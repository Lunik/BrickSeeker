import Foundation
import Observation
import SwiftData

/// One theme's slice of the collection, grouped by resolved display name rather than raw
/// `themeId` — Rebrickable's theme table is hierarchical, so distinct ids can share a name, and
/// grouping by id alone used to split a single theme (e.g. "City") into two identical-looking
/// slices (issue #171). `themeId` is kept only as a stable `Identifiable` key (one representative
/// id per name group), not for display.
struct ThemeBreakdown: Identifiable {
    var id: Int { themeId }
    let themeId: Int
    let themeName: String
    let setCount: Int
    let partCount: Int
}

/// One 5-year bucket of the collection (e.g. "2020-24") rather than one bar per individual year:
/// a real collection can easily span 30-40 distinct years, and on a phone-width chart each
/// category only gets a few points of horizontal room — individually labeling that many slots
/// truncates to unreadable single characters no matter how many labels are thinned out, since
/// `AxisValueLabel` stays constrained to its own category's slot width. Bucketing by 5 years
/// caps the bar count at ~8-10 regardless of collection age, which is what actually fixes it.
struct YearBreakdown: Identifiable {
    var id: Int { bucketStart }
    let bucketStart: Int
    let setCount: Int
    /// Just the bucket's start year (e.g. "1985", not "1985-89") — even at only ~8-10 bars, the
    /// full range was still wide enough to get ellipsis-truncated by `AxisValueLabel`'s slot
    /// width on a real phone screen (confirmed on-device, not just reasoned about).
    var label: String { String(bucketStart) }
}

struct CollectionStats {
    let setCount: Int
    /// Σ `quantity` over the collection — the unit `totalValueEUR` is actually denominated in,
    /// unlike `setCount`, which counts *distinct* sets. Both are surfaced side by side rather
    /// than one replacing the other: the estimated-value caption used to read "basée sur X / Y
    /// sets" while the total below it weighted every price by `quantity`, so the sentence and the
    /// number it explained were counting different things.
    let unitCount: Int
    let partCount: Int
    let themeCount: Int
    let themeBreakdown: [ThemeBreakdown]
    let yearBreakdown: [YearBreakdown]
    let totalValueEUR: Double
    let setsWithKnownPrice: Int
    /// Σ `quantity` over the priced sets only — `setsWithKnownPrice`'s counterpart in the same
    /// unit as `totalValueEUR`.
    let pricedUnitCount: Int
    let mostExpensiveSet: CachedSet?
    /// The price actually used to pick `mostExpensiveSet` — may come from any source in the
    /// fallback chain, so it can't be read back off `mostExpensiveSet.storePriceEUR` (that's
    /// `nil` whenever the winning price came from Amazon/BrickLink instead).
    let mostExpensiveSetPriceEUR: Double?
    let oldestSet: CachedSet?
    let largestSet: CachedSet?

    static var empty: CollectionStats {
        CollectionStats(
            setCount: 0,
            unitCount: 0,
            partCount: 0,
            themeCount: 0,
            themeBreakdown: [],
            yearBreakdown: [],
            totalValueEUR: 0,
            setsWithKnownPrice: 0,
            pricedUnitCount: 0,
            mostExpensiveSet: nil,
            mostExpensiveSetPriceEUR: nil,
            oldestSet: nil,
            largestSet: nil
        )
    }
}

@Observable
@MainActor
final class StatisticsViewModel {
    var stats: CollectionStats = .empty

    private var ownedSets: [CachedSet] = []
    private var conditionByListId: [Int: ListCondition] = [:]
    private let localRepository: LocalRepository
    private let themeNameStore: ThemeNameStore

    init(
        localRepository: LocalRepository,
        themeNameStore: ThemeNameStore = .shared
    ) {
        self.localRepository = localRepository
        self.themeNameStore = themeNameStore
    }

    func load() {
        ownedSets = localRepository.ownedSets()
        conditionByListId = localRepository.conditionByListId()
        recomputeStats()
        // Theme names are read straight off the (observable) ThemeNameStore by the view —
        // this just makes sure the table exists/refreshes.
        Task { await themeNameStore.refreshIfNeeded() }
    }

    /// Re-derives `stats` from the already-fetched `ownedSets`/`conditionByListId` without
    /// refetching either — called after `load()` and again after every set processed by the
    /// price batch (see #48) so the total/coverage climb live instead of staying frozen until
    /// the whole batch completes. Safe to call repeatedly: `ownedSets` holds the same SwiftData
    /// model instances the batch's `persist` closure mutates (same `modelContext`), so each
    /// `CachedSet.storePriceEUR` write is already visible here without a re-fetch — only the
    /// derived `stats` snapshot itself needs reassigning to trigger a re-render, per the
    /// `@Observable`-only-tracks-stored-properties rule in AGENTS.md.
    ///
    /// Quotes come from **one** `allCachedPrices()` fetch grouped by set number, not from
    /// `effectivePriceEUR(for:)`'s per-set fetch: this runs once per `done` increment during a
    /// batch, so a per-set fetch made the whole run quadratic (~250 000 fetches for a 500-set
    /// collection) and visibly froze this screen. The index is deliberately rebuilt on every call
    /// and **not** cached between increments — each processed set inserts new `CachedSetPrice`
    /// rows, and a stale index would pin the total to its pre-batch value.
    func recomputeStats() {
        let quotesBySetNum = SetPriceIndex.pricesBySetNum(localRepository.allCachedPrices())
        let priceByNum = Dictionary(uniqueKeysWithValues: ownedSets.map { set in
            (set.setNum, effectivePriceEUR(for: set, quotes: quotesBySetNum[set.setNum] ?? []))
        })
        stats = Self.computeStats(
            from: ownedSets,
            priceByNum: priceByNum,
            themeName: { themeNameStore.displayName(forThemeId: $0) }
        )
    }

