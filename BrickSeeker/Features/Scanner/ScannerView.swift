import SwiftUI
import SwiftData
import PhotosUI

struct ScannerView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ScannerViewModel()
    @State private var hasAPIKey = KeychainService.shared.hasAPIKey
    @State private var showBatchSummary = false
    @State private var showBatchModeConfirmation = false
    /// Persists across app launches (issue #157) — the explanation alert only needs to show once,
    /// ever; `ScannerViewModel`/`isBatchModeEnabled` are recreated fresh every time the scanner is
    /// (re)entered (`BrickSeekerApp`'s root is a real `if isScanning {...}` branch), so a per-session
    /// flag would re-nag on every re-entry. Mirrors `BrickSeekerApp`'s `hasSeenOnboarding`.
    @AppStorage("hasSeenBatchModeIntro") private var hasSeenBatchModeIntro = false
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

                // Camera-refused is the one dead end the camera view alone can't recover from —
                // it replaces the live overlay with a full-screen `ContentUnavailableView`
                // offering a real way out (open iOS Settings, or fall back to manual entry / a
                // photo) instead of leaving the user stuck staring at a passive banner (#145).
                // A missing API key is no longer a dead end: `ScannerViewModel.resolveSet`
                // treats it exactly like being offline and falls back to the offline catalogue,
                // so scanning/manual entry/photo import still work — this only gets a heads-up
                // banner, not a block (#145 follow-up).
                if viewModel.state == .permissionDenied {
                    permissionDeniedView
                } else {
                    ScanOverlayView(
                        state: viewModel.state,
                        candidateDetected: viewModel.candidateDetected,
                        candidateThumbnail: viewModel.candidateThumbnail
                    )

                    if !hasAPIKey {
                        missingAPIKeyBanner
                    }

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
                            // Turning off is the safe direction (nothing lost, easily flipped back
                            // on) — no confirmation needed. Turning on redirects every subsequent
                            // scan into a session instead of opening the detail sheet, which is
                            // explained once via `showBatchModeConfirmation` (issue #157) and never
                            // again after `hasSeenBatchModeIntro` is set.
                            if viewModel.isBatchModeEnabled {
                                viewModel.isBatchModeEnabled = false
                            } else if hasSeenBatchModeIntro {
                                viewModel.isBatchModeEnabled = true
                            } else {
                                showBatchModeConfirmation = true
                            }
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
            .alert("Activer le mode lot ?", isPresented: $showBatchModeConfirmation) {
                Button("Activer") {
                    viewModel.isBatchModeEnabled = true
                    hasSeenBatchModeIntro = true
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les prochains scans seront ajoutés à une session, sans ouvrir la fiche du set.")
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
        .onDisappear {
            viewModel.onDisappear()
            // Always clear, independent of `isBatchModeEnabled` below — leaving the camera screen
            // must never leave the idle timer disabled, or the screen stays on indefinitely and
            // drains the battery (#163).
            UIApplication.shared.isIdleTimerDisabled = false
        }
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
        // `initial: true` covers batch mode already being on when this view (re)appears, same
        // reasoning as `StatisticsView`'s price-batch handling (#162) — keeps the screen awake for
        // the whole batch-scan session instead of letting auto-lock interrupt it (#163).
        .onChange(of: viewModel.isBatchModeEnabled, initial: true) { _, isEnabled in
            UIApplication.shared.isIdleTimerDisabled = isEnabled
        }
    }

    private var isMenuOpen: Bool {
        viewModel.isPresentingLookupResult || showBatchSummary || showManualEntry || showPhotoPicker || showSettings || showBatchModeConfirmation
    }

    private var isCameraBlocked: Bool {
        viewModel.state == .permissionDenied
    }

    private var isRecoverableFailure: Bool {
        switch viewModel.state {
        case .notFound, .error: return true
        default: return false
        }
    }

    /// Empty session: a plain status row, not a `Button` — it used to be tappable and open
    /// `BatchSessionSummaryView`'s own empty state, a dead end with nothing to do there (issue
    /// #157). Non-empty: unchanged tappable row into the real session.
    private var batchSessionButton: some View {
        VStack {
            Spacer()
            if viewModel.batchSession.isEmpty {
                HStack {
                    Image(systemName: "square.stack.3d.up.fill")
                        .accessibilityHidden(true)
                    Text("Mode lot actif — scanne un set pour commencer")
                    Spacer()
                }
                .font(.footnote.bold())
                .padding(12)
                .background(.thinMaterial)
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else {
                Button {
                    showBatchSummary = true
                } label: {
                    HStack {
                        Image(systemName: "square.stack.3d.up.fill")
                        Text("Voir la session (\(viewModel.batchSession.items.count))")
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

    /// Non-blocking heads-up, not a dead end: `ScannerViewModel.resolveSet` treats a missing API
    /// key exactly like being offline and falls back to the offline catalogue, so camera/manual
    /// entry/photo import all still work as long as that catalogue has the set. Mirrors
    /// `HomeView`'s own `apiKeyWarningBanner` styling; tapping opens Settings in-app (via the
    /// scanner's own sheet, not `onStopScanning`) rather than exiting the scanner.
    private var missingAPIKeyBanner: some View {
        VStack {
            Button {
                showSettings = true
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Clé API Rebrickable non configurée — recherche limitée au catalogue hors-ligne")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.footnote.bold())
                .padding(12)
                .background(Color.brickStud)
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
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
                    // Every other list in the app shows a thumbnail via `SetRowView` — this was
                    // the one exception, making near-identical set numbers harder to tell apart
                    // by more than digits alone (#156).
                    HStack(spacing: 14) {
                        SetThumbnailView(imageUrl: set.setImgUrl)
                        VStack(alignment: .leading) {
                            Text(duplicatedBaseSetNums.contains(set.setNum.baseSetNum) ? set.setNum : set.setNum.baseSetNum)
                                .font(.headline)
                            Text(set.name).font(.subheadline).foregroundStyle(.secondary)
                        }
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
