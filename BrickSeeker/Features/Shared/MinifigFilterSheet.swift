import SwiftUI

/// Filter/sort sheet for `MinifigGalleryView`, mirroring `SetFilterSheet`'s layout. The "owned
/// only" toggle is deliberately NOT here — it's promoted to a first-level toolbar action on the
/// gallery itself (see `MinifigFilterState.ownedOnly`), per the issue's explicit ask.
struct MinifigFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var filter: MinifigFilterState
    let availableThemeIds: [Int]
    let availableYears: [Int]
    let themeName: (Int) -> String

    /// "Tous" stays pinned first. The actual rows are deduplicated by display name rather than
    /// one per `themeId` — same reasoning as `SetFilterSheet.sortedThemeNames` (issue #171).
    private var sortedThemeNames: [String] {
        Set(availableThemeIds.map(themeName)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tri") {
                    HStack {
                        Picker("Trier par", selection: $filter.sort) {
                            ForEach(MinifigSortOption.allCases) { option in
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
