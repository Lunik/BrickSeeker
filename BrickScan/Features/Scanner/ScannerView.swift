import SwiftUI
import PhotosUI
import SwiftData

struct ScannerView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ScannerViewModel()
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var hasAPIKey = KeychainService.shared.hasAPIKey
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showManualEntry = false

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreviewView(controller: viewModel.cameraController)
                    .ignoresSafeArea()

                ScanOverlayView(state: viewModel.state, candidateDetected: viewModel.candidateDetected)

                if let minifigOverlay = viewModel.minifigOverlay {
                    MinifigOverlayView(overlay: minifigOverlay)
                }

                if !hasAPIKey {
                    apiKeyWarningBanner
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        Button {
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Image(systemName: "photo.on.rectangle")
                        }
                        Button {
                            showManualEntry = true
                        } label: {
                            Image(systemName: "keyboard")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button {
                            viewModel.toggleTorch()
                        } label: {
                            Image(systemName: viewModel.torchOn ? "bolt.fill" : "bolt.slash")
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                HistoryView { setNum in
                    viewModel.lookupSetNumber(setNum)
                }
            }
            .sheet(isPresented: $showManualEntry) {
                ManualSetEntryView { setNum in
                    viewModel.lookupSetNumber(setNum)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                hasAPIKey = KeychainService.shared.hasAPIKey
            }) {
                SettingsView()
            }
            .sheet(isPresented: setDetailBinding) {
                if case .found(let legoSet, let collectionStatus) = viewModel.state {
                    SetDetailView(legoSet: legoSet, collectionStatus: collectionStatus) {
                        viewModel.resumeScanning()
                    }
                }
            }
            .sheet(isPresented: ambiguousBinding) {
                if case .ambiguous(let sets) = viewModel.state {
                    AmbiguousSetPickerView(sets: sets) { selected in
                        viewModel.selectAmbiguousSet(selected)
                    } onCancel: {
                        viewModel.resumeScanning()
                    }
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: isMenuOpen) { _, isOpen in
            if isOpen {
                viewModel.cameraController.stop()
            } else {
                viewModel.cameraController.start()
            }
        }
        .onChange(of: viewModel.state) { _, newState in
            if case .found(let legoSet, let collectionStatus) = newState {
                let isInCollection: Bool
                let listId: Int?
                switch collectionStatus {
                case .inCollection(let userSet):
                    isInCollection = true
                    listId = userSet.listId
                case .notInCollection, .unknown:
                    isInCollection = false
                    listId = nil
                }
                LocalRepository(modelContext: modelContext)
                    .cacheSet(legoSet, isInCollection: isInCollection, listId: listId, listName: nil)
            }
        }
        .onChange(of: viewModel.lastDetectedMinifig) { _, newValue in
            guard let newValue else { return }
            let isInCollection: Bool
            let listId: Int?
            switch newValue.collectionStatus {
            case .inCollection(let userSet):
                isInCollection = true
                listId = userSet.listId
            case .notInCollection, .unknown:
                isInCollection = false
                listId = nil
            }
            LocalRepository(modelContext: modelContext).cacheSet(
                newValue.legoSet,
                isInCollection: isInCollection,
                listId: listId,
                listName: nil,
                isMinifig: true,
                boxCode: newValue.boxCode
            )
        }
        .onChange(of: viewModel.lastUnresolvedBoxCode) { _, newValue in
            guard let newValue else { return }
            LocalRepository(modelContext: modelContext).cachePendingBoxCode(newValue.boxCode)
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let cgImage = UIImage(data: data)?.cgImage {
                    viewModel.importImage(cgImage)
                }
                selectedPhotoItem = nil
            }
        }
    }

    private var isMenuOpen: Bool {
        showHistory || showSettings || showPhotoPicker || showManualEntry || setDetailBinding.wrappedValue || ambiguousBinding.wrappedValue
    }

    private var apiKeyWarningBanner: some View {
        VStack {
            Button {
                showSettings = true
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("API Key Rebrickable non configurée")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.footnote.bold())
                .padding(12)
                .background(Color(hex: "FFD700"))
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            Spacer()
        }
    }

    private var setDetailBinding: Binding<Bool> {
        Binding(
            get: {
                if case .found = viewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { viewModel.resumeScanning() }
            }
        )
    }

    private var ambiguousBinding: Binding<Bool> {
        Binding(
            get: {
                if case .ambiguous = viewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { viewModel.resumeScanning() }
            }
        )
    }
}

private struct ManualSetEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var setNum = ""
    @FocusState private var isInputFocused: Bool
    let onSubmit: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Numéro de set, ex. 42143", text: $setNum)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isInputFocused)
                    .onSubmit(submit)
            }
            .navigationTitle("Ajouter un set")
            .onAppear { isInputFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rechercher", action: submit)
                        .disabled(setNum.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func submit() {
        let trimmed = setNum.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

private struct AmbiguousSetPickerView: View {
    let sets: [LegoSet]
    let onSelect: (LegoSet) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List(sets) { set in
                Button {
                    onSelect(set)
                } label: {
                    VStack(alignment: .leading) {
                        Text(set.setNum).font(.headline)
                        Text(set.name).font(.subheadline)
                    }
                }
            }
            .navigationTitle("Choisir un set")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", action: onCancel)
                }
            }
        }
    }
}
