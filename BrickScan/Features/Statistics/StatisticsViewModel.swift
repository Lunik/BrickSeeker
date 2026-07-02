import Foundation
import Observation
import SwiftData

/// One theme's slice of the collection. `themeId` is shown raw (e.g. "Thème #158") since
/// Rebrickable's `themes` endpoint isn't wired up — see issue #14's accepted fallback.
struct ThemeBreakdown: Identifiable {
    var id: Int { themeId }
    let themeId: Int
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
    let partCount: Int
    let themeCount: Int
    let themeBreakdown: [ThemeBreakdown]
    let yearBreakdown: [YearBreakdown]
    let totalValueEUR: Double
    let setsWithKnownPrice: Int
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
            partCount: 0,
            themeCount: 0,
            themeBreakdown: [],
            yearBreakdown: [],
            totalValueEUR: 0,
            setsWithKnownPrice: 0,
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
    func recomputeStats() {
        let priceByNum = Dictionary(uniqueKeysWithValues: ownedSets.map { ($0.setNum, effectivePriceEUR(for: $0)) })
        stats = Self.computeStats(from: ownedSets, priceByNum: priceByNum)
    }

    var setsForExport: [CachedSet] { ownedSets }

    /// The price used for collection valuation and exports. Source depends on the `ListCondition`
    /// annotated on the set's current list (see issue #47):
    ///
    /// - `.newSet` (default): lego.com → Amazon → BrickLink new
    /// - `.used`: BrickLink used only — nil when unavailable so occasion sets aren't
    ///   over-valued by a retail proxy.
    func effectivePriceEUR(for set: CachedSet) -> Double? {
        let condition = set.currentListId.flatMap { conditionByListId[$0] } ?? .newSet
        let quotes = localRepository.cachedPrices(setNum: set.setNum)
        switch condition {
        case .newSet:
            if let legoPrice = set.storePriceEUR { return legoPrice }
            if let amazon = quotes.first(where: { $0.source == .amazon }) {
                return NSDecimalNumber(decimal: amazon.amount).doubleValue
            }
            if let bricklinkNew = quotes.first(where: { $0.source == .bricklinkNew }) {
                return NSDecimalNumber(decimal: bricklinkNew.amount).doubleValue
            }
            return nil
        case .used:
            if let bricklinkUsed = quotes.first(where: { $0.source == .bricklinkUsed }) {
                return NSDecimalNumber(decimal: bricklinkUsed.amount).doubleValue
            }
            return nil
        }
    }

    /// `priceByNum` is precomputed by `load()` via `effectivePriceEUR(for:)` — the lego.com →
    /// Amazon → BrickLink-used fallback chain — since this function stays pure/static and has no
    /// repository access of its own.
    private static func computeStats(from sets: [CachedSet], priceByNum: [String: Double?]) -> CollectionStats {
        guard !sets.isEmpty else { return .empty }

        let partCount = sets.reduce(0) { $0 + $1.numParts * $1.quantity }
        let themeCount = Set(sets.map(\.themeId)).count

        let themeBreakdown = Dictionary(grouping: sets, by: \.themeId)
            .map { themeId, sets in
                ThemeBreakdown(
                    themeId: themeId,
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
            partCount: partCount,
            themeCount: themeCount,
            themeBreakdown: themeBreakdown,
            yearBreakdown: yearBreakdown,
            totalValueEUR: totalValueEUR,
            setsWithKnownPrice: pricedSets.count,
            mostExpensiveSet: mostExpensive?.set,
            mostExpensiveSetPriceEUR: mostExpensive?.price,
            oldestSet: sets.min { $0.year < $1.year },
            largestSet: sets.max { $0.numParts < $1.numParts }
        )
    }
}
