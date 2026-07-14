import SwiftUI
import PhotosUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    let viewModel: HomeViewModel
    @State private var lookupViewModel = ScannerViewModel()

    @State private var hasAPIKey = KeychainService.shared.hasAPIKey
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
    private enum Destination: Identifiable, Equatable {
        case collection
        case statistics
        case wishlist
        case history
        case minifigs
        case newSets

        var id: Self { self }
    }
    @State private var destination: Destination?

    let onStartScanning: () -> Void
    @Binding var pendingAction: HomeScreenShortcut?

    var body: some View {
        NavigationStack {
            // The cluster floats over the content as a `ZStack` overlay with *no* backing of its
            // own — no scrim, no colour fill. Earlier takes each traded one flaw for another: a
            // fixed-width gradient scrim rendered as a parasitic translucent box (#192); giving the
            // cluster its own `VStack` row instead left a dead strip of window background (white in
            // light mode, black in dark) permanently filling the bottom of the screen behind the
            // buttons. With a bare overlay there's nothing painted behind the buttons at all — the
            // scrolling content (or, past it, the plain background) shows through the gaps. The
            // ScrollView's generous `.bottom` padding is what keeps the last card reachable clear
            // of the buttons: it can always be scrolled up above them.
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("BrickSeeker")
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
                    .padding(.bottom, 120)
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
                case .history:
                    HistoryView(lookupViewModel: lookupViewModel) { setNum in
                        lookupViewModel.lookupSetNumber(setNum, source: .listReopen)
                    }
                case .minifigs:
                    MinifigGalleryView(lookupViewModel: lookupViewModel)
                case .newSets:
                    NewSetsView(lookupViewModel: lookupViewModel)
                }
            }
            .sheet(isPresented: $showManualEntry) {
                ManualSetEntryView(lookupViewModel: lookupViewModel) { setNum in
                    lookupViewModel.lookupSetNumber(setNum, source: .manualEntry)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                hasAPIKey = KeychainService.shared.hasAPIKey
                Task { await viewModel.syncCollection() }
                // The minifig catalogue's own download/purge lives in Settings too (issue #170) —
                // refresh the Home tile's count in case it changed there, same reasoning as the
                // `.minifigs` destination's own onChange below.
                Task { await viewModel.loadOwnedMinifigsCount() }
            }) {
                SettingsView()
            }
            // Gated while ManualEntry is up: it presents its own nested result sheet, so closing
            // a result returns there instead of Home — see LookupResultSheetsModifier's doc for
            // the full story. History/Collection/Wishlist/Statistics are pushed onto this same
            // NavigationStack (not a nested presenter), so this ungated copy already handles them:
            // dismissing SetDetail reveals whichever of those is on top of the stack.
            .lookupResultSheets(for: lookupViewModel, isGated: showManualEntry)
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
                LocalRepository(modelContext: modelContext).cacheFoundState(
                    newState,
                    markAsScanned: lookupViewModel.lastLookupSource.shouldRecordScanEvent
                )
            }
        }
        .onAppear {
            lookupViewModel.localRepository = LocalRepository(modelContext: modelContext)
            lookupViewModel.playsFeedbackSounds = false
            // Local-only refresh (no network) — picks up anything scanned while the camera was
            // open without re-syncing the whole remote collection just for returning to Home.
            viewModel.loadFromCache()
            consumePendingAction()
            Task { await viewModel.loadOwnedMinifigsCount() }
        }
        .onChange(of: pendingAction) { _, _ in consumePendingAction() }
        // Refreshes the "Mes minifigs" count after returning from the gallery — unlike the other
        // pushed destinations, that screen can change the answer mid-visit (downloading the
        // minifig catalogue there), and `HomeView` itself isn't recreated by a push/pop the way
        // it is by exiting the camera, so `onAppear` alone wouldn't catch it.
        .onChange(of: destination) { oldValue, newValue in
            if oldValue == .minifigs, newValue == nil {
                Task { await viewModel.loadOwnedMinifigsCount() }
            }
        }
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
                Text("Clé API Rebrickable non configurée")
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.footnote.bold())
            .padding(12)
            // `brickStud` is the scan/processing color, not a warning one (#156) — this banner
            // means "something needs attention", the same semantic `.orange` uses for
            // `StoreAvailabilityStatus.outOfStock`/the collection-status "unknown" badge
            // elsewhere in the app.
            .background(.orange)
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func appStatsSection(_ viewModel: HomeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activité")
                .font(.headline)
            HStack(spacing: 12) {
                Button {
                    destination = .history
                } label: {
                    // `isLink: true` (#150) — this card and "Scans effectués" right next to it
                    // shared the exact same chrome despite only one of them going anywhere.
                    StatCard(title: "Sets scannés", value: "\(viewModel.scannedSetsCount)", icon: "number.square", isLink: true)
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
                // Two rows of two rather than one row of four (#185) — a fourth tile in a single
                // `HStack` left every title cramped enough to truncate (even "Statistiques", which
                // already clipped to "Sta-tist…" at three).
                VStack(spacing: 12) {
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
                            StatCard(title: "Sets possédés", value: "\(viewModel.ownedSetsCount)", icon: "shippingbox", isLink: true)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 12) {
                        Button {
                            destination = .minifigs
                        } label: {
                            StatCard(title: "Mes minifigs", value: "\(viewModel.ownedMinifigsCount)", icon: "person.fill", isLink: true)
                        }
                        .buttonStyle(.plain)

                        Button {
                            destination = .newSets
                        } label: {
                            statCardLink(title: "Nouveaux sets", icon: "sparkles")
                        }
                        .buttonStyle(.plain)
                    }
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let errorMessage = viewModel.syncErrorMessage {
                        // Was plain `.caption`/`.secondary` — identical to the neutral "Dernière
                        // synchronisation" line right below it (#149), so a failed sync read as
                        // just another status update.
                        InlineErrorLabel(message: errorMessage, font: .caption)
                    } else if let lastSyncedAt = viewModel.lastSyncedAt {
                        Text("Dernière synchronisation : \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(" ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                    StatCard(title: "Dans la liste cadeaux", value: "\(viewModel.wishlistSetsCount)", icon: "heart", isLink: true)
                }
                .buttonStyle(.plain)

                // Same sync as Collection (piggybacks on `syncCollection()`, see
                // `HomeViewModel`) — mirrors that section's row so both show one consistent
                // "last synced" state instead of the wishlist looking unsynced next to it.
                HStack(spacing: 6) {
                    if viewModel.isSyncing {
                        ProgressView().controlSize(.small)
                        Text("Synchronisation…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let errorMessage = viewModel.syncErrorMessage {
                        InlineErrorLabel(message: errorMessage, font: .caption)
                    } else if let lastSyncedAt = viewModel.lastSyncedAt {
                        Text("Dernière synchronisation : \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(" ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 16, alignment: .leading)
            }
        }
    }

    /// Same layout as `StatCard` (icon + two text lines) for a tile that navigates somewhere
    /// rather than displaying a count.
    private func statCardLink(title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer()
                // Was missing here (#185 feedback) — every other `isLink` tile (`StatCard(isLink:
                // true)`) already shows this trailing chevron as the "this navigates" signal.
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            // Matches `StatCard`'s reserved 2-line height (see its doc) so this card doesn't grow
            // taller than its `StatCard` neighbours in the same row just because its title wraps.
            Text(title)
                .font(.title2.bold())
                .lineLimit(2)
                .frame(minHeight: 56, alignment: .top)
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
            satelliteButton(icon: "photo.on.rectangle", accessibilityLabel: "Depuis mes photos") {
                showPhotoPicker = true
            }

            scanButton

            satelliteButton(icon: "keyboard", accessibilityLabel: "Saisie manuelle") {
                showManualEntry = true
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
