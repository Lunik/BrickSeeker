import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(filter: #Predicate<CachedSet> { $0.wasScanned }, sort: \CachedSet.lastScannedAt, order: .reverse)
    private var cachedSets: [CachedSet]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable private var filter = HistoryFilterState.shared
    @State private var showFilters = false
    @State private var themeNames: [Int: String] = ThemeNameStore.shared.namesByThemeId
    let lookupViewModel: ScannerViewModel
    let onSelect: (String) -> Void

    private var filteredSets: [CachedSet] { cachedSets.filteredAndSorted(by: filter) }
    private var availableThemeIds: [Int] { Set(cachedSets.map(\.themeId)).sorted() }
    private var availableYears: [Int] { Set(cachedSets.map(\.year)).sorted(by: >) }

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
                            HStack(spacing: 14) {
                                SetThumbnailView(imageUrl: cached.setImgUrl)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cached.setNum)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(cached.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    if let amount = cached.storePriceEUR {
                                        Text(amount, format: .currency(code: "EUR"))
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.primary)
                                    }
                                    if cached.isInCollection {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
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
