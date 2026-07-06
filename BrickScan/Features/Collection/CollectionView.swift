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
                    List(filteredSets, id: \.setNum) { cached in
                        Button {
                            lookupViewModel.lookupSetNumber(cached.setNum)
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: filter.isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filtres")
                .accessibilityValue(filter.isFilterActive ? "Actifs" : "Inactifs")
            }
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
