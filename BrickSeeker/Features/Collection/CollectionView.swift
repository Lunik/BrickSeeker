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

    /// Memoized from `allCachedPrices` (see the `.onChange` in `body`) — rebuilding this
    /// dictionary was previously a computed property re-run on every keystroke in the search bar.
    @State private var pricesBySetNum: [String: [PriceQuote]] = [:]

    @State private var editMode: EditMode = .inactive
    @State private var selectedSetNums: Set<String> = []
    @State private var isRefreshingSelection = false
    @State private var selectionRefreshError: String?

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

    /// Batch "refresh prices" action on the selected sets, reusing `CollectionPriceUpdater
    /// .shared` — the same singleton driven by `CollectionPriceUpdateSection` from Réglages —
    /// rather than a parallel pipeline (see #141). That singleton is a single global run: if
    /// one is already in progress, or a previous full-collection pass was paused mid-way (its
    /// queue file still on disk), `start(allSets:)` would silently ignore our selection and
    /// resume/observe that other queue instead. Guard against both up front so the button never
    /// quietly refreshes the wrong sets.
    private func refreshSelectedPrices() async {
        selectionRefreshError = nil
        guard let viewModel else { return }
        let selected = viewModel.cachedSets.filter { selectedSetNums.contains($0.setNum) }
        guard !selected.isEmpty else { return }

        let updater = CollectionPriceUpdater.shared
        guard !updater.isRunning, !updater.hasResumableUpdate else {
            selectionRefreshError = String(
                localized: "Une actualisation des prix de la collection est déjà en cours ou en attente de reprise. Terminez-la avant d'actualiser une sélection."
            )
            return
        }

        isRefreshingSelection = true
        defer { isRefreshingSelection = false }

        await PriceUpdateNotifier.requestAuthorizationIfNeeded()

        let result = await updater.start(
            allSets: selected.map { $0.asLegoSet() },
            priceRepository: PriceRepository(),
            legoStoreRepository: LegoStoreRepository(),
            persist: CollectionPriceUpdater.persistClosure(modelContext: modelContext)
        )

        if result.completed {
            PriceUpdateNotifier.notifyCompleted(total: result.total)
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
                }
            } else {
                ContentUnavailableView(
                    "Aucun set possédé",
                    systemImage: "shippingbox",
                    description: Text("Liez votre compte Rebrickable et synchronisez depuis l'accueil.")
                )
            }
        }
        .searchable(text: $filter.searchText, prompt: "Nom ou numéro de set")
        .navigationTitle("Ma collection")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !(viewModel?.cachedSets.isEmpty ?? true) {
                    EditButton()
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
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button {
                        Task { await refreshSelectedPrices() }
                    } label: {
                        if isRefreshingSelection {
                            ProgressView()
                        } else {
                            Text("Actualiser les prix (\(selectedSetNums.count))")
                        }
                    }
                    .disabled(selectedSetNums.isEmpty || isRefreshingSelection)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing {
                selectedSetNums.removeAll()
            }
        }
        .alert(
            "Actualisation impossible",
            isPresented: Binding(
                get: { selectionRefreshError != nil },
                set: { isPresented in if !isPresented { selectionRefreshError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(selectionRefreshError ?? "")
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
