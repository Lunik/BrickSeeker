import SwiftUI
import SwiftData

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allCachedPrices: [CachedSetPrice]
    @Query private var allCachedSetLists: [CachedSetList]
    @State private var viewModel: CollectionViewModel?
    @State private var showFilters = false
    @State private var showSettings = false
    @Bindable private var filter = CollectionFilterState.shared
    let lookupViewModel: ScannerViewModel
    var rebrickableRepository: RebrickableRepositoryProtocol = RebrickableRepository()

    /// Memoized from `allCachedPrices` (see the `.onChange` in `body`) — rebuilding this
    /// dictionary was previously a computed property re-run on every keystroke in the search bar.
    @State private var pricesBySetNum: [String: [PriceQuote]] = [:]

    @State private var isSelecting = false
    @State private var selectedSetNums: Set<String> = []
    @State private var isPerformingBulkAction = false
    @State private var selectionActionError: String?
    @State private var showMoveListPicker = false
    @State private var showRemoveConfirmation = false
    /// Sets targeted by the next `showMoveListPicker`/`showRemoveConfirmation` flow — either the
    /// current multi-select checkbox selection, or the single row long-pressed for a context menu
    /// action (#172), set right before presenting the sheet/alert.
    @State private var pendingActionTargets: [CachedSet] = []

    private var conditionByListId: [Int: ListCondition] {
        Dictionary(allCachedSetLists.map { ($0.listId, $0.condition) }, uniquingKeysWith: { first, _ in first })
    }

    /// Hoisted out of `body` (unlike before #161/#164) so the bottom toolbar's "Tout
    /// sélectionner" can read the same filtered/searched set the list is currently showing.
    private var filteredSets: [CachedSet] {
        guard let viewModel else { return [] }
        return viewModel.cachedSets.filteredAndSorted(by: filter, resolvedPrice: resolvedPrice)
    }

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
    /// — never the whole underlying collection.
    private func toggleSelectAll() {
        if areAllFilteredSelected {
            selectedSetNums.subtract(filteredSets.map(\.setNum))
        } else {
            selectedSetNums.formUnion(filteredSets.map(\.setNum))
        }
    }

    private func resolvedPrice(for cached: CachedSet) -> Double? {
        let condition = cached.currentListId.flatMap { conditionByListId[$0] }
        return resolveCollectionPrice(
            storePriceEUR: cached.storePriceEUR,
            condition: condition,
            quotes: pricesBySetNum[cached.setNum] ?? []
        )
    }

    private var selectedCachedSets: [CachedSet] {
        guard let viewModel else { return [] }
        return viewModel.cachedSets.filter { selectedSetNums.contains($0.setNum) }
    }

    /// "Refresh prices" action, reusing `CollectionPriceUpdater.shared` — the same singleton
    /// driven by `CollectionPriceUpdateSection` from Réglages — rather than a parallel pipeline
    /// (see #141). Shared by the multi-select bulk menu and the single-row context menu (#172),
    /// which pass `selectedCachedSets` / `[cached]` respectively.
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

    /// Moves every set in `sets` into `listId` on Rebrickable — a set with no known current list
    /// is added rather than moved (there's nothing to remove it from). Shared by the bulk menu
    /// (`selectedCachedSets`) and the row context menu (`[cached]`, via `pendingActionTargets`, #172).
    private func moveToList(_ sets: [CachedSet], listId: Int, listName: String) async {
        selectionActionError = nil
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in sets {
            do {
                if let fromListId = cached.currentListId, fromListId != listId {
                    try await rebrickableRepository.moveSetToList(setNum: cached.setNum, fromListId: fromListId, toListId: listId)
                } else if cached.currentListId == nil {
                    try await rebrickableRepository.addSetToList(setNum: cached.setNum, listId: listId)
                }
                localRepository.setCollectionStatus(setNum: cached.setNum, isInCollection: true, listId: listId, listName: listName)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = String(localized: "\(failureCount) set(s) n'ont pas pu être déplacés. Vérifiez votre connexion.")
        } else {
            isSelecting = false
        }
    }

    /// Shared by the bulk menu (`selectedCachedSets`) and the row context menu (`[cached]`, via
    /// `pendingActionTargets`, #172).
    private func removeFromCollection(_ sets: [CachedSet]) async {
        selectionActionError = nil
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in sets {
            do {
                try await rebrickableRepository.removeSetFromCollection(setNum: cached.setNum)
                localRepository.setCollectionStatus(setNum: cached.setNum, isInCollection: false, listId: nil, listName: nil)
            } catch {
                failureCount += 1
            }
        }

        // Removed sets drop out of `ownedSets()` — the view model's `cachedSets` is a plain
        // snapshot (not a live query), so it needs an explicit reload to stop showing them.
        viewModel?.load()

        if failureCount > 0 {
            selectionActionError = String(localized: "\(failureCount) set(s) n'ont pas pu être retirés. Vérifiez votre connexion.")
        } else {
            isSelecting = false
        }
    }

    /// True while the initial launch sync (#148) is still unresolved and the collection cache is
    /// empty — used to show a spinner instead of jumping straight to "Aucun set possédé", which
    /// would otherwise be indistinguishable from a genuinely empty collection during that window.
    private var isInitialCollectionLoad: Bool {
        (viewModel?.cachedSets.isEmpty ?? true)
            && (SyncStatusStore.shared.isSyncing || !SyncStatusStore.shared.didAttemptInitialSync)
    }

    var body: some View {
        Group {
            if let viewModel, !viewModel.cachedSets.isEmpty {
                if filteredSets.isEmpty {
                    // Was a dead end (#147): no way to recover short of manually clearing the
                    // search field and reopening the filter sheet.
                    ContentUnavailableView {
                        Label("Aucun résultat", systemImage: "magnifyingglass")
                    } description: {
                        Text("Essayez de modifier la recherche ou les filtres.")
                    } actions: {
                        Button("Réinitialiser les filtres") {
                            filter.resetFilters()
                            filter.searchText = ""
                        }
                    }
                } else {
                    List(filteredSets, id: \.setNum) { cached in
                        // No `List(selection:)` binding — its native circle can't be moved off
                        // the leading edge (#161), so selection is homemade: the row's own tap
                        // either toggles it or navigates, never both (#165).
                        Button {
                            if isSelecting {
                                toggleSelection(cached.setNum)
                            } else {
                                lookupViewModel.lookupSetNumber(cached.setNum, source: .listReopen)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                SetRowView(
                                    setNum: cached.setNum,
                                    name: cached.name,
                                    setImgUrl: cached.setImgUrl,
                                    subtitle: cached.currentListName,
                                    resolvedPrice: resolvedPrice(for: cached),
                                    isInWishlist: cached.isInWishlist,
                                    quantity: cached.quantity
                                ) {
                                    EmptyView()
                                }
                                if isSelecting {
                                    RowSelectionIndicator(isSelected: selectedSetNums.contains(cached.setNum))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        // Long-press shortcut for the same actions as the multi-select "Actions"
                        // menu below, applied to this single set (#172). Hidden while selecting —
                        // the two selection modes don't cohabit.
                        .contextMenu {
                            if !isSelecting {
                                Button {
                                    Task { await refreshPrices(for: [cached]) }
                                } label: {
                                    Label("Actualiser les prix", systemImage: "arrow.clockwise")
                                }
                                Button {
                                    pendingActionTargets = [cached]
                                    showMoveListPicker = true
                                } label: {
                                    Label("Déplacer vers une liste", systemImage: "folder")
                                }
                                // Unlike the bulk `Menu` above, a `.contextMenu` on a single row
                                // doesn't get the destructive red-flash-across-selection glitch,
                                // so `role: .destructive` is safe to use here (see #172).
                                Button(role: .destructive) {
                                    pendingActionTargets = [cached]
                                    showRemoveConfirmation = true
                                } label: {
                                    Label("Retirer de la collection", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .contentMargins(.top, 0, for: .scrollContent)
                }
            } else if isInitialCollectionLoad {
                ProgressView("Synchronisation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No way to act on this short of leaving the screen to find Settings yourself
                // (#147) — the button opens the same sheet as Home's gear icon.
                ContentUnavailableView {
                    Label("Aucun set possédé", systemImage: "shippingbox")
                } description: {
                    Text("Liez votre compte Rebrickable et synchronisez depuis l'accueil.")
                } actions: {
                    Button("Ouvrir les Réglages") {
                        showSettings = true
                    }
                }
            }
        }
        .searchable(text: $filter.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nom ou numéro de set")
        .navigationTitle("Ma collection")
        .toolbar {
            // Previously only reachable from Statistiques (#153) even though it directly affects
            // the prices shown right here in Collection.
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ListConditionsView()
                } label: {
                    Image(systemName: "tag")
                }
                .accessibilityLabel("Types de listes (neuf/occasion)")
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
            // Pinned to the bottom bar (not the nav bar) rather than the top-trailing spot used
            // before #141's search bar: iOS hides the top nav bar's own toolbar items while the
            // search field is focused, which used to make this button unreachable mid-search —
            // the bottom bar isn't affected by that collapse.
            if !(viewModel?.cachedSets.isEmpty ?? true) {
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
                                showMoveListPicker = true
                            } label: {
                                Label("Déplacer vers une liste", systemImage: "folder")
                            }
                            // Not `role: .destructive` — SwiftUI previews a destructive Menu item
                            // across the List's selected rows the instant the Menu opens (a red
                            // flash on the selection background), not just on tap. Since `role`
                            // can't carry the danger signal here, the label is colored explicitly
                            // instead (#152) — the accent color it relied on before is user
                            // -configurable (yellow/blue/red), so "red" isn't guaranteed without
                            // this.
                            Button {
                                pendingActionTargets = selectedCachedSets
                                showRemoveConfirmation = true
                            } label: {
                                Label("Retirer de la collection", systemImage: "trash")
                                    .foregroundStyle(Color.brickDanger)
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
                            // nor "multiple" (#151).
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
        .sheet(isPresented: $showMoveListPicker) {
            ListPickerView(repository: rebrickableRepository) { listId, listName in
                Task { await moveToList(pendingActionTargets, listId: listId, listName: listName) }
            }
        }
        .alert("Retirer de la collection ?", isPresented: $showRemoveConfirmation) {
            Button("Retirer", role: .destructive) {
                Task { await removeFromCollection(pendingActionTargets) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(pendingActionTargets.count) set(s) seront retirés de votre collection Rebrickable.")
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
                availableThemeIds: viewModel?.availableThemeIds ?? [],
                availableYears: viewModel?.availableYears ?? [],
                availableListNames: viewModel?.availableListNames ?? [],
                showsOwnedFilter: false,
                themeName: { ThemeNameStore.shared.displayName(forThemeId: $0) },
                excludedSortOptions: [.dateAdded]
            )
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            viewModel?.load()
        }) {
            SettingsView()
        }
        .onChange(of: SetPriceIndex.Version(allCachedPrices), initial: true) { _, _ in
            pricesBySetNum = SetPriceIndex.pricesBySetNum(allCachedPrices)
        }
        .onAppear {
            if viewModel == nil {
                viewModel = CollectionViewModel(localRepository: LocalRepository(modelContext: modelContext))
            }
            viewModel?.load()
        }
        .onDisappear {
            CollectionFilterState.shared.resetSort()
        }
        // Reloads once the initial (or a pull-to-refresh) sync finishes — this view can be on
        // screen before the launch sync started/completed (#148), so it needs to pick up the
        // freshly-synced sets rather than staying on whatever `onAppear` saw.
        .onChange(of: SyncStatusStore.shared.isSyncing) { _, syncing in
            if !syncing { viewModel?.load() }
        }
    }
}
