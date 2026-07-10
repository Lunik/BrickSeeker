import SwiftUI
import SwiftData

private let frenchDateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "fr_FR"))

/// "Mes minifigs" (issue #170): a photo gallery of every minifig in Rebrickable's catalogue,
/// owned ones in colour and missing ones in silhouette (`MinifigThumbnailView`), searchable,
/// filterable by year/theme, sortable, with an "owned only" toggle. Entirely offline-driven
/// (`OfflineMinifigCatalogStore`) and cache-only on price (`SetPriceIndex`/`LocalRepository`) —
/// never a live network call from this screen, see the issue's decisions #2/#3. Tapping a tile
/// opens the same `SetDetailView` sheet as tapping a `fig-…` item anywhere else in the app —
/// see `openDetail(for:ownedQuantity:)`.
struct MinifigGalleryView: View {
    @State private var viewModel = MinifigGalleryViewModel()
    @Bindable private var filter = MinifigGalleryFilterState.shared
    @State private var showFilters = false
    @State private var displayedCount = Self.pageSize
    /// Not started/camera-driven (see `HomeView`'s own `lookupViewModel`) — reused purely to open
    /// the exact same `SetDetailView` sheet a tap in Collection opens (`openDetail(for:ownedQuantity:)`).
    /// `HomeView`'s existing (ungated) `.lookupResultSheets(for: lookupViewModel)` already presents
    /// it — this view is pushed onto the same `NavigationStack` as `CollectionView`/`HistoryView`,
    /// so it must NOT apply the modifier a second time (see `LookupResultSheetsModifier`'s doc on
    /// "gate the parent, nest in the child").
    let lookupViewModel: ScannerViewModel

