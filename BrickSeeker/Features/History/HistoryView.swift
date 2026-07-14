import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(filter: #Predicate<CachedSet> { $0.wasScanned }, sort: \CachedSet.lastScannedAt, order: .reverse)
    private var cachedSets: [CachedSet]
    @Query private var allCachedPrices: [CachedSetPrice]
    @Environment(\.modelContext) private var modelContext
    @Bindable private var filter = HistoryFilterState.shared
    @State private var showFilters = false
    @State private var showScanMap = false
    @State private var setPendingDeletion: CachedSet?
    var rebrickableRepository: RebrickableRepositoryProtocol = RebrickableRepository()
    // Wishlist is Brickset-backed, not a Rebrickable setlist (see `SetDetailViewModel
    // .toggleWishlist()`) — needed for the "Ajouter à ma liste de cadeaux" bulk action (#166).
    var bricksetRepository: BricksetRepositoryProtocol = BricksetRepository()
    let lookupViewModel: ScannerViewModel
    let onSelect: (String) -> Void

    /// Memoized from `allCachedPrices` (see the `.onChange` in `body`) — rebuilding this
    /// dictionary was previously a computed property re-run on every keystroke in the search bar.
    @State private var pricesBySetNum: [String: [PriceQuote]] = [:]

    @State private var isSelecting = false
    @State private var selectedSetNums: Set<String> = []
    @State private var isPerformingBulkAction = false
    @State private var selectionActionError: String?
    @State private var showRemoveScansConfirmation = false
    @State private var showAddToListPicker = false
    /// Sets targeted by the next `showAddToListPicker` flow — either the current multi-select
    /// checkbox selection, or the single row long-pressed for a context menu action (#172), set
    /// right before presenting the sheet.
    @State private var pendingActionTargets: [CachedSet] = []

    private var filteredSets: [CachedSet] { cachedSets.filteredAndSorted(by: filter, resolvedPrice: resolvedPrice) }
    private var selectedCachedSets: [CachedSet] { filteredSets.filter { selectedSetNums.contains($0.setNum) } }
    private var availableThemeIds: [Int] { Set(cachedSets.map(\.themeId)).sorted() }
    private var availableYears: [Int] { Set(cachedSets.map(\.year)).sorted(by: >) }

    private var areAllFilteredSelected: Bool {
        !filteredSets.isEmpty && filteredSets.allSatisfy { selectedSetNums.contains($0.setNum) }
    }

    private func toggleSelection(_ setNum: String) {
        if selectedSetNums.contains(setNum) {
            selectedSetNums.remove(setNum)
        } else {
            selectedSetNums.insert(setNum)
        }
    }

    /// Selects/deselects only the sets currently visible under the active filters/search (#164)
    /// — never the whole scan history.
    private func toggleSelectAll() {
        if areAllFilteredSelected {
            selectedSetNums.subtract(filteredSets.map(\.setNum))
        } else {
            selectedSetNums.formUnion(filteredSets.map(\.setNum))
        }
    }

    private func resolvedPrice(for cached: CachedSet) -> Double? {
        resolveNewPrice(storePriceEUR: cached.storePriceEUR, quotes: pricesBySetNum[cached.setNum] ?? [])
    }

    /// Reuses `CollectionPriceUpdater.shared`, same as `CollectionView`'s bulk refresh (#141) —
    /// a single global run, so a concurrent/paused unrelated job means `.busy`, not silently
    /// hijacking that other queue. Shared by the bulk menu and the row context menu (#172), which
    /// pass the filtered selection / `[cached]` respectively.
    private func refreshPrices(for sets: [CachedSet]) async {
        selectionActionError = nil
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let outcome = await CollectionPriceUpdater.shared.refreshPrices(
            for: sets.map { $0.asLegoSet() },
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

    /// Adds every set in `sets` to `listId` on Rebrickable — same as `WishlistView`'s bulk action
    /// (#141): a scanned set isn't necessarily owned, so this just adds it to the chosen list.
    /// Shared by the bulk menu and the row context menu (`[cached]`, via `pendingActionTargets`, #172).
    private func addToCollection(_ sets: [CachedSet], listId: Int, listName: String) async {
        selectionActionError = nil
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in sets {
            do {
                try await rebrickableRepository.addSetToList(setNum: cached.setNum, listId: listId)
                localRepository.setCollectionStatus(setNum: cached.setNum, isInCollection: true, listId: listId, listName: listName)
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

    /// Adds every set in `sets` to the Brickset wishlist (#166) — same repository/local-cache
    /// pairing as `SetDetailViewModel.toggleWishlist()`'s add branch, looped over the selection.
    /// Shared by the bulk menu and the row context menu (`[cached]`, #172).
    private func addToWishlist(_ sets: [CachedSet]) async {
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
        for cached in sets {
            do {
                try await bricksetRepository.addToWishlist(setNum: cached.setNum)
                localRepository.setWishlistStatus(setNum: cached.setNum, isInWishlist: true)
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

    /// Reuses `deleteFromHistory` — the same per-item logic already wired to the row's swipe
    /// action, just looped over the selection instead of one `CachedSet`.
    private func removeSelectedScans() {
        let repository = LocalRepository(modelContext: modelContext)
        for setNum in selectedSetNums {
            repository.deleteFromHistory(setNum: setNum)
        }
        isSelecting = false
    }

    var body: some View {
        Group {
            if cachedSets.isEmpty {
                ContentUnavailableView(
                    "Aucun set scanné",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Les sets que vous scannez apparaîtront ici.")
                )
            } else if filteredSets.isEmpty {
                ContentUnavailableView(
                    "Aucun résultat",
                    systemImage: "magnifyingglass",
                    description: Text("Essayez de modifier la recherche ou les filtres.")
                )
            } else {
                // No `List(selection:)` binding — its native circle can't be moved off the
                // leading edge (#161), so selection is homemade: the row's own tap either
                // toggles it or navigates, never both (#165).
                List(filteredSets, id: \.setNum) { cached in
                    Button {
                        if isSelecting {
                            toggleSelection(cached.setNum)
                        } else {
                            // Deliberately no dismiss() here: pushed onto Home's NavigationStack
                            // like Collection/Wishlist (#141) — Home's own (ungated)
                            // lookupResultSheets presents SetDetail on top of the whole stack, so
                            // closing it reveals History again, not Home.
                            onSelect(cached.setNum)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SetRowView(
                                setNum: cached.setNum,
                                name: cached.name,
                                setImgUrl: cached.setImgUrl,
                                resolvedPrice: resolvedPrice(for: cached),
                                priceLabel: "Neuf",
                                isInWishlist: cached.isInWishlist
                            ) {
                                if cached.isInCollection {
                                    // Color-only signal before this (#143) — a green checkmark
                                    // reads as "owned" only if you can see green.
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("Dans votre collection")
                                }
                            }
                            if isSelecting {
                                RowSelectionIndicator(isSelected: selectedSetNums.contains(cached.setNum))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        // Hidden while selecting — the row's own tap is repurposed for selection
                        // (#165); a swipe shouldn't offer a second, unguarded way to mutate state.
                        if !isSelecting {
                            Button(role: .destructive) {
                                setPendingDeletion = cached
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                    }
                    // Long-press shortcut for the same actions as the multi-select "Actions" menu
                    // below, applied to this single set (#172). Hidden while selecting — the two
                    // selection modes don't cohabit. "Retirer le scan" reuses `setPendingDeletion`,
                    // the exact same confirmation flow already wired to the swipe action above.
                    .contextMenu {
                        if !isSelecting {
                            Button {
                                Task { await refreshPrices(for: [cached]) }
                            } label: {
                                Label("Actualiser les prix", systemImage: "arrow.clockwise")
                            }
                            Button {
                                pendingActionTargets = [cached]
                                showAddToListPicker = true
                            } label: {
                                Label("Ajouter à la collection", systemImage: "shippingbox")
                            }
                            Button {
                                Task { await addToWishlist([cached]) }
                            } label: {
                                Label("Ajouter à ma liste de cadeaux", systemImage: "heart")
                            }
                            Button(role: .destructive) {
                                setPendingDeletion = cached
                            } label: {
                                Label("Retirer le scan", systemImage: "trash")
                            }
                        }
                    }
                }
                .contentMargins(.top, 0, for: .scrollContent)
            }
        }
        .searchable(text: $filter.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nom ou numéro de set")
        .navigationTitle("Historique")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showScanMap = true
                } label: {
                    Image(systemName: "map")
                }
                .accessibilityLabel("Carte des scans")
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
            // Pinned to the bottom bar (not the nav bar) — see the matching comment in
            // CollectionView (#141): iOS hides the top nav bar's toolbar items while the search
            // field is focused, which used to make this button unreachable mid-search.
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    Button(areAllFilteredSelected ? "Tout désélectionner" : "Tout sélectionner") {
                        toggleSelectAll()
                    }
                    .disabled(filteredSets.isEmpty)
                }
                Spacer()
                if isSelecting {
                    Menu {
                        Button {
                            Task { await refreshPrices(for: selectedCachedSets) }
                        } label: {
                            Label("Actualiser les prix", systemImage: "arrow.clockwise")
                        }
                        Button {
                            pendingActionTargets = selectedCachedSets
                            showAddToListPicker = true
                        } label: {
                            Label("Ajouter à la collection", systemImage: "shippingbox")
                        }
                        Button {
                            Task { await addToWishlist(selectedCachedSets) }
                        } label: {
                            Label("Ajouter à ma liste de cadeaux", systemImage: "heart")
                        }
                        // Not `role: .destructive` — SwiftUI previews a destructive Menu item
                        // across the List's selected rows the instant the Menu opens (a red
                        // flash on the selection background), not just on tap. The icon still
                        // renders in the app's red accent color either way.
                        Button {
                            showRemoveScansConfirmation = true
                        } label: {
                            Label("Retirer tous les scans", systemImage: "trash")
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
                        // `square.and.pencil` (compose/edit) + "Actions" said neither "select"
                        // nor "multiple" (#151) — `checklist` + "Sélectionner" names what tapping
                        // it actually does.
                        Image(systemName: "checklist")
                    }
                }
                .accessibilityLabel(isSelecting ? "Terminé" : "Sélectionner plusieurs sets")
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
        .alert("Retirer ces sets de l'Historique ?", isPresented: $showRemoveScansConfirmation) {
            Button("Retirer", role: .destructive) {
                removeSelectedScans()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les sets encore dans votre Collection y resteront, mais disparaîtront de l'Historique.")
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
        .sheet(isPresented: $showScanMap) {
            ScanMapView { setNum in
                // Dismiss the map first, then resolve on the next runloop tick — the result
                // sheet is presented by this same view, and presenting it in the same
                // transaction as dismissing the map is unreliable in SwiftUI (same pattern
                // as BatchSessionSummaryView).
                showScanMap = false
                DispatchQueue.main.async {
                    onSelect(setNum)
                }
            }
        }
        .alert(
            "Retirer de l'Historique ?",
            isPresented: Binding(
                get: { setPendingDeletion != nil },
                set: { if !$0 { setPendingDeletion = nil } }
            ),
            presenting: setPendingDeletion
        ) { cached in
            Button("Retirer", role: .destructive) {
                LocalRepository(modelContext: modelContext).deleteFromHistory(setNum: cached.setNum)
            }
            Button("Annuler", role: .cancel) {}
        } message: { cached in
            if cached.isInCollection {
                Text("« \(cached.name) » restera dans votre Collection, mais disparaîtra de l'Historique.")
            } else {
                Text("Tous les scans de « \(cached.name) » seront supprimés.")
            }
        }
        .sheet(isPresented: $showFilters) {
            SetFilterSheet(
                filter: filter,
                availableThemeIds: availableThemeIds,
                availableYears: availableYears,
                availableListNames: [],
                showsOwnedFilter: true,
                themeName: { ThemeNameStore.shared.displayName(forThemeId: $0) },
                excludedSortOptions: [.dateAdded]
            )
        }
        .task {
            await ThemeNameStore.shared.refreshIfNeeded()
        }
        .onChange(of: SetPriceIndex.Version(allCachedPrices), initial: true) { _, _ in
            pricesBySetNum = SetPriceIndex.pricesBySetNum(allCachedPrices)
        }
        // No `onDisappear` filter reset (#153) — `HistoryFilterState` is a process-lifetime
        // singleton precisely so the filter survives this view being torn down and recreated by
        // a push/pop (see AGENTS.md); opening a set from a filtered list and coming back used to
        // silently drop the filter every time.
    }
}
