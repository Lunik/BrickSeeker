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

    private var pricesBySetNum: [String: [PriceQuote]] {
        Dictionary(grouping: allCachedPrices.filter { !$0.isExpired }.compactMap({ p -> (String, PriceQuote)? in
            guard let q = p.quote else { return nil }
            return (p.setNum, q)
        }), by: \.0).mapValues { $0.map(\.1) }
    }

    private var conditionByListId: [Int: ListCondition] {
        Dictionary(uniqueKeysWithValues: allCachedSetLists.map { ($0.listId, $0.condition) })
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
                let filteredSets = viewModel.filteredSets
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
                                resolvedPrice: resolvedPrice(for: cached)
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
            }
        }
        .sheet(isPresented: $showFilters) {
            SetFilterSheet(
                filter: filter,
                availableThemeIds: viewModel?.availableThemeIds ?? [],
                availableYears: viewModel?.availableYears ?? [],
                availableListNames: viewModel?.availableListNames ?? [],
                showsOwnedFilter: false,
                themeName: { viewModel?.themeName(forThemeId: $0) ?? "Thème #\($0)" }
            )
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
