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
    /// How many of the screen's sets have no lego.com availability information yet (#226). Drives
    /// the hint under the "Disponibilité" picker: that data is only written when a lego.com price
    /// is actually fetched, so on a big collection most sets legitimately sit in "Inconnue" and
    /// the filter would otherwise look broken ("En vente returns 3 sets?"). 0 hides the hint.
    var unknownAvailabilityCount: Int = 0
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
    /// French-correct singular/plural, same convention as `setsCountSentence` (#155).
    private var unknownAvailabilityHint: String {
        let count = setsCountSentence(
            unknownAvailabilityCount,
            singular: "n'a pas encore d'information de disponibilité lego.com.",
            plural: "n'ont pas encore d'information de disponibilité lego.com."
        )
        return "\(count) \(String(localized: "Elle est relevée en même temps que le prix lego.com : actualisez les prix pour la compléter."))"
    }

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

                Section {
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

                    // Same icons/wording as SetDetail's badge next to the lego.com price
                    // (`StoreAvailabilityStatus`'s display extension) so both surfaces describe
                    // the same store state identically (#226). The per-status `tint` is set here
                    // but a menu-style Picker repaints its row icons with the app accent colour,
                    // so only the *shapes* (check / warning triangle / archive box / question
                    // mark) carry the distinction inside the menu — verified in the simulator.
                    // "Inconnue" is a listed choice, not a hidden bucket — see
                    // `SetFilterState.availability`.
                    Picker("Disponibilité", selection: $filter.availability) {
                        Text("Toutes").tag(StoreAvailabilityStatus?.none)
                        ForEach(StoreAvailabilityStatus.allCases, id: \.self) { status in
                            Label {
                                Text(status.label)
                            } icon: {
                                Image(systemName: status.pickerSystemImage)
                                    .foregroundStyle(status.tint)
                            }
                            .tag(StoreAvailabilityStatus?.some(status))
                        }
                    }
                } header: {
                    Text("Filtres")
                } footer: {
                    if unknownAvailabilityCount > 0 {
                        // The pointer the issue asks for: this data is a by-product of fetching
                        // the lego.com price, so "refresh the prices" is the one gesture that
                        // fills it in — said explicitly rather than leaving the user to guess why
                        // so many sets are "Inconnue".
                        Text(unknownAvailabilityHint)
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
