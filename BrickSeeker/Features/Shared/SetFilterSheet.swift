import SwiftUI

/// Filter/sort sheet shared by `CollectionView` and `HistoryView` (issue #38). The fields shown
/// vary per screen: `availableListNames`/`showsOwnedFilter` are only relevant to one screen each
/// — Collection is already restricted to owned sets so an owned/not-owned filter wouldn't do
/// anything there, and History has no per-set list assignment of its own.
struct SetFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var filter: SetFilterState
    let availableThemeIds: [Int]
    let availableYears: [Int]
    let availableListNames: [String]
    let showsOwnedFilter: Bool
    let themeName: (Int) -> String

    /// "Tous" stays pinned first (it's the no-filter row, not a real theme); the actual themes
    /// sort by display name rather than raw `themeId`, since the id order is meaningless to a user.
    private var sortedThemeIds: [Int] {
        availableThemeIds.sorted { themeName($0).localizedCaseInsensitiveCompare(themeName($1)) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tri") {
                    HStack {
                        Picker("Trier par", selection: $filter.sort) {
                            ForEach(SetSortOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .onChange(of: filter.sort) { _, newSort in
                            filter.sortAscending = newSort.defaultAscending
                        }

                        Button {
                            filter.sortAscending.toggle()
                        } label: {
                            Image(systemName: filter.sortAscending ? "arrow.up" : "arrow.down")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section("Filtres") {
                    Picker("Thème", selection: $filter.themeId) {
                        Text("Tous").tag(Int?.none)
                        ForEach(sortedThemeIds, id: \.self) { themeId in
                            Text(themeName(themeId)).tag(Int?.some(themeId))
                        }
                    }

                    Picker("Année", selection: $filter.year) {
                        Text("Toutes").tag(Int?.none)
                        ForEach(availableYears, id: \.self) { year in
                            Text(String(year)).tag(Int?.some(year))
                        }
                    }

                    if !availableListNames.isEmpty {
                        Picker("Liste", selection: $filter.listName) {
                            Text("Toutes").tag(String?.none)
                            ForEach(availableListNames, id: \.self) { listName in
                                Text(listName).tag(String?.some(listName))
                            }
                        }
                    }

                    if showsOwnedFilter {
                        Picker("Possession", selection: $filter.ownedOnly) {
                            Text("Tous").tag(Bool?.none)
                            Text("Possédés").tag(Bool?.some(true))
                            Text("Non possédés").tag(Bool?.some(false))
                        }
                    }
                }

                if filter.isFilterActive {
                    Section {
                        Button("Réinitialiser les filtres", role: .destructive) {
                            filter.resetFilters()
                        }
                    }
                }
            }
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
