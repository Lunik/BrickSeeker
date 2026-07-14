import SwiftUI
import SwiftData

/// "Nouveaux sets" (issue #185): browses the whole offline catalogue (`OfflineCatalogStore`,
/// ~27k sets, already downloaded/refreshed independently from Settings or the button below).
/// Rebrickable exposes no real "date added to catalogue" field (confirmed against the community
/// OpenAPI spec), so this device tracks it locally instead — `OfflineCatalogStore
/// .allFirstSeenAt()` stamps each `set_num` the instant a download first contains it, and
/// `NewSetsFilterState`'s default `.dateAdded` sort uses that. `.year` (the set's real-world
/// release year, far coarser — hundreds of sets share one value) is still offered as an
/// alternative. Nothing is hard-filtered out either way: search/theme/year filters still reach
/// every year.
///
/// Same shared list pattern as `HistoryView`/`CollectionView` (see AGENTS.md), not the gallery
/// variant — the issue's own file-level instructions name `SetRowView` explicitly. The dataset is
/// catalogue-sized rather than personal-history-sized though, which matters for two things this
/// view borrows from `MinifigGalleryView` instead of `HistoryView`: local `displayedCount`
/// windowing (see its own doc comment) and scoping "select all" to `windowed` rather than every
/// filtered match (an unscoped select-all here could queue thousands of sequential price-scrape/
/// add requests).
struct NewSetsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allCachedSets: [CachedSet]
    @Query private var allCachedPrices: [CachedSetPrice]
    @State private var viewModel = NewSetsViewModel()
    @Bindable private var filter = NewSetsFilterState.shared
    @State private var showFilters = false
    @State private var displayedCount = Self.pageSize

    @State private var isSelecting = false
    @State private var selectedSetNums: Set<String> = []
    @State private var isPerformingBulkAction = false
    @State private var selectionActionError: String?
    @State private var showAddToListPicker = false
    /// Sets targeted by the next `showAddToListPicker` flow — either the current multi-select
    /// checkbox selection, or the single row long-pressed for a context menu action, set right
    /// before presenting the sheet (same pattern as `HistoryView`/`CollectionView`).
    @State private var pendingActionTargets: [LegoSet] = []

    var rebrickableRepository: RebrickableRepositoryProtocol = RebrickableRepository()
    /// Wishlist is Brickset-backed, not a Rebrickable setlist — see `SetDetailViewModel
    /// .toggleWishlist()` and AGENTS.md — needed for the "Ajouter à ma liste de cadeaux" action.
    var bricksetRepository: BricksetRepositoryProtocol = BricksetRepository()
    let lookupViewModel: ScannerViewModel

    /// Memoized from `allCachedPrices` (see the `.onChange` in `body`), same reasoning as every
    /// other list screen: rebuilding this dictionary on every keystroke in the search bar would be
    /// wasteful.
    @State private var pricesBySetNum: [String: [PriceQuote]] = [:]

    private static let pageSize = 60

    private struct FilterSignature: Equatable {
        let searchText: String
        let themeName: String?
        let year: Int?
        let ownedOnly: Bool?
        let sort: SetSortOption
        let sortAscending: Bool
    }

    private var filterSignature: FilterSignature {
        FilterSignature(
            searchText: filter.searchText, themeName: filter.themeName, year: filter.year,
            ownedOnly: filter.ownedOnly, sort: filter.sort, sortAscending: filter.sortAscending
        )
    }

    /// Local cache cross-reference, rebuilt once per body evaluation from the (small — hundreds,
    /// not tens of thousands) set of rows the user has actually scanned/owned/wishlisted — used
    /// for the row's ownership checkmark/wishlist heart and to preserve known status before a
    /// cache write (see `ensureCached`). Mirrors `MinifigGalleryView.ownedQuantityByFigNum`'s
    /// "compute once, not per row" reasoning.
    private var cachedByNum: [String: CachedSet] {
        Dictionary(allCachedSets.map { ($0.setNum, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func resolvedPrice(for legoSet: LegoSet) -> Double? {
        resolveNewPrice(storePriceEUR: cachedByNum[legoSet.setNum]?.storePriceEUR, quotes: pricesBySetNum[legoSet.setNum] ?? [])
    }

    private func toggleSelection(_ setNum: String) {
        if selectedSetNums.contains(setNum) {
            selectedSetNums.remove(setNum)
        } else {
            selectedSetNums.insert(setNum)
        }
    }

    /// Scoped to `entries` (always `windowed` in practice) rather than every filtered match — see
    /// the type doc for why an unbounded "select all" is unsafe against this catalogue's size.
    private func toggleSelectAll(_ entries: [LegoSet]) {
        let setNums = entries.map(\.setNum)
        if setNums.allSatisfy(selectedSetNums.contains) {
            selectedSetNums.subtract(setNums)
        } else {
            selectedSetNums.formUnion(setNums)
        }
    }

    /// Ensures a `CachedSet` row exists before writing collection/wishlist status onto it — most
    /// New Sets entries have never been scanned/owned, and `LocalRepository.setCollectionStatus`/
    /// `setWishlistStatus` silently no-op without an existing row (see AGENTS.md). Preserves
    /// whatever collection status is already locally known instead of clobbering it with
    /// false/nil. Mirrors `MinifigGalleryView.cacheEntryIfNeeded`.
    private func ensureCached(_ legoSet: LegoSet, using localRepository: LocalRepository) {
        let existing = cachedByNum[legoSet.setNum]
        localRepository.cacheSet(
            legoSet,
            isInCollection: existing?.isInCollection ?? false,
            listId: existing?.currentListId,
            listName: existing?.currentListName,
            markAsScanned: false
        )
    }

    /// Opens the same `SetDetailView` sheet as every other list/gallery screen
    /// (`lookupViewModel.lookupSetNumber`, `.listReopen` records no scan event and doesn't flip
    /// `wasScanned` — see `ScannerViewModel.LookupSource`). Seeds the `CachedSet` row first so the
    /// cache-hit path shows it instantly from already-known offline data instead of waiting on a
    /// live round-trip.
    private func openDetail(for legoSet: LegoSet) {
        if let localRepository = lookupViewModel.localRepository {
            ensureCached(legoSet, using: localRepository)
        }
        lookupViewModel.lookupSetNumber(legoSet.setNum, source: .listReopen)
    }

    /// Reuses `CollectionPriceUpdater.shared`, same singleton every other list screen's bulk/
    /// context-menu "Actualiser les prix" drives (#141/#172). No `ensureCached` first: unlike
    /// collection/wishlist status, `LocalRepository.cachePrices`/`cacheStorePrice` write to
    /// `CachedSetPrice` rows keyed by `setNum` directly, not through an existing `CachedSet` row
    /// (same reasoning as `MinifigGalleryView.refreshPrices`'s doc comment).
    private func refreshPrices(for sets: [LegoSet]) async {
        selectionActionError = nil
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let outcome = await CollectionPriceUpdater.shared.refreshPrices(
            for: sets,
            persist: CollectionPriceUpdater.persistClosure(modelContext: modelContext)
        )

        switch outcome {
        case .completed:
            isSelecting = false
        case .busy:
            selectionActionError = String(
                localized: "Une actualisation des prix de la collection est déjà en cours ou en attente de reprise. Terminez-la avant d'actualiser une sélection."
            )
        case .cancelled:
            break
        }
    }

    /// Adds every set in `sets` to `listId` on Rebrickable, same as `HistoryView`'s bulk action —
    /// a New Sets entry isn't necessarily owned, so this just adds it. `cacheSet` upserts (creates
    /// the row if this entry was never scanned/owned before, updates it otherwise) — unlike
    /// `HistoryView`/`CollectionView`, a plain `setCollectionStatus` call would silently no-op here
    /// since most entries have no existing `CachedSet` row yet (see AGENTS.md).
    private func addToCollection(_ sets: [LegoSet], listId: Int, listName: String) async {
        selectionActionError = nil
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for legoSet in sets {
            do {
                try await rebrickableRepository.addSetToList(setNum: legoSet.setNum, listId: listId)
                localRepository.cacheSet(legoSet, isInCollection: true, listId: listId, listName: listName, markAsScanned: false)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = setsCountSentence(
                failureCount,
                singular: "n'a pas pu être ajouté à la collection. Vérifiez votre connexion.",
                plural: "n'ont pas pu être ajoutés à la collection. Vérifiez votre connexion."
            )
        } else {
            isSelecting = false
        }
    }

    /// Adds every set in `sets` to the Brickset wishlist, same repository/local-cache pairing as
    /// `HistoryView`'s equivalent action — except `ensureCached` runs first here, since
    /// `cacheWishlistSet` can't update a row that already exists and `setWishlistStatus` can't
    /// create one that doesn't (see `ensureCached`'s doc).
    private func addToWishlist(_ sets: [LegoSet]) async {
        selectionActionError = nil
        guard NetworkMonitor.shared.isConnected else {
            selectionActionError = UserMessage.offlineStatus
            return
        }
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for legoSet in sets {
            do {
                try await bricksetRepository.addToWishlist(setNum: legoSet.setNum)
                ensureCached(legoSet, using: localRepository)
                localRepository.setWishlistStatus(setNum: legoSet.setNum, isInWishlist: true)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = setsCountSentence(
                failureCount,
                singular: "n'a pas pu être ajouté à la liste cadeaux. Vérifiez votre connexion.",
                plural: "n'ont pas pu être ajoutés à la liste cadeaux. Vérifiez votre connexion."
            )
        } else {
            isSelecting = false
        }
    }

    var body: some View {
        let filteredSorted = viewModel.allSets.filteredAndSorted(
            by: filter,
            owned: { cachedByNum[$0]?.isInCollection ?? false },
            resolvedPrice: resolvedPrice(for:),
            firstSeenAt: { viewModel.firstSeenBySetNum[$0] },
            themeName: { ThemeNameStore.shared.displayName(forThemeId: $0) }
        )
        let windowed = Array(filteredSorted.prefix(displayedCount))
        let areAllWindowedSelected = !windowed.isEmpty && windowed.allSatisfy { selectedSetNums.contains($0.setNum) }
        let selectedSets = windowed.filter { selectedSetNums.contains($0.setNum) }

        Group {
            if !viewModel.hasCatalog {
                emptyCatalogView
            } else if viewModel.allSets.isEmpty && viewModel.isLoadingCatalog {
                ProgressView("Chargement du catalogue…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.allSets.isEmpty {
                // Distinct from the "Aucun résultat" case below: nothing has ever been confirmed
                // new since the baseline sync (see `NewSetsViewModel.loadCatalog`'s doc), not "the
                // search/filters excluded everything" — different cause, different copy/action.
                noNewSetsYetView
            } else if filteredSorted.isEmpty {
                ContentUnavailableView(
                    "Aucun résultat",
                    systemImage: "magnifyingglass",
                    description: Text("Essayez de modifier la recherche ou les filtres.")
                )
            } else {
                List {
                    ForEach(windowed, id: \.setNum) { legoSet in
                        Button {
                            if isSelecting {
                                toggleSelection(legoSet.setNum)
                            } else {
                                openDetail(for: legoSet)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                SetRowView(
                                    setNum: legoSet.setNum,
                                    name: legoSet.name,
                                    setImgUrl: legoSet.setImgUrl,
                                    resolvedPrice: resolvedPrice(for: legoSet),
                                    isInWishlist: cachedByNum[legoSet.setNum]?.isInWishlist ?? false
                                ) {
                                    if cachedByNum[legoSet.setNum]?.isInCollection == true {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.green)
                                            .accessibilityLabel("Dans votre collection")
                                    }
                                }
                                if isSelecting {
                                    RowSelectionIndicator(isSelected: selectedSetNums.contains(legoSet.setNum))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !isSelecting {
                                Button {
                                    Task { await refreshPrices(for: [legoSet]) }
                                } label: {
                                    Label("Actualiser les prix", systemImage: "arrow.clockwise")
                                }
                                Button {
                                    pendingActionTargets = [legoSet]
                                    showAddToListPicker = true
                                } label: {
                                    Label("Ajouter à la collection", systemImage: "shippingbox")
                                }
                                Button {
                                    Task { await addToWishlist([legoSet]) }
                                } label: {
                                    Label("Ajouter à ma liste de cadeaux", systemImage: "heart")
                                }
                            }
                        }
                    }

                    if displayedCount < filteredSorted.count {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .onAppear { displayedCount += Self.pageSize }
                    }
                }
                .contentMargins(.top, 0, for: .scrollContent)
            }
        }
        .searchable(text: $filter.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nom ou numéro de set")
        .navigationTitle("Nouveaux sets")
        .toolbar {
            if viewModel.hasCatalog {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.downloadCatalog() }
                    } label: {
                        if viewModel.isDownloadingCatalog {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isDownloadingCatalog)
                    .accessibilityLabel("Actualiser le catalogue")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: filter.isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filtres")
                .accessibilityValue(filter.isFilterActive ? "Actifs" : "Inactifs")
            }
            // Pinned to the bottom bar (not the nav bar) — iOS hides the top nav bar's own
            // toolbar items while the search field is focused (#141).
            if !viewModel.allSets.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    if isSelecting {
                        Button(areAllWindowedSelected ? "Tout désélectionner" : "Tout sélectionner") {
                            toggleSelectAll(windowed)
                        }
                        .disabled(windowed.isEmpty)
                    }
                    Spacer()
                    if isSelecting {
                        Menu {
                            Button {
                                Task { await refreshPrices(for: selectedSets) }
                            } label: {
                                Label("Actualiser les prix", systemImage: "arrow.clockwise")
                            }
                            Button {
                                pendingActionTargets = selectedSets
                                showAddToListPicker = true
                            } label: {
                                Label("Ajouter à la collection", systemImage: "shippingbox")
                            }
                            Button {
                                Task { await addToWishlist(selectedSets) }
                            } label: {
                                Label("Ajouter à ma liste de cadeaux", systemImage: "heart")
                            }
                        } label: {
                            if isPerformingBulkAction {
                                ProgressView()
                            } else {
                                Label("Actions (\(selectedSetNums.count))", systemImage: "ellipsis.circle")
                            }
                        }
                        .disabled(selectedSetNums.isEmpty || isPerformingBulkAction)
                    }
                    Button {
                        withAnimation { isSelecting.toggle() }
                    } label: {
                        if isSelecting {
                            Text("Terminé")
                        } else {
                            Image(systemName: "checklist")
                        }
                    }
                    .disabled(isSelecting && isPerformingBulkAction)
                    .accessibilityLabel(isSelecting ? "Terminé" : "Sélectionner plusieurs sets")
                }
            }
        }
        .onChange(of: isSelecting) { _, newValue in
            if !newValue {
                selectedSetNums.removeAll()
            }
        }
        .sheet(isPresented: $showAddToListPicker) {
            ListPickerView(repository: rebrickableRepository) { listId, listName in
                Task { await addToCollection(pendingActionTargets, listId: listId, listName: listName) }
            }
        }
        .alert(
            "Action impossible",
            isPresented: Binding(
                get: { selectionActionError != nil },
                set: { isPresented in if !isPresented { selectionActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(selectionActionError ?? "")
        }
        .sheet(isPresented: $showFilters) {
            SetFilterSheet(
                filter: filter,
                availableThemeIds: viewModel.availableThemeIds,
                availableYears: viewModel.availableYears,
                availableListNames: [],
                showsOwnedFilter: true,
                themeName: { ThemeNameStore.shared.displayName(forThemeId: $0) },
                excludedSortOptions: [.dateScanned]
            )
        }
        .onChange(of: filterSignature) { _, _ in displayedCount = Self.pageSize }
        .onChange(of: SetPriceIndex.Version(allCachedPrices), initial: true) { _, _ in
            pricesBySetNum = SetPriceIndex.pricesBySetNum(allCachedPrices)
        }
        .task {
            await ThemeNameStore.shared.refreshIfNeeded()
            await viewModel.loadCatalog()
        }
        // No `.onDisappear` filter reset — `NewSetsFilterState` is a process-lifetime singleton
        // precisely so the filter survives this view being torn down and recreated by a push/pop,
        // same reasoning as `HistoryFilterState` (see AGENTS.md).
    }

    private var emptyCatalogView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Catalogue non téléchargé")
                .font(.headline)
            Text("Téléchargez le catalogue Rebrickable (~27 000 sets) pour découvrir les nouveautés. Peut aussi se faire depuis Réglages.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if viewModel.isDownloadingCatalog {
                ProgressView(value: viewModel.downloadProgress)
                    .frame(maxWidth: 200)
                Text(viewModel.downloadProgress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Télécharger le catalogue") {
                    Task { await viewModel.downloadCatalog() }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.shared.accent)
            }

            if let errorMessage = viewModel.downloadErrorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.brickDanger)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when the catalogue is downloaded but `viewModel.allSets` is empty — nothing has been
    /// confirmed added to Rebrickable's catalogue since the baseline sync yet (see
    /// `NewSetsViewModel.loadCatalog`'s doc), including right after that very first sync, where
    /// this is the expected, not broken, result. Distinct copy from "Aucun résultat" below (that
    /// one means the search/filters excluded everything, not that there's genuinely nothing new).
    private var noNewSetsYetView: some View {
        ContentUnavailableView {
            Label("Aucun nouveau set pour l'instant", systemImage: "sparkles")
        } description: {
            Text("Les sets ajoutés au catalogue Rebrickable depuis votre dernière synchronisation apparaîtront ici.")
        } actions: {
            Button("Actualiser le catalogue") {
                Task { await viewModel.downloadCatalog() }
            }
            .disabled(viewModel.isDownloadingCatalog)
        }
    }
}
