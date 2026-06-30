import SwiftUI
import SwiftData

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CollectionViewModel?
    @State private var showFilters = false
    @Bindable private var filter = CollectionFilterState.shared
    let lookupViewModel: ScannerViewModel

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
                            HStack(spacing: 14) {
                                SetThumbnailView(imageUrl: cached.setImgUrl)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cached.setNum).font(.headline)
                                    Text(cached.name).font(.subheadline).foregroundStyle(.secondary)
                                    if let listName = cached.currentListName {
                                        Text(listName).font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .foregroundStyle(.primary)

                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
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
