import SwiftUI
import PhotosUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    let viewModel: HomeViewModel
    @State private var lookupViewModel = ScannerViewModel()

    @State private var hasAPIKey = KeychainService.shared.hasAPIKey
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showManualEntry = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showCollection = false

    let onStartScanning: () -> Void
    @Binding var pendingAction: AppShortcut?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("BrickScan")
                            .font(.largeTitle.bold())
                            .padding(.top, 16)

                        if !hasAPIKey {
                            apiKeyWarningBanner
                        }

                        appStatsSection(viewModel)
                        collectionStatsSection(viewModel)

                        quickActionsSection
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 140)
                }
                .refreshable {
                    // SwiftUI can cancel .refreshable's own task mid-flight (a known quirk, e.g.
                    // when pulled content reflows under the gesture). Run the sync in a detached
                    // Task so it keeps going to completion even if that happens — otherwise the
                    // request gets cancelled before it reaches the network and nothing happens.
                    await Task { await viewModel.syncCollection() }.value
                }

                scanButton
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(isPresented: $showCollection) {
                CollectionView(lookupViewModel: lookupViewModel)
            }
            .sheet(isPresented: $showHistory) {
                HistoryView(lookupViewModel: lookupViewModel) { setNum in
                    lookupViewModel.lookupSetNumber(setNum)
                }
            }
            .sheet(isPresented: $showManualEntry) {
                ManualSetEntryView(lookupViewModel: lookupViewModel) { setNum in
                    lookupViewModel.lookupSetNumber(setNum)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                hasAPIKey = KeychainService.shared.hasAPIKey
                Task { await viewModel.syncCollection() }
            }) {
                SettingsView()
            }
            .sheet(isPresented: setDetailBinding) {
                if case .found(let legoSet, let collectionStatus) = lookupViewModel.state {
                    let cached = LocalRepository(modelContext: modelContext).cachedSet(setNum: legoSet.setNum)
                    SetDetailView(
                        legoSet: legoSet,
                        collectionStatus: collectionStatus,
                        initialListName: lookupViewModel.lastFoundWasFromCache ? cached?.currentListName : nil,
                        initialStorePrice: cached?.storePriceEUR.map { StorePrice(amount: $0, currency: "EUR", availability: cached?.storeAvailability) },
                        initialStorePriceFetchedAt: cached?.storePriceFetchedAt,
                        reconcileOnAppear: lookupViewModel.lastFoundWasFromCache,
                        isOfflineResult: lookupViewModel.lastFoundWasOffline
                    ) {
                        lookupViewModel.resumeScanning()
                    }
                }
            }
            .sheet(isPresented: ambiguousBinding) {
                if case .ambiguous(let sets) = lookupViewModel.state {
                    AmbiguousSetPickerView(sets: sets) { selected in
                        lookupViewModel.selectAmbiguousSet(selected)
                    } onCancel: {
                        lookupViewModel.resumeScanning()
                    }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let cgImage = UIImage(data: data)?.cgImage {
                        lookupViewModel.importImage(cgImage)
                    }
                    selectedPhotoItem = nil
                }
            }
            .onChange(of: lookupViewModel.state) { _, newState in
                LocalRepository(modelContext: modelContext).cacheFoundState(newState)
            }
        }
        .onAppear {
            lookupViewModel.localRepository = LocalRepository(modelContext: modelContext)
            lookupViewModel.playsFeedbackSounds = false
            // Local-only refresh (no network) — picks up anything scanned while the camera was
            // open without re-syncing the whole remote collection just for returning to Home.
            viewModel.loadFromCache()
            consumePendingAction()
        }
        .onChange(of: pendingAction) { _, _ in consumePendingAction() }
    }

    private func consumePendingAction() {
        guard let pendingAction else { return }
        self.pendingAction = nil
        switch pendingAction {
        case .manualEntry:
            showManualEntry = true
        case .photo:
            showPhotoPicker = true
        case .scan:
            break
        }
    }


    // Gated by !showHistory and !showManualEntry: when a lookup is triggered from one of those,
    // it presents its own nested SetDetail/Ambiguous sheet on top of itself instead (see
    // HistoryView/ManualSetEntryView), so closing the result returns there rather than straight
    // to Home. Without this gate, this sheet would race the sibling sheet's own dismissal —
    // SwiftUI can't cleanly close one sheet and open another from the same parent in one
    // transaction, which is exactly what happened when a manually-typed set resolved from cache
    // instantly (same frame as the manual-entry sheet dismissing): the price-load animation never
    // got a chance to start because the SetDetail sheet's presentation/task got dropped.
    private var setDetailBinding: Binding<Bool> {
        Binding(
            get: {
                guard !showHistory, !showManualEntry else { return false }
                if case .found = lookupViewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { lookupViewModel.resumeScanning() }
            }
        )
    }

    private var ambiguousBinding: Binding<Bool> {
        Binding(
            get: {
                guard !showHistory, !showManualEntry else { return false }
                if case .ambiguous = lookupViewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { lookupViewModel.resumeScanning() }
            }
        )
    }

    private var apiKeyWarningBanner: some View {
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
        }
    }

    private func appStatsSection(_ viewModel: HomeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activité")
                .font(.headline)
            HStack(spacing: 12) {
                Button {
                    showHistory = true
                } label: {
                    statCard(title: "Sets scannés", value: "\(viewModel.scannedSetsCount)", icon: "number.square")
                }
                .buttonStyle(.plain)

                statCard(title: "Scans effectués", value: "\(viewModel.totalScans)", icon: "barcode.viewfinder")
            }
        }
    }

    private func collectionStatsSection(_ viewModel: HomeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Collection")
                .font(.headline)

            if !viewModel.isAccountLinked {
                Text("Compte non lié — ouvrez Réglages pour lier votre compte Rebrickable.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showCollection = true
                } label: {
                    HStack(spacing: 12) {
                        statCard(title: "Sets possédés", value: "\(viewModel.ownedSetsCount)", icon: "shippingbox")
                        statCard(title: "Listes", value: "\(viewModel.listsCount)", icon: "list.bullet")
                    }
                }
                .buttonStyle(.plain)

                // Fixed height regardless of which branch renders: letting this row appear/
                // disappear reflows the ScrollView content while .refreshable's pull gesture is
                // still tracking, which can cancel the in-flight sync task on some iOS versions.
                HStack(spacing: 6) {
                    if viewModel.isSyncing {
                        ProgressView().controlSize(.small)
                        Text("Synchronisation…")
                    } else if let errorMessage = viewModel.syncErrorMessage {
                        Text(errorMessage)
                    } else if let lastSyncedAt = viewModel.lastSyncedAt {
                        Text("Dernière synchronisation : \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 16, alignment: .leading)
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions")
                .font(.headline)
            HStack(spacing: 12) {
                actionButton(title: "Photo", icon: "photo.on.rectangle") { showPhotoPicker = true }
                actionButton(title: "Saisie", icon: "keyboard") { showManualEntry = true }
            }
        }
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(value)
                .font(.title2.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.primary)
    }

    private var scanButton: some View {
        Button(action: onStartScanning) {
            Image(systemName: "camera.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Color.accentColor)
                .clipShape(Circle())
                .shadow(radius: 8)
        }
        .padding(.bottom, 32)
    }
}

private struct ManualSetEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var setNum = ""
    @FocusState private var isInputFocused: Bool
    let lookupViewModel: ScannerViewModel
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
            // Nested rather than a sibling sheet on HomeView — when a typed set resolves
            // straight from cache, the result is ready in the same frame this view dismisses,
            // and SwiftUI can't cleanly close one sheet while opening another from the same
            // parent at once (see HomeView.setDetailBinding's !showManualEntry gate). Nesting
            // here, like HistoryView already does, avoids that race entirely.
            .sheet(isPresented: setDetailBinding) {
                if case .found(let legoSet, let collectionStatus) = lookupViewModel.state {
                    let cached = LocalRepository(modelContext: modelContext).cachedSet(setNum: legoSet.setNum)
                    SetDetailView(
                        legoSet: legoSet,
                        collectionStatus: collectionStatus,
                        initialListName: lookupViewModel.lastFoundWasFromCache ? cached?.currentListName : nil,
                        initialStorePrice: cached?.storePriceEUR.map { StorePrice(amount: $0, currency: "EUR", availability: cached?.storeAvailability) },
                        initialStorePriceFetchedAt: cached?.storePriceFetchedAt,
                        reconcileOnAppear: lookupViewModel.lastFoundWasFromCache,
                        isOfflineResult: lookupViewModel.lastFoundWasOffline
                    ) {
                        lookupViewModel.resumeScanning()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: ambiguousBinding) {
                if case .ambiguous(let sets) = lookupViewModel.state {
                    AmbiguousSetPickerView(sets: sets) { selected in
                        lookupViewModel.selectAmbiguousSet(selected)
                    } onCancel: {
                        lookupViewModel.resumeScanning()
                    }
                }
            }
        }
    }

    private func submit() {
        let trimmed = setNum.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }

    private var setDetailBinding: Binding<Bool> {
        Binding(
            get: {
                if case .found = lookupViewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { lookupViewModel.resumeScanning() }
            }
        )
    }

    private var ambiguousBinding: Binding<Bool> {
        Binding(
            get: {
                if case .ambiguous = lookupViewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { lookupViewModel.resumeScanning() }
            }
        )
    }
}
