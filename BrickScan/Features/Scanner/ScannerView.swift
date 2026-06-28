import SwiftUI
import SwiftData

struct ScannerView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ScannerViewModel()
    @State private var hasAPIKey = KeychainService.shared.hasAPIKey
    var onStopScanning: (() -> Void)?

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
                    if let onStopScanning {
                        Button {
                            onStopScanning()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.toggleTorch()
                    } label: {
                        Image(systemName: viewModel.torchOn ? "bolt.fill" : "bolt.slash")
                    }
                }
            }
            .sheet(isPresented: setDetailBinding) {
                if case .found(let legoSet, let collectionStatus) = viewModel.state {
                    let cached = LocalRepository(modelContext: modelContext).cachedSet(setNum: legoSet.setNum)
                    SetDetailView(
                        legoSet: legoSet,
                        collectionStatus: collectionStatus,
                        initialListName: viewModel.lastFoundWasFromCache ? cached?.currentListName : nil,
                        initialStorePrice: cached?.storePriceEUR.map { StorePrice(amount: $0, currency: "EUR", availability: cached?.storeAvailability) },
                        initialStorePriceFetchedAt: cached?.storePriceFetchedAt,
                        reconcileOnAppear: viewModel.lastFoundWasFromCache,
                        isOfflineResult: viewModel.lastFoundWasOffline
                    ) {
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
        .onAppear {
            viewModel.localRepository = LocalRepository(modelContext: modelContext)
            viewModel.onAppear()
        }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: isMenuOpen) { _, isOpen in
            if isOpen {
                viewModel.cameraController.stop()
            } else {
                viewModel.cameraController.start()
            }
        }
        .onChange(of: viewModel.state) { _, newState in
            LocalRepository(modelContext: modelContext).cacheFoundState(newState)
        }
    }

    private var isMenuOpen: Bool {
        setDetailBinding.wrappedValue || ambiguousBinding.wrappedValue
    }

    private var apiKeyWarningBanner: some View {
        VStack {
            Button {
                onStopScanning?()
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("API Key Rebrickable non configurée")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.footnote.bold())
                .padding(12)
                .background(Color.brickStud)
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

struct AmbiguousSetPickerView: View {
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
                        Text(set.name).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
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
