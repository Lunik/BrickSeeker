import SwiftUI
import SwiftData

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allCachedPrices: [CachedSetPrice]
    @Query private var allCachedSetLists: [CachedSetList]
    @State private var viewModel: CollectionViewModel?
    @State private var showFilters = false
    @Bindable private var filter = CollectionFilterState.shared
    let lookupViewModel: ScannerViewModel
    var rebrickableRepository: RebrickableRepositoryProtocol = RebrickableRepository()

    /// Memoized from `allCachedPrices` (see the `.onChange` in `body`) — rebuilding this
    /// dictionary was previously a computed property re-run on every keystroke in the search bar.
    @State private var pricesBySetNum: [String: [PriceQuote]] = [:]

    @State private var editMode: EditMode = .inactive
    @State private var selectedSetNums: Set<String> = []
    @State private var isPerformingBulkAction = false
    @State private var selectionActionError: String?
    @State private var showMoveListPicker = false
    @State private var showRemoveConfirmation = false

    private var conditionByListId: [Int: ListCondition] {
        Dictionary(allCachedSetLists.map { ($0.listId, $0.condition) }, uniquingKeysWith: { first, _ in first })
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

    /// Batch "refresh prices" action on the selected sets, reusing `CollectionPriceUpdater
    /// .shared` — the same singleton driven by `CollectionPriceUpdateSection` from Réglages —
    /// rather than a parallel pipeline (see #141).
    private func refreshSelectedPrices() async {
        selectionActionError = nil
        let selected = selectedCachedSets
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

    /// Moves every selected set into `listId` on Rebrickable — a set with no known current list
    /// is added rather than moved (there's nothing to remove it from).
    private func moveSelectedToList(listId: Int, listName: String) async {
        selectionActionError = nil
        let selected = selectedCachedSets
        guard !selected.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in selected {
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
            editMode = .inactive
        }
    }

    private func removeSelectedFromCollection() async {
        selectionActionError = nil
        let selected = selectedCachedSets
        guard !selected.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in selected {
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
            editMode = .inactive
        }
    }

    var body: some View {
        Group {
            if let viewModel, !viewModel.cachedSets.isEmpty {
                let filteredSets = viewModel.cachedSets.filteredAndSorted(by: filter, resolvedPrice: resolvedPrice)
                if filteredSets.isEmpty {
                    ContentUnavailableView(
                        "Aucun résultat",
                        systemImage: "magnifyingglass",
                        description: Text("Essayez de modifier la recherche ou les filtres.")
                    )
                } else {
                    List(filteredSets, id: \.setNum, selection: $selectedSetNums) { cached in
                        Button {
                            lookupViewModel.lookupSetNumber(cached.setNum, source: .listReopen)
                        } label: {
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
                        }
                        .buttonStyle(.plain)
                    }
                    .contentMargins(.top, 0, for: .scrollContent)
                }
            } else {
                ContentUnavailableView(
                    "Aucun set possédé",
                    systemImage: "shippingbox",
                    description: Text("Liez votre compte Rebrickable et synchronisez depuis l'accueil.")
                )
            }
        }
        .searchable(text: $filter.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nom ou numéro de set")
        .navigationTitle("Ma collection")
        .toolbar {
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
                    Spacer()
                    if editMode.isEditing {
                        Menu {
                            Button {
                                Task { await refreshSelectedPrices() }
                            } label: {
                                Label("Actualiser les prix", systemImage: "arrow.clockwise")
                            }
                            Button {
                                showMoveListPicker = true
                            } label: {
                                Label("Déplacer vers une liste", systemImage: "folder")
                            }
                            Button(role: .destructive) {
                                showRemoveConfirmation = true
                            } label: {
                                Label("Retirer de la collection", systemImage: "trash")
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
                    Button(editMode.isEditing ? "Terminé" : "Actions") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing {
                selectedSetNums.removeAll()
            }
        }
        .sheet(isPresented: $showMoveListPicker) {
            ListPickerView(repository: rebrickableRepository) { listId, listName in
                Task { await moveSelectedToList(listId: listId, listName: listName) }
            }
        }
        .alert("Retirer de la collection ?", isPresented: $showRemoveConfirmation) {
            Button("Retirer", role: .destructive) {
                Task { await removeSelectedFromCollection() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(selectedSetNums.count) set(s) seront retirés de votre collection Rebrickable.")
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
                themeName: { ThemeNameStore.shared.displayName(forThemeId: $0) }
            )
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
    }
}
