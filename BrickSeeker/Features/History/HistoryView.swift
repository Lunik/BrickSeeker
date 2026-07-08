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
    let lookupViewModel: ScannerViewModel
    let onSelect: (String) -> Void

    /// Memoized from `allCachedPrices` (see the `.onChange` in `body`) — rebuilding this
    /// dictionary was previously a computed property re-run on every keystroke in the search bar.
    @State private var pricesBySetNum: [String: [PriceQuote]] = [:]

    @State private var editMode: EditMode = .inactive
    @State private var selectedSetNums: Set<String> = []
    @State private var isPerformingBulkAction = false
    @State private var selectionActionError: String?
    @State private var showRemoveScansConfirmation = false
    @State private var showAddToListPicker = false

    private var filteredSets: [CachedSet] { cachedSets.filteredAndSorted(by: filter, resolvedPrice: resolvedPrice) }
    private var availableThemeIds: [Int] { Set(cachedSets.map(\.themeId)).sorted() }
    private var availableYears: [Int] { Set(cachedSets.map(\.year)).sorted(by: >) }

    private func resolvedPrice(for cached: CachedSet) -> Double? {
        resolveNewPrice(storePriceEUR: cached.storePriceEUR, quotes: pricesBySetNum[cached.setNum] ?? [])
    }

    /// Reuses `CollectionPriceUpdater.shared`, same as `CollectionView`'s bulk refresh (#141) —
    /// a single global run, so a concurrent/paused unrelated job means `.busy`, not silently
    /// hijacking that other queue.
    private func refreshSelectedPrices() async {
        selectionActionError = nil
        let selected = filteredSets.filter { selectedSetNums.contains($0.setNum) }
        guard !selected.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let outcome = await CollectionPriceUpdater.shared.refreshPrices(
            for: selected.map { $0.asLegoSet() },
            persist: CollectionPriceUpdater.persistClosure(modelContext: modelContext)
        )

        switch outcome {
        case .completed:
            editMode = .inactive
        case .busy:
            selectionActionError = String(
                localized: "Une actualisation des prix de la collection est déjà en cours ou en attente de reprise. Terminez-la avant d'actualiser une sélection."
            )
        case .cancelled:
            break
        }
    }

    /// Adds every selected set to `listId` on Rebrickable — same as `WishlistView`'s bulk action
    /// (#141): a scanned set isn't necessarily owned, so this just adds it to the chosen list.
    private func addSelectedToCollection(listId: Int, listName: String) async {
        selectionActionError = nil
        let selected = filteredSets.filter { selectedSetNums.contains($0.setNum) }
        guard !selected.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in selected {
            do {
                try await rebrickableRepository.addSetToList(setNum: cached.setNum, listId: listId)
                localRepository.setCollectionStatus(setNum: cached.setNum, isInCollection: true, listId: listId, listName: listName)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = String(localized: "\(failureCount) set(s) n'ont pas pu être ajoutés à la collection. Vérifiez votre connexion.")
        } else {
            editMode = .inactive
        }
    }

    /// Reuses `deleteFromHistory` — the same per-item logic already wired to the row's swipe
    /// action, just looped over the selection instead of one `CachedSet`.
    private func removeSelectedScans() {
        let repository = LocalRepository(modelContext: modelContext)
        for setNum in selectedSetNums {
            repository.deleteFromHistory(setNum: setNum)
        }
        editMode = .inactive
    }

    var body: some View {
        Group {
            if cachedSets.isEmpty {
                ContentUnavailableView(
                    "Aucun set scanné",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Les sets que tu scannes apparaîtront ici.")
                )
            } else if filteredSets.isEmpty {
                ContentUnavailableView(
                    "Aucun résultat",
                    systemImage: "magnifyingglass",
                    description: Text("Essayez de modifier la recherche ou les filtres.")
                )
            } else {
                List(filteredSets, id: \.setNum, selection: $selectedSetNums) { cached in
                    Button {
                        // Deliberately no dismiss() here: pushed onto Home's NavigationStack like
                        // Collection/Wishlist (#141) — Home's own (ungated) lookupResultSheets
                        // presents SetDetail on top of the whole stack, so closing it reveals
                        // History again, not Home.
                        onSelect(cached.setNum)
                    } label: {
                        SetRowView(
                            setNum: cached.setNum,
                            name: cached.name,
                            setImgUrl: cached.setImgUrl,
                            resolvedPrice: resolvedPrice(for: cached),
                            isInWishlist: cached.isInWishlist
                        ) {
                            if cached.isInCollection {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            setPendingDeletion = cached
                        } label: {
                            Label("Supprimer", systemImage: "trash")
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
                Spacer()
                if editMode.isEditing {
                    Menu {
                        Button {
                            Task { await refreshSelectedPrices() }
                        } label: {
                            Label("Actualiser les prix", systemImage: "arrow.clockwise")
                        }
                        Button {
                            showAddToListPicker = true
                        } label: {
                            Label("Ajouter à la collection", systemImage: "shippingbox")
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
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                } label: {
                    if editMode.isEditing {
                        Text("Terminé")
                    } else {
                        Image(systemName: "square.and.pencil")
                    }
                }
                .accessibilityLabel(editMode.isEditing ? "Terminé" : "Actions")
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing {
                selectedSetNums.removeAll()
            }
        }
        .sheet(isPresented: $showAddToListPicker) {
            ListPickerView(repository: rebrickableRepository) { listId, listName in
                Task { await addSelectedToCollection(listId: listId, listName: listName) }
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
                Text("« \(cached.name) » restera dans ta Collection, mais disparaîtra de l'Historique.")
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
                themeName: { ThemeNameStore.shared.displayName(forThemeId: $0) }
            )
        }
        .task {
            await ThemeNameStore.shared.refreshIfNeeded()
        }
        .onChange(of: SetPriceIndex.Version(allCachedPrices), initial: true) { _, _ in
            pricesBySetNum = SetPriceIndex.pricesBySetNum(allCachedPrices)
        }
        .onDisappear {
            HistoryFilterState.shared.resetFilters()
        }
    }
}
