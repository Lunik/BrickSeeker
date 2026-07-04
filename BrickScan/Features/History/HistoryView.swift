import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(filter: #Predicate<CachedSet> { $0.wasScanned }, sort: \CachedSet.lastScannedAt, order: .reverse)
    private var cachedSets: [CachedSet]
    @Query private var allCachedPrices: [CachedSetPrice]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable private var filter = HistoryFilterState.shared
    @State private var showFilters = false
    @State private var showScanMap = false
    @State private var setPendingDeletion: CachedSet?
    let lookupViewModel: ScannerViewModel
    let onSelect: (String) -> Void

    /// Memoized from `allCachedPrices` (see the `.onChange` in `body`) — rebuilding this
    /// dictionary was previously a computed property re-run on every keystroke in the search bar.
    @State private var pricesBySetNum: [String: [PriceQuote]] = [:]

    private var filteredSets: [CachedSet] { cachedSets.filteredAndSorted(by: filter, resolvedPrice: resolvedPrice) }
    private var availableThemeIds: [Int] { Set(cachedSets.map(\.themeId)).sorted() }
    private var availableYears: [Int] { Set(cachedSets.map(\.year)).sorted(by: >) }

    private func resolvedPrice(for cached: CachedSet) -> Double? {
        resolveNewPrice(storePriceEUR: cached.storePriceEUR, quotes: pricesBySetNum[cached.setNum] ?? [])
    }

    var body: some View {
        NavigationStack {
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
                    List(filteredSets) { cached in
                        Button {
                            // Deliberately no dismiss() here: closing the SetDetail sheet we
                            // present below should reveal History again, not Home — see
                            // HomeView.setDetailBinding's !showHistory gate.
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
                }
            }
            .searchable(text: $filter.searchText, prompt: "Nom ou numéro de set")
            .navigationTitle("Historique")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: filter.isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filtres")
                    .accessibilityValue(filter.isFilterActive ? "Actifs" : "Inactifs")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showScanMap = true
                    } label: {
                        Image(systemName: "map")
                    }
                    .accessibilityLabel("Carte des scans")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
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
            // Nested presenter — closing the result reveals History again, not Home (HomeView
            // gates its own copy while this sheet is up; see LookupResultSheetsModifier).
            .lookupResultSheets(for: lookupViewModel)
        }
    }
}
