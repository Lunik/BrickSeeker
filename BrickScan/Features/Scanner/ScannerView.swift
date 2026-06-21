import SwiftUI
import PhotosUI

struct ScannerView: View {
    @State private var viewModel = ScannerViewModel()
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var hasAPIKey = KeychainService.shared.hasAPIKey
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreviewView(controller: viewModel.cameraController)
                    .ignoresSafeArea()

                ScanOverlayView(state: viewModel.state, candidateDetected: viewModel.candidateDetected)

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
                Text("Historique")
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                hasAPIKey = KeychainService.shared.hasAPIKey
            }) {
                SettingsView()
            }
            .sheet(isPresented: setDetailBinding) {
                if case .found(let legoSet, let userSet) = viewModel.state {
                    SetDetailView(legoSet: legoSet, userSet: userSet) {
                        viewModel.resumeScanning()
                    }
                }
            }
            .sheet(isPresented: ambiguousBinding) {
                if case .ambiguous(let sets) = viewModel.state {
                    AmbiguousSetPickerView(sets: sets) { selected in
                        viewModel.state = .processing
                        Task {
                            // Re-trigger detail resolution for the chosen set.
                            viewModel.state = .found(selected, nil)
                        }
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
        showHistory || showSettings || showPhotoPicker || setDetailBinding.wrappedValue || ambiguousBinding.wrappedValue
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
