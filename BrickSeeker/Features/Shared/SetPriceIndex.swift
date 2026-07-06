import Foundation

/// Shared by `HistoryView` and `CollectionView` (#67): both derive the same "set number →
/// non-expired cached quotes" dictionary from an unfiltered `@Query` of `CachedSetPrice` before
/// applying their own price-resolution rule per row (`resolveNewPrice` /
/// `resolveCollectionPrice` — see SetRowView.swift).
enum SetPriceIndex {
    /// Groups non-expired cached price rows by set number. Expensive on a big collection
    /// (thousands of rows re-wrapped into `PriceQuote`s) — memoize behind `Version`, don't call
    /// per render.
    static func pricesBySetNum(_ prices: [CachedSetPrice]) -> [String: [PriceQuote]] {
        Dictionary(grouping: prices.filter { !$0.isExpired }.compactMap { p -> (String, PriceQuote)? in
            guard let q = p.quote else { return nil }
            return (p.setNum, q)
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    /// Cheap change token to memoize `pricesBySetNum(_:)` against, via
    /// `.onChange(of: Version(allCachedPrices), initial: true)`. `@Query` rows are classes that
    /// mutate **in place** (`cachePrices` re-uses existing rows), so neither array nor element
    /// identity can detect an update — but every cache write also refreshes `fetchedAt`, so
    /// (count, newest fetchedAt) moves on every insert, delete and update. Comparing it per
    /// render is O(n) with no allocations, versus rebuilding the whole dictionary per keystroke.
    struct Version: Equatable {
        private let count: Int
        private let newest: Date?

        init(_ prices: [CachedSetPrice]) {
            count = prices.count
            newest = prices.lazy.map(\.fetchedAt).max()
        }
    }
}