    var setsForExport: [CachedSet] { ownedSets }

    /// The price used for collection valuation and exports — the same `resolveCollectionPrice`
    /// the CollectionView row uses, so the list and the stats total always agree (issue #194).
    /// The set's list `ListCondition` picks the primary source, with a used↔new cross-fallback as
    /// last resort (see #47/#87/#194 in `resolveCollectionPrice`):
    ///
    /// - `.newSet` (default): lego.com → Amazon/Cdiscount → BrickLink new → BrickLink used
    /// - `.used`: BrickLink used → lego.com → Amazon/Cdiscount → BrickLink new
    ///
    /// `nil` only when no source has a price at all.
    ///
    /// This overload fetches the set's quotes itself, so it's the right entry point for a one-shot
    /// caller (the CSV/PDF exporters pass it as a closure). Anything iterating the whole collection
    /// should go through the `quotes:` overload with a `SetPriceIndex`-grouped index instead — see
    /// `recomputeStats()`.
    func effectivePriceEUR(for set: CachedSet) -> Double? {
        effectivePriceEUR(for: set, quotes: localRepository.cachedPrices(setNum: set.setNum))
    }

    /// `effectivePriceEUR(for:)` with the set's non-expired quotes already in hand — same
    /// resolution chain, no fetch. `quotes` must be pre-filtered the way both
    /// `LocalRepository.cachedPrices(setNum:)` and `SetPriceIndex.pricesBySetNum` do it (expired
    /// rows dropped), which is why callers pass one of those two.
    private func effectivePriceEUR(for set: CachedSet, quotes: [PriceQuote]) -> Double? {
        let condition = set.currentListId.flatMap { conditionByListId[$0] }
        return resolveCollectionPrice(storePriceEUR: set.storePriceEUR, condition: condition, quotes: quotes)
    }

    /// - Parameters:
    ///   - priceByNum: precomputed by `recomputeStats()` via `effectivePriceEUR(for:quotes:)` —
    ///     the `resolveCollectionPrice` fallback chain — since this function stays pure/static and
    ///     has no repository access of its own.
    ///   - themeName: display-name resolver, used to group `themeBreakdown` by name rather than
    ///     raw `themeId` (see `ThemeBreakdown`'s doc for why).
    private static func computeStats(
        from sets: [CachedSet],
        priceByNum: [String: Double?],
        themeName: (Int) -> String
    ) -> CollectionStats {
        guard !sets.isEmpty else { return .empty }

        let partCount = sets.reduce(0) { $0 + $1.numParts * $1.quantity }
        let themeCount = Set(sets.map(\.themeId).map(themeName)).count

        let themeBreakdown = Dictionary(grouping: sets) { themeName($0.themeId) }
            .map { name, sets in
                ThemeBreakdown(
                    themeId: sets.map(\.themeId).min() ?? 0,
                    themeName: name,
                    setCount: sets.count,
                    partCount: sets.reduce(0) { $0 + $1.numParts * $1.quantity }
                )
            }
            .sorted { $0.setCount > $1.setCount }

        let yearBreakdown = Dictionary(grouping: sets) { ($0.year / 5) * 5 }
            .map { bucketStart, sets in YearBreakdown(bucketStart: bucketStart, setCount: sets.count) }
            .sorted { $0.bucketStart < $1.bucketStart }

        let pricedSets: [(set: CachedSet, price: Double)] = sets.compactMap { set in
            guard let price = priceByNum[set.setNum] ?? nil else { return nil }
            return (set, price)
        }
        let totalValueEUR = pricedSets.reduce(0.0) { $0 + $1.price * Double($1.set.quantity) }
        let mostExpensive = pricedSets.max { $0.price < $1.price }

        return CollectionStats(
            setCount: sets.count,
            unitCount: sets.reduce(0) { $0 + $1.quantity },
            partCount: partCount,
            themeCount: themeCount,
            themeBreakdown: themeBreakdown,
            yearBreakdown: yearBreakdown,
            totalValueEUR: totalValueEUR,
            setsWithKnownPrice: pricedSets.count,
            pricedUnitCount: pricedSets.reduce(0) { $0 + $1.set.quantity },
            mostExpensiveSet: mostExpensive?.set,
            mostExpensiveSetPriceEUR: mostExpensive?.price,
            oldestSet: sets.min { $0.year < $1.year },
            largestSet: sets.max { $0.numParts < $1.numParts }
        )
    }
}
