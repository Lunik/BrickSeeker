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
    @State private var themeNames: [Int: String] = ThemeNameStore.shared.namesByThemeId
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
                                resolvedPrice: resolvedPrice(for: cached)
                            ) {
                                if cached.isInCollection {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
                    Button("Fermer") { dismiss() }
                }
            }
            .sheet(isPresented: $showFilters) {
                SetFilterSheet(
                    filter: filter,
                    availableThemeIds: availableThemeIds,
                    availableYears: availableYears,
                    availableListNames: [],
                    showsOwnedFilter: true,
                    themeName: { themeNames[$0] ?? "Thème #\($0)" }
                )
            }
            .task {
                await ThemeNameStore.shared.refreshIfNeeded()
                themeNames = ThemeNameStore.shared.namesByThemeId
            }
            .onChange(of: SetPriceIndex.Version(allCachedPrices), initial: true) { _, _ in
                pricesBySetNum = SetPriceIndex.pricesBySetNum(allCachedPrices)
            }
            .onDisappear {
                HistoryFilterState.shared.resetFilters()
            }
            .sheet(isPresented: setDetailBinding) {
                if case .found(let legoSet, let collectionStatus) = lookupViewModel.state {
                    let cached = LocalRepository(modelContext: modelContext).cachedSet(setNum: legoSet.setNum)
                    SetDetailView(
                        legoSet: legoSet,
                        collectionStatus: collectionStatus,
                        initialListName: lookupViewModel.lastFoundWasFromCache ? cached?.currentListName : nil,
                        initialStorePrice: cached?.storePriceEUR.map { StorePrice(amount: $0, currency: "EUR", availability: cached?.storeAvailability) },
                        initialStorePriceFetchedAt: cached?.storePriceFetchedAt,
                        reconcileOnAppear: lookupViewModel.lastFoundWasFromCache,
                        isOfflineResult: lookupViewModel.lastFoundWasOffline
                    ) {
                        lookupViewModel.resumeScanning()
                    }
                }
            }
            .sheet(isPresented: ambiguousBinding) {
                if case .ambiguous(let sets) = lookupViewModel.state {
                    AmbiguousSetPickerView(sets: sets) { selected in
                        lookupViewModel.selectAmbiguousSet(selected)
                    } onCancel: {
                        lookupViewModel.resumeScanning()
                    }
                }
            }
        }
    }

    private var setDetailBinding: Binding<Bool> {
        Binding(
            get: {
                if case .found = lookupViewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { lookupViewModel.resumeScanning() }
            }
        )
    }

    private var ambiguousBinding: Binding<Bool> {
        Binding(
            get: {
                if case .ambiguous = lookupViewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { lookupViewModel.resumeScanning() }
            }
        )
    }
}