    @Query(filter: #Predicate<CachedSet> { $0.isInCollection }) private var ownedCachedSets: [CachedSet]
    @Query private var allCachedPrices: [CachedSetPrice]
    @State private var pricesByFigNum: [String: [PriceQuote]] = [:]

    private static let pageSize = 60
    private static let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    private struct FilterSignature: Equatable {
        let searchText: String
        let themeId: Int?
        let year: Int?
        let sort: MinifigSortOption
        let sortAscending: Bool
        let ownedOnly: Bool
    }

    private var filterSignature: FilterSignature {
        FilterSignature(
            searchText: filter.searchText, themeId: filter.themeId, year: filter.year,
            sort: filter.sort, sortAscending: filter.sortAscending, ownedOnly: filter.ownedOnly
        )
    }

    private struct GallerySection: Identifiable {
        let id: String
        let header: String?
        let items: [OfflineMinifigCatalogStore.MinifigCatalogEntry]
    }

    private func resolvedPrice(figNum: String, prices: [String: [PriceQuote]]) -> Double? {
        guard let quote = prices[figNum]?.first(where: { $0.source == .bricklinkUsed }) else { return nil }
        return (quote.amount as NSDecimalNumber).doubleValue
    }

    /// How many copies of each minifig the user owns — summed across every owned set it appears
    /// in (`containingSet.quantityPerSet × ` that set's own owned quantity), not just whether
    /// they own it at all (issue #170 feedback: cards show "×N", not just colour/silhouette).
    /// Only figNums with a positive total are present in the result.
    private static func ownedQuantityByFigNum(
        entries: [OfflineMinifigCatalogStore.MinifigCatalogEntry],
        ownedCachedSets: [CachedSet]
    ) -> [String: Int] {
        guard !ownedCachedSets.isEmpty else { return [:] }
        let ownedQuantityBySetNum = Dictionary(ownedCachedSets.map { ($0.setNum, $0.quantity) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Int] = [:]
        for entry in entries {
            let total = entry.containingSets.reduce(into: 0) { sum, containingSet in
                guard let ownedQuantity = ownedQuantityBySetNum[containingSet.setNum] else { return }
                sum += containingSet.quantityPerSet * ownedQuantity
            }
            if total > 0 { result[entry.figNum] = total }
        }
        return result
    }

    /// Opens the exact same `SetDetailView` sheet tapping a `fig-…` item from Collection would
    /// (issue #170 feedback #7/#8) — not a custom minifig page. Seeds a `CachedSet` row from this
    /// catalogue entry's rich offline data *before* calling `lookupSetNumber`, so
    /// `ScannerViewModel.resolveSet`'s cache-hit branch fires immediately with complete data
    /// (image/name/theme/year/parts) instead of falling through to a live `/lego/sets/…` lookup,
    /// which 404s for a `fig-…` id (see `AGENTS.md`'s note on this exact case).
    private func openDetail(for entry: OfflineMinifigCatalogStore.MinifigCatalogEntry, ownedQuantity: Int) {
        let syntheticLegoSet = LegoSet(
            setNum: entry.figNum,
            name: entry.name,
            year: entry.year ?? 0,
            themeId: entry.themeId ?? 0,
            numParts: entry.numParts,
            setImgUrl: entry.imgUrl,
            setUrl: nil
        )
        lookupViewModel.localRepository?.cacheSet(
            syntheticLegoSet, isInCollection: ownedQuantity > 0, listId: nil, listName: nil, markAsScanned: false
        )
        if ownedQuantity > 0 {
            lookupViewModel.localRepository?.setQuantity(setNum: entry.figNum, quantity: ownedQuantity)
        }
        lookupViewModel.lookupSetNumber(entry.figNum, source: .listReopen)
    }

    private func sectionHeader(for entry: OfflineMinifigCatalogStore.MinifigCatalogEntry) -> String {
        switch filter.sort {
        case .year:
            return entry.year.map(String.init) ?? "Année inconnue"
        case .theme:
            return entry.themeId.map { ThemeNameStore.shared.displayName(forThemeId: $0) } ?? "Thème inconnu"
        case .name, .price:
            return ""
        }
    }

    /// Groups an already-sorted (by year/theme) slice into contiguous runs — cheap, since the
    /// input is pre-sorted by the exact same key used to group it.
    private func sections(from windowed: [OfflineMinifigCatalogStore.MinifigCatalogEntry]) -> [GallerySection] {
        guard filter.sort == .year || filter.sort == .theme else {
            return [GallerySection(id: "all", header: nil, items: windowed)]
        }
        var result: [GallerySection] = []
        var currentHeader: String?
        var currentItems: [OfflineMinifigCatalogStore.MinifigCatalogEntry] = []
        for entry in windowed {
            let header = sectionHeader(for: entry)
            if header != currentHeader, !currentItems.isEmpty {
                result.append(GallerySection(id: "\(result.count)-\(currentHeader ?? "")", header: currentHeader, items: currentItems))
                currentItems = []
            }
            currentHeader = header
            currentItems.append(entry)
        }
        if !currentItems.isEmpty {
            result.append(GallerySection(id: "\(result.count)-\(currentHeader ?? "")", header: currentHeader, items: currentItems))
        }
        return result
    }

    var body: some View {
        // Computed once per body evaluation and captured by the closures below, rather than
        // re-derived per grid cell — this walks the whole catalogue, which must not happen once
        // per visible tile.
        let ownedQuantityByFigNum = Self.ownedQuantityByFigNum(entries: viewModel.allEntries, ownedCachedSets: ownedCachedSets)
        let prices = pricesByFigNum
        let filteredSorted = viewModel.allEntries.filteredAndSorted(
            by: filter,
            owned: { ownedQuantityByFigNum[$0, default: 0] > 0 },
            resolvedPrice: { resolvedPrice(figNum: $0, prices: prices) },
            themeName: { ThemeNameStore.shared.displayName(forThemeId: $0) }
        )
        let windowed = Array(filteredSorted.prefix(displayedCount))
        let gridSections = sections(from: windowed)

        Group {
            if !viewModel.hasCatalog {
                emptyCatalogView
            } else if viewModel.allEntries.isEmpty && viewModel.isLoadingCatalog {
                ProgressView("Chargement du catalogue…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSorted.isEmpty {
                ContentUnavailableView(
                    "Aucun résultat",
                    systemImage: "magnifyingglass",
                    description: Text("Essayez de modifier la recherche ou les filtres.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: .sectionHeaders) {
                        ForEach(gridSections) { section in
                            SwiftUI.Section {
                                LazyVGrid(columns: Self.columns, spacing: 12) {
                                    ForEach(section.items) { entry in
                                        Button {
                                            openDetail(for: entry, ownedQuantity: ownedQuantityByFigNum[entry.figNum, default: 0])
                                        } label: {
                                            MinifigThumbnailView(
                                                entry: entry,
                                                ownedQuantity: ownedQuantityByFigNum[entry.figNum, default: 0],
                                                price: resolvedPrice(figNum: entry.figNum, prices: prices)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } header: {
                                if let header = section.header {
                                    Text(header)
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                        .background(.bar)
                                }
                            }
                        }

                        if displayedCount < filteredSorted.count {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                                .onAppear { displayedCount += Self.pageSize }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .searchable(text: $filter.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nom ou identifiant")
        .navigationTitle("Mes minifigs")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    filter.ownedOnly.toggle()
                } label: {
                    Image(systemName: filter.ownedOnly ? "shippingbox.fill" : "shippingbox")
                }
                .accessibilityLabel("Possédées seulement")
                .accessibilityValue(filter.ownedOnly ? "Activé" : "Désactivé")

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
            MinifigFilterSheet(
                filter: filter,
                availableThemeIds: viewModel.availableThemeIds,
                availableYears: viewModel.availableYears,
                themeName: { ThemeNameStore.shared.displayName(forThemeId: $0) }
            )
        }
        .onChange(of: filterSignature) { _, _ in displayedCount = Self.pageSize }
        .onChange(of: SetPriceIndex.Version(allCachedPrices), initial: true) { _, _ in
            pricesByFigNum = SetPriceIndex.pricesBySetNum(allCachedPrices)
        }
        .task {
            await viewModel.loadCatalog()
        }
    }

    private var emptyCatalogView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Catalogue minifigs non téléchargé")
                .font(.headline)
            Text("Télécharge le catalogue Rebrickable (~15 000 minifigs) pour parcourir ta collection. Peut aussi se faire depuis Réglages.")
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
}
