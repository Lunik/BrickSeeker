import Foundation
import Observation

enum SetSortOption: String, CaseIterable, Identifiable {
    case dateScanned
    case year
    case name
    case partCount
    case price
    /// When *this device* first saw a `set_num` in a downloaded offline-catalogue snapshot
    /// (`OfflineCatalogStore.allFirstSeenAt()`) — `NewSetsView` only; meaningless for a `CachedSet`
    /// (excluded from History/Collection's `SetFilterSheet`, see their call sites).
    case dateAdded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateScanned: return "Date de scan"
        case .year: return "Année"
        case .name: return "Nom"
        case .partCount: return "Nombre de pièces"
        case .price: return "Prix"
        case .dateAdded: return "Date d'ajout"
        }
    }

    /// The direction each option reads most naturally in — newest/biggest first for the
    /// numeric/date ones, A→Z for name. Used to reset `SetFilterState.sortAscending` whenever
    /// the user switches `sort`, so flipping from "Nom" to "Année" doesn't carry over an
    /// ascending choice that would otherwise show the oldest set first without explanation.
    var defaultAscending: Bool {
        switch self {
        case .dateScanned, .year, .partCount, .price, .dateAdded: return false
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
    /// Resolved theme display name (e.g. "City"), not a raw `themeId` — Rebrickable's theme
    /// table is hierarchical and several distinct ids can share the same name (issue #171), so
    /// the filter selects on the name and matches every id that resolves to it, rather than
    /// picking one arbitrary id and silently excluding its homonyms. `nil` means "all themes".
    var themeName: String?
    var year: Int?
    /// Collection only — filters by `CachedSet.currentListName`.
    var listName: String?
    /// History only — `nil` shows both owned and not-owned, `true`/`false` restricts to one.
    var ownedOnly: Bool?
    var sort: SetSortOption
    var sortAscending: Bool

    /// The screen's own "nothing selected yet" sort — `.dateScanned` for History/Collection,
    /// `.year` for `NewSetsView` (catalogue entries have no scan date). `isFilterActive`/
    /// `resetFilters`/`resetSort` compare/reset against this instead of a hardcoded option, so a
    /// screen with a non-`.dateScanned` default doesn't permanently read as "a filter is applied".
    private let defaultSort: SetSortOption

    init(defaultSort: SetSortOption = .dateScanned) {
        self.defaultSort = defaultSort
        self.sort = defaultSort
        self.sortAscending = defaultSort.defaultAscending
    }

    var isFilterActive: Bool {
        themeName != nil || year != nil || listName != nil || ownedOnly != nil ||
            sort != defaultSort || sortAscending != sort.defaultAscending
    }

    func resetFilters() {
        themeName = nil
        year = nil
        listName = nil
        ownedOnly = nil
        sort = defaultSort
        sortAscending = defaultSort.defaultAscending
    }

    func resetSort() {
        sort = defaultSort
        sortAscending = defaultSort.defaultAscending
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

/// Separate singleton, same reasoning as `CollectionFilterState`/`HistoryFilterState` (#206).
@MainActor
enum WishlistFilterState {
    static let shared = SetFilterState()
}

/// Separate singleton, same reasoning as `CollectionFilterState`/`HistoryFilterState`. Defaults to
/// `.dateAdded` (newest-seen first, see `OfflineCatalogStore.allFirstSeenAt()`) instead of
/// `SetFilterState`'s own `.dateScanned` default — catalogue entries were never scanned, so that
/// default would be meaningless here (see `SetFilterSheet.excludedSortOptions`, which hides that
/// option in the UI too). `.year` is still offered as an alternate sort, just no longer the
/// default — `.dateAdded` is the more accurate "new" signal once at least one prior sync exists to
/// diff against. Passed as this instance's `defaultSort` (not just its initial `sort`) so
/// `isFilterActive` doesn't permanently read "active" before the user has touched anything.
@MainActor
enum NewSetsFilterState {
    static let shared = SetFilterState(defaultSort: .dateAdded)
}

extension Array where Element == CachedSet {
    /// - Parameters:
    ///   - resolvedPrice: closure used only for `.price` sort — each screen passes its own rule
    ///     (new-price chain for History, condition-aware for Collection). Nil falls back to
    ///     `storePriceEUR` so callers that don't need price sorting can omit it.
    ///   - themeName: display-name resolver, used to match `filter.themeName` against every
    ///     `themeId` that resolves to it (see `SetFilterState.themeName`'s doc for why).
    @MainActor
    func filteredAndSorted(
        by filter: SetFilterState,
        resolvedPrice: ((CachedSet) -> Double?)? = nil,
        themeName: (Int) -> String = { ThemeNameStore.shared.displayName(forThemeId: $0) }
    ) -> [CachedSet] {
        var result = self

        let trimmedSearch = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedSearch) ||
                    $0.setNum.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
        if let selectedThemeName = filter.themeName {
            result = result.filter { themeName($0.themeId) == selectedThemeName }
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
        let priceFor = resolvedPrice ?? { $0.storePriceEUR }
        switch filter.sort {
        case .dateScanned:
            result.sort { ascending ? $0.lastScannedAt < $1.lastScannedAt : $0.lastScannedAt > $1.lastScannedAt }
        case .dateAdded:
            // Unreachable for History/Collection (excluded from their `SetFilterSheet` calls) — a
            // `CachedSet` has no "first seen in the offline catalogue" concept of its own; only
            // `NewSetsView`'s `Array<LegoSet>` extension below implements this for real.
            break
        case .year:
            result.sort { ascending ? $0.year < $1.year : $0.year > $1.year }
        case .name:
            result.sort {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .partCount:
            result.sort { ascending ? $0.numParts < $1.numParts : $0.numParts > $1.numParts }
        case .price:
            // Pre-resolve every price once — avoids calling the closure O(n log n) times
            // (each call may rebuild an expensive dictionary from SwiftData results).
            let prices = result.map { (set: $0, price: priceFor($0)) }
            result = prices.sorted {
                switch ($0.price, $1.price) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return ascending ? a < b : a > b
                }
            }.map(\.set)
        }

        return result
    }
}

extension Array where Element == LegoSet {
    /// Parallel to `Array<CachedSet>.filteredAndSorted` for `NewSetsView`, which browses the
    /// offline catalogue (`OfflineCatalogStore.allSets()`) rather than the SwiftData cache —
    /// mirrors how `MinifigFilterState.filteredAndSorted` solved the same problem for
    /// `OfflineMinifigCatalogStore.MinifigCatalogEntry`: closures for anything not stored
    /// directly on the element.
    /// - Parameters:
    ///   - owned: whether a given `setNum` is already in the local collection — cross-referenced
    ///     from `CachedSet` by the caller (a catalogue entry has no ownership info of its own).
    ///   - resolvedPrice: cache-only price lookup, used only for `.price` sort.
    ///   - firstSeenAt: when this device's downloaded snapshot first contained a given `setNum`
    ///     (`OfflineCatalogStore.allFirstSeenAt()`), used only for `.dateAdded` sort.
    ///   - themeName: display-name resolver, used to match `filter.themeName` against every
    ///     `themeId` that resolves to it (see `SetFilterState.themeName`'s doc for why).
    @MainActor
    func filteredAndSorted(
        by filter: SetFilterState,
        owned: (String) -> Bool,
        resolvedPrice: (LegoSet) -> Double?,
        firstSeenAt: (String) -> Date?,
        themeName: (Int) -> String = { ThemeNameStore.shared.displayName(forThemeId: $0) }
    ) -> [LegoSet] {
        var result = self

        let trimmedSearch = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedSearch) ||
                    $0.setNum.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
        if let selectedThemeName = filter.themeName {
            result = result.filter { themeName($0.themeId) == selectedThemeName }
        }
        if let year = filter.year {
            result = result.filter { $0.year == year }
        }
        // `listName` has no equivalent here — a catalogue entry has no Rebrickable set-list
        // membership (only owned sets do) — so this screen never offers that filter in the UI
        // (`availableListNames: []`) and `filter.listName` stays nil in practice.
        if let ownedOnly = filter.ownedOnly {
            result = result.filter { owned($0.setNum) == ownedOnly }
        }

        let ascending = filter.sortAscending
        switch filter.sort {
        case .dateScanned:
            // Unreachable through this screen's UI (excluded from `SetFilterSheet`, and the
            // singleton defaults away from it) — catalogue entries were never scanned, so there's
            // no meaningful order to apply here.
            break
        case .dateAdded:
            // The real "newly appeared in my catalogue" signal (see `OfflineCatalogStore
            // .allFirstSeenAt()`'s doc) — this is `NewSetsFilterState`'s default sort. Pre-resolve
            // once, same reasoning as `.price`. A `setNum` with no recorded first-seen date (the
            // very first-ever download hasn't finished yet, or a purge/re-download raced this
            // read) sorts last regardless of direction — nothing to compare it against.
            let dated = result.map { (set: $0, date: firstSeenAt($0.setNum)) }
            result = dated.sorted {
                switch ($0.date, $1.date) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return ascending ? a < b : a > b
                }
            }.map(\.set)
        case .year:
            // `year` alone ties constantly — it's the finest-grained date Rebrickable exposes, so
            // hundreds of sets share the same value (#185 feedback: within-year order looked
            // arbitrary, and `allSets()`'s `Dictionary.values` isn't even order-stable between
            // catalogue reloads). `setNum` as a secondary key doesn't claim to be a real
            // chronological signal, only a *stable, deterministic* one, so the list stops
            // reshuffling ties for no visible reason.
            result.sort {
                if $0.year != $1.year { return ascending ? $0.year < $1.year : $0.year > $1.year }
                return ascending ? $0.setNum < $1.setNum : $0.setNum > $1.setNum
            }
        case .name:
            result.sort {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .partCount:
            result.sort { ascending ? $0.numParts < $1.numParts : $0.numParts > $1.numParts }
        case .price:
            // Pre-resolve every price once — avoids calling the closure O(n log n) times, same
            // reasoning as the `CachedSet` version above.
            let prices = result.map { (set: $0, price: resolvedPrice($0)) }
            result = prices.sorted {
                switch ($0.price, $1.price) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return ascending ? a < b : a > b
                }
            }.map(\.set)
        }

        return result
    }
}
