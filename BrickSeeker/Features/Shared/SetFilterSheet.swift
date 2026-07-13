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
    /// Hides sort options that don't make sense for a given screen — e.g. `.dateScanned` for
    /// `NewSetsView`'s catalogue browse, which has no scan history to sort by. Empty by default so
    /// Collection/History (which show every option) are unaffected.
    var excludedSortOptions: Set<SetSortOption> = []

    private var availableSortOptions: [SetSortOption] {
        SetSortOption.allCases.filter { !excludedSortOptions.contains($0) }
    }

    /// "Tous" stays pinned first (it's the no-filter row, not a real theme). The actual rows are
    /// deduplicated by display name rather than one per `themeId` — Rebrickable's theme table is
    /// hierarchical, so distinct ids can share a name (e.g. two "City" entries, issue #171), and
    /// showing both would just confuse the user with no way to tell them apart.
    private var sortedThemeNames: [String] {
        Set(availableThemeIds.map(themeName)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tri") {
                    HStack {
                        Picker("Trier par", selection: $filter.sort) {
                            ForEach(availableSortOptions) { option in
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
                        // Icon-only, no label before this (#143) — VoiceOver would have announced
                        // the raw SF Symbol name instead of what tapping it does.
                        .accessibilityLabel("Ordre de tri")
                        .accessibilityValue(filter.sortAscending ? "Croissant" : "Décroissant")
                    }
                }

                Section("Filtres") {
                    Picker("Thème", selection: $filter.themeName) {
                        Text("Tous").tag(String?.none)
                        ForEach(sortedThemeNames, id: \.self) { name in
                            Text(name).tag(String?.some(name))
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
                        // Was `role: .destructive` (red) — clearing filters loses no data, unlike
                        // every other red button in the app (#153).
                        Button("Réinitialiser les filtres") {
                            filter.resetFilters()
                        }
                    }
                }
            }
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Filters already apply live as they're changed — a single "OK" (no "Annuler")
                // implied a pending choice to confirm/cancel that doesn't actually exist (#153).
                // "Fermer" says what the button does: close the sheet, nothing more.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
