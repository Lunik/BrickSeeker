import SwiftUI
import SwiftData
import PhotosUI

struct ScannerView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ScannerViewModel()
    @State private var hasAPIKey = KeychainService.shared.hasAPIKey
    @State private var showBatchSummary = false
    @State private var showManualEntry = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showSettings = false
    var onStopScanning: (() -> Void)?

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreviewView(controller: viewModel.cameraController)
                    .ignoresSafeArea()

                // Camera-refused and missing-API-key are both dead ends the camera view alone
                // can't recover from — each replaces the live overlay with a full-screen
                // `ContentUnavailableView` offering a real way out (open Settings/iOS Settings,
                // or fall back to manual entry / a photo) instead of leaving the user stuck
                // staring at a passive banner or a silently-failing scan (#145).
                if viewModel.state == .permissionDenied {
                    permissionDeniedView
                } else if !hasAPIKey {
                    missingAPIKeyView
                } else {
                    ScanOverlayView(
                        state: viewModel.state,
                        candidateDetected: viewModel.candidateDetected,
                        candidateThumbnail: viewModel.candidateThumbnail
                    )

                    if isRecoverableFailure {
                        recoveryActionCluster
                    }

                    if viewModel.isBatchModeEnabled {
                        batchSessionButton
                    }
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
                        .accessibilityLabel("Fermer le scanner")
                    }
                }
                // Torch/batch toggles are meaningless while the camera is refused or blocked
                // behind the missing-API-key screen — hide them rather than leave controls that
                // do nothing (or nothing useful) visible.
                if !isCameraBlocked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.isBatchModeEnabled.toggle()
                        } label: {
                            Image(systemName: viewModel.isBatchModeEnabled ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                        }
                        .accessibilityLabel("Mode lot")
                        .accessibilityValue(viewModel.isBatchModeEnabled ? "Activé" : "Désactivé")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.toggleTorch()
                        } label: {
                            Image(systemName: viewModel.torchOn ? "bolt.fill" : "bolt.slash")
                        }
                        .accessibilityLabel("Torche")
                        .accessibilityValue(viewModel.torchOn ? "Activée" : "Désactivée")
                    }
                }
            }
            // `isGated: showManualEntry` — ManualSetEntryView nests its own copy of this same
            // modifier (see its doc comment), so this ungated copy must stand down while it's up,
            // exactly like HomeView's, to avoid a race between the two presenters on `.found`/
            // `.ambiguous`.
            .lookupResultSheets(for: viewModel, isGated: showManualEntry)
            .sheet(isPresented: $showBatchSummary) {
                BatchSessionSummaryView(
                    session: viewModel.batchSession,
                    onSelect: { setNum in
                        // Dismiss this sheet first, then ask the viewModel to resolve for detail
                        // on the next runloop tick — presenting the detail sheet in the same
                        // transaction as dismissing this one is unreliable in SwiftUI.
                        showBatchSummary = false
                        DispatchQueue.main.async {
                            viewModel.lookupSetForDetail(setNum)
                        }
                    },
                    onClearSession: {
                        viewModel.batchSession.clear()
                    }
                )
            }
            .sheet(isPresented: $showManualEntry) {
                ManualSetEntryView(lookupViewModel: viewModel) { setNum in
                    viewModel.lookupSetNumber(setNum, source: .manualEntry)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                hasAPIKey = KeychainService.shared.hasAPIKey
            }) {
                SettingsView()
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
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
            LocalRepository(modelContext: modelContext).cacheFoundState(
                newState,
                markAsScanned: viewModel.lastLookupSource.shouldRecordScanEvent
            )
        }
    }

    private var isMenuOpen: Bool {
        viewModel.isPresentingLookupResult || showBatchSummary || showManualEntry || showPhotoPicker || showSettings
    }

    private var isCameraBlocked: Bool {
        viewModel.state == .permissionDenied || !hasAPIKey
    }

    private var isRecoverableFailure: Bool {
        switch viewModel.state {
        case .notFound, .error: return true
        default: return false
        }
    }

    private var batchSessionButton: some View {
        VStack {
            Spacer()
            Button {
                showBatchSummary = true
            } label: {
                HStack {
                    Image(systemName: "square.stack.3d.up.fill")
                    Text(viewModel.batchSession.isEmpty ? "Mode lot actif" : "Voir la session (\(viewModel.batchSession.items.count))")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.footnote.bold())
                .padding(12)
                .background(.thinMaterial)
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    /// Camera access was refused: nothing detectable is on screen, so this replaces the passive
    /// overlay entirely with a real way forward instead of a dead viewfinder — the deep link to
    /// iOS Settings mirrors `SettingsView.swift`'s own "Ouvrir les réglages iOS" link, and manual
    /// entry / a photo both work without the camera.
    private var permissionDeniedView: some View {
        ContentUnavailableView {
            Label("Accès caméra refusé", systemImage: "camera.metering.none")
        } description: {
            Text("Autorise la caméra dans les réglages iOS, ou saisis un numéro / choisis une photo.")
        } actions: {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Ouvrir les réglages iOS", destination: url)
            }
            Button("Saisir un numéro") { showManualEntry = true }
            Button("Choisir une photo") { showPhotoPicker = true }
        }
    }

    /// Escalated from the old passive "API Key non configurée" banner: with no key, every lookup
    /// (camera, manual, or photo — all three call the same Rebrickable API) is guaranteed to
    /// fail, so this blocks scanning outright with a single clear way out rather than let the
    /// user keep hitting silent/confusing errors (#145). Not a whole-app lock — Guideline 2.1 is
    /// about not gating the *app* behind an account; this only gates the one feature that
    /// genuinely needs the key, and points straight at fixing it.
    private var missingAPIKeyView: some View {
        ContentUnavailableView {
            Label("Clé API Rebrickable manquante", systemImage: "key.slash")
        } description: {
            Text("Ajoutez votre clé API Rebrickable dans les réglages pour identifier des sets.")
        } actions: {
            Button("Ouvrir les réglages") { showSettings = true }
        }
    }

    /// Shown alongside the normal overlay when a resolution just failed (`.notFound`/`.error`) —
    /// gives an explicit way to try again or sidestep the camera entirely, instead of leaving the
    /// user staring at a status label with no obvious next step (#145).
    private var recoveryActionCluster: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Button {
                    viewModel.resumeScanning()
                } label: {
                    Label("Réessayer", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 10) {
                    Button("Saisir un numéro") { showManualEntry = true }
                        .frame(maxWidth: .infinity)
                    Button("Choisir une photo") { showPhotoPicker = true }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }

}

struct AmbiguousSetPickerView: View {
    let sets: [LegoSet]
    let onSelect: (LegoSet) -> Void
    let onCancel: () -> Void

    /// Base numbers shared by more than one candidate — only these need the full `-N` suffix to
    /// tell entries apart (e.g. Collectible Minifigures, see #97). Other candidates show the
    /// base number, consistent with the rest of the app.
    private var duplicatedBaseSetNums: Set<String> {
        let counts = Dictionary(grouping: sets, by: \.setNum.baseSetNum).mapValues(\.count)
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    var body: some View {
        NavigationStack {
            List(sets) { set in
                Button {
                    onSelect(set)
                } label: {
                    VStack(alignment: .leading) {
                        Text(duplicatedBaseSetNums.contains(set.setNum.baseSetNum) ? set.setNum : set.setNum.baseSetNum)
                            .font(.headline)
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
