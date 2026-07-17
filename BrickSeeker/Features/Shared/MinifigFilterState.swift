import Foundation
import Observation

enum MinifigSortOption: String, CaseIterable, Identifiable {
    case name
    case year
    case theme
    case price

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Nom"
        case .year: return "Année"
        case .theme: return "Thème"
        case .price: return "Prix"
        }
    }

    /// Mirrors `SetSortOption.defaultAscending`'s reasoning — the direction each option reads
    /// most naturally in, so switching sort doesn't silently carry over a stale direction.
    var defaultAscending: Bool {
        switch self {
        case .name, .theme: return true
        case .year, .price: return false
        }
    }
}

/// Search/filter/sort state for `MinifigGalleryView`, mirroring `SetFilterState`'s "process-
/// lifetime singleton" pattern (`MinifigGalleryFilterState` below) so the filter survives the view
/// being torn down and recreated on navigation push/pop rather than resetting every time (issue
/// #38's reasoning, same as `CollectionFilterState`/`HistoryFilterState`).
@Observable
@MainActor
final class MinifigFilterState {
    var searchText = ""
    /// Resolved theme display name (e.g. "City"), derived from the minifig's first containing
    /// set — not a raw `themeId` — since Rebrickable's theme table is hierarchical and several
    /// distinct ids can share the same name (issue #171, same reasoning as `SetFilterState
    /// .themeName`): the filter selects on the name and matches every id that resolves to it.
    /// `nil` means "all themes".
    var themeName: String?
    /// Derived `year` (from the minifig's first containing set); nil means "all years".
    var year: Int?
    /// Default sort is by year (newest first, via `.year`'s `defaultAscending == false`) — the
    /// "collection to complete" framing reads better grouped by release year than alphabetically.
    var sort: MinifigSortOption = .year
    var sortAscending = MinifigSortOption.year.defaultAscending
    /// Promoted to a first-level toolbar toggle in `MinifigGalleryView` rather than buried in the
    /// filter sheet, per the issue's explicit ask — still lives here (not view `@State`) so it
    /// persists across navigation the same way the rest of the filter does.
    var ownedOnly = false

    var isFilterActive: Bool {
        themeName != nil || year != nil || ownedOnly ||
            sort != .year || sortAscending != sort.defaultAscending
    }

    func resetFilters() {
        themeName = nil
        year = nil
        ownedOnly = false
        sort = .year
        sortAscending = MinifigSortOption.year.defaultAscending
    }
}

@MainActor
enum MinifigGalleryFilterState {
    static let shared = MinifigFilterState()
}

extension Array where Element == OfflineMinifigCatalogStore.MinifigCatalogEntry {
    /// - Parameters:
    ///   - owned: which fig_nums count as owned (`CachedSet.isInCollection` cross-referenced
    ///     against `containingSets` — computed once by the caller, not per-element here).
    ///   - resolvedPrice: cache-only, condition-aware BrickLink price lookup (`resolveMinifigPrice`,
    ///     issue #203), used only for `.price` sort.
    ///   - themeName: display-name resolver, used only for `.theme` sort (grouping/ordering by the
    ///     same string `MinifigGalleryView`'s section headers show, not the raw `themeId`).
    @MainActor
    func filteredAndSorted(
        by filter: MinifigFilterState,
        owned: (String) -> Bool,
        resolvedPrice: (String) -> Double?,
        themeName: (Int) -> String
    ) -> [OfflineMinifigCatalogStore.MinifigCatalogEntry] {
        var result = self

        let trimmedSearch = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedSearch) ||
                    $0.figNum.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
        if let selectedThemeName = filter.themeName {
            result = result.filter { $0.themeId.map(themeName) == selectedThemeName }
        }
        if let year = filter.year {
            result = result.filter { $0.year == year }
        }
        if filter.ownedOnly {
            result = result.filter { owned($0.figNum) }
        }

        let ascending = filter.sortAscending
        switch filter.sort {
        case .name:
            result.sort {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .year:
            // Minifigs with no derivable year (no containing set found in the catalogue dump —
            // rare, e.g. a not-yet-released promo) always sort last, regardless of direction.
            result.sort {
                switch ($0.year, $1.year) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return ascending ? a < b : a > b
                }
            }
        case .theme:
            let named = result.map { (entry: $0, name: $0.themeId.map(themeName)) }
            result = named.sorted {
                switch ($0.name, $1.name) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?):
                    let order = a.localizedCaseInsensitiveCompare(b)
                    return ascending ? order == .orderedAscending : order == .orderedDescending
                }
            }.map(\.entry)
        case .price:
            // Pre-resolve once — avoids calling the closure O(n log n) times (see
            // `SetFilterState.filteredAndSorted`'s identical reasoning for sets).
            let priced = result.map { (entry: $0, price: resolvedPrice($0.figNum)) }
            result = priced.sorted {
                switch ($0.price, $1.price) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return ascending ? a < b : a > b
                }
            }.map(\.entry)
        }

        return result
    }
}
