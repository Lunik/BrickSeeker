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
    // A single typed destination, not three separate `Bool` + `.navigationDestination(isPresented:)`
    // pairs — chaining multiple `isPresented:` destinations on the same NavigationStack is prone to
    // an infinite construct/destroy oscillation between them (SwiftUI can't stably reconcile which
    // one owns the current path position), reproduced here once a third one (Wishlist) was added:
    // CollectionView/StatisticsView/WishlistView kept getting created and torn down forever,
    // freezing the app at ~100% CPU. `.navigationDestination(item:)` has exactly one destination to
    // resolve, so there's nothing to oscillate between.
    private enum Destination: Identifiable {
        case collection
        case statistics
        case wishlist

        var id: Self { self }
    }
    @State private var destination: Destination?

    let onStartScanning: () -> Void
    @Binding var pendingAction: HomeScreenShortcut?

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
                        wishlistSection(viewModel)
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

                scanButtonCluster
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Réglages")
                }
            }
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .collection:
                    CollectionView(lookupViewModel: lookupViewModel)
                case .statistics:
                    StatisticsView(lookupViewModel: lookupViewModel)
                case .wishlist:
                    WishlistView(lookupViewModel: lookupViewModel)
                }
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
            // Gated while History/ManualEntry are up: those present their own nested result
            // sheets, so closing a result returns there instead of Home — see
            // LookupResultSheetsModifier's doc for the full story.
            .lookupResultSheets(for: lookupViewModel, isGated: showHistory || showManualEntry)
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
            .background(Color.brickStud)
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
                    StatCard(title: "Sets scannés", value: "\(viewModel.scannedSetsCount)", icon: "number.square")
                }
                .buttonStyle(.plain)

                StatCard(title: "Scans effectués", value: "\(viewModel.totalScans)", icon: "viewfinder")
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
                HStack(spacing: 12) {
                    Button {
                        destination = .statistics
                    } label: {
                        statCardLink(title: "Statistiques", icon: "chart.bar")
                    }
                    .buttonStyle(.plain)

                    Button {
                        destination = .collection
                    } label: {
                        StatCard(title: "Sets possédés", value: "\(viewModel.ownedSetsCount)", icon: "shippingbox")
                    }
                    .buttonStyle(.plain)
                }

                // Every branch renders exactly one line (including the blank placeholder), so the
                // row never appears/disappears: that reflowed the ScrollView content while
                // .refreshable's pull gesture was still tracking, which can cancel the in-flight
                // sync task on some iOS versions. `minHeight` (not a fixed height) so Dynamic
                // Type XXL isn't clipped.
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
                .frame(minHeight: 16, alignment: .leading)
            }
        }
    }

    /// Independent of `collectionStatsSection` — the wishlist lives on Brickset, a separate
    /// account from Rebrickable's (see `AGENTS.md`/issue #6), so it's gated on its own linked
    /// state rather than `viewModel.isAccountLinked`.
    private func wishlistSection(_ viewModel: HomeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Liste cadeaux")
                .font(.headline)

            if !viewModel.isBricksetAccountLinked {
                Text("Compte non lié — ouvrez Réglages pour lier votre compte Brickset.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    destination = .wishlist
                } label: {
                    StatCard(title: "Dans la liste cadeaux", value: "\(viewModel.wishlistSetsCount)", icon: "heart")
                }
                .buttonStyle(.plain)

                // Same sync as Collection (piggybacks on `syncCollection()`, see
                // `HomeViewModel`) — mirrors that section's row so both show one consistent
                // "last synced" state instead of the wishlist looking unsynced next to it.
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
                .frame(minHeight: 16, alignment: .leading)
            }
        }
    }

    /// Same layout as `StatCard` (icon + two text lines) for a tile that navigates somewhere
    /// rather than displaying a count.
    private func statCardLink(title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.bold())
            Text("Voir le détail")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    /// The three actions (photo, scan, manual entry) as a single floating cluster instead of a
    /// lone camera button plus a separate `quickActionsSection` in the scrolling content — see
    /// issue #99. The camera button keeps its original size/action; the satellites reuse the
    /// same `showPhotoPicker`/`showManualEntry` triggers without duplicating that logic.
    private var scanButtonCluster: some View {
        HStack(spacing: 24) {
            satelliteButton(icon: "keyboard", accessibilityLabel: "Saisie manuelle") {
                showManualEntry = true
            }

            scanButton

            satelliteButton(icon: "photo.on.rectangle", accessibilityLabel: "Depuis mes photos") {
                showPhotoPicker = true
            }
        }
        .padding(.bottom, 32)
    }

    private var scanButton: some View {
        Button(action: onStartScanning) {
            Image(systemName: "camera.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(AppTheme.shared.accent)
                .clipShape(Circle())
                .shadow(radius: 8)
        }
        .accessibilityLabel("Scanner un set")
    }

    private func satelliteButton(icon: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .background(.thinMaterial)
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .accessibilityLabel(accessibilityLabel)
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
            // parent at once (see HomeView's gated lookupResultSheets). Nesting here, like
            // HistoryView already does, avoids that race entirely. Closing the result reveals
            // this view again, not Home.
            .lookupResultSheets(for: lookupViewModel)
        }
    }

    private func submit() {
        let trimmed = setNum.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}
