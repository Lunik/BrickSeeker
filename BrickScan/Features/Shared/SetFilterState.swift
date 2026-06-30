import Foundation
import Observation

enum SetSortOption: String, CaseIterable, Identifiable {
    case dateScanned
    case year
    case name
    case partCount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateScanned: return "Date de scan"
        case .year: return "Année"
        case .name: return "Nom"
        case .partCount: return "Nombre de pièces"
        }
    }

    /// The direction each option reads most naturally in — newest/biggest first for the
    /// numeric/date ones, A→Z for name. Used to reset `SetFilterState.sortAscending` whenever
    /// the user switches `sort`, so flipping from "Nom" to "Année" doesn't carry over an
    /// ascending choice that would otherwise show the oldest set first without explanation.
    var defaultAscending: Bool {
        switch self {
        case .dateScanned, .year, .partCount: return false
        case .name: return true
        }
    }
}

/// Search/filter/sort state for `CollectionView` and `HistoryView`. Held as a process-lifetime
/// singleton (see `CollectionFilterState`/`HistoryFilterState` below) rather than `@State` on the
/// view, since both views are recreated from scratch every time they're presented (navigation
/// push / sheet) — per issue #38 the filter should survive that and only reset when the app is
/// relaunched, not on every dismiss.
@Observable
@MainActor
final class SetFilterState {
    var searchText = ""
    /// `CachedSet.themeId`; nil means "all themes".
    var themeId: Int?
    var year: Int?
    /// Collection only — filters by `CachedSet.currentListName`.
    var listName: String?
    /// History only — `nil` shows both owned and not-owned, `true`/`false` restricts to one.
    var ownedOnly: Bool?
    var sort: SetSortOption = .dateScanned
    var sortAscending = SetSortOption.dateScanned.defaultAscending

    var isFilterActive: Bool {
        themeId != nil || year != nil || listName != nil || ownedOnly != nil ||
            sort != .dateScanned || sortAscending != sort.defaultAscending
    }

    func resetFilters() {
        themeId = nil
        year = nil
        listName = nil
        ownedOnly = nil
        sort = .dateScanned
        sortAscending = SetSortOption.dateScanned.defaultAscending
    }

    func resetSort() {
        sort = .dateScanned
        sortAscending = SetSortOption.dateScanned.defaultAscending
    }
}

/// Separate singleton from `HistoryFilterState` so filtering one screen never affects the other.
@MainActor
enum CollectionFilterState {
    static let shared = SetFilterState()
}

@MainActor
enum HistoryFilterState {
    static let shared = SetFilterState()
}

extension Array where Element == CachedSet {
    @MainActor
    func filteredAndSorted(by filter: SetFilterState) -> [CachedSet] {
        var result = self

        let trimmedSearch = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedSearch) ||
                    $0.setNum.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
        if let themeId = filter.themeId {
            result = result.filter { $0.themeId == themeId }
        }
        if let year = filter.year {
            result = result.filter { $0.year == year }
        }
        if let listName = filter.listName {
            result = result.filter { $0.currentListName == listName }
        }
        if let ownedOnly = filter.ownedOnly {
            result = result.filter { $0.isInCollection == ownedOnly }
        }

        let ascending = filter.sortAscending
        switch filter.sort {
        case .dateScanned:
            result.sort { ascending ? $0.lastScannedAt < $1.lastScannedAt : $0.lastScannedAt > $1.lastScannedAt }
        case .year:
            result.sort { ascending ? $0.year < $1.year : $0.year > $1.year }
        case .name:
            result.sort {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .partCount:
            result.sort { ascending ? $0.numParts < $1.numParts : $0.numParts > $1.numParts }
        }

        return result
    }
}
