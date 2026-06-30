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
    var priceUpdateErrorMessage: String?
    /// Mirrors `ThemeNameStore.shared.namesByThemeId` once `refreshIfNeeded()` resolves — copied
    /// into this `@Observable` property (rather than read directly from the store) so the view
    /// re-renders when names arrive after the initial, name-less render.
    var themeNames: [Int: String] = [:]

    private var ownedSets: [CachedSet] = []
    private let localRepository: LocalRepository
    private let priceRepository: PriceRepositoryProtocol
    private let legoStoreRepository: LegoStoreRepositoryProtocol
    private let themeNameStore: ThemeNameStore

    init(
        localRepository: LocalRepository,
        priceRepository: PriceRepositoryProtocol = PriceRepository(),
        legoStoreRepository: LegoStoreRepositoryProtocol = LegoStoreRepository(),
        themeNameStore: ThemeNameStore = .shared
    ) {
        self.localRepository = localRepository
        self.priceRepository = priceRepository
        self.legoStoreRepository = legoStoreRepository
        self.themeNameStore = themeNameStore
    }

    func load() {
        ownedSets = localRepository.ownedSets()
        let priceByNum = Dictionary(uniqueKeysWithValues: ownedSets.map { ($0.setNum, effectivePriceEUR(for: $0)) })
        stats = Self.computeStats(from: ownedSets, priceByNum: priceByNum)
        themeNames = themeNameStore.namesByThemeId
        Task {
            await themeNameStore.refreshIfNeeded()
            themeNames = themeNameStore.namesByThemeId
        }
    }

    func themeName(forThemeId themeId: Int) -> String {
        themeNames[themeId] ?? "Thème #\(themeId)"
    }

    var setsForExport: [CachedSet] { ownedSets }

    /// The price used for collection valuation and exports, in priority order: lego.com retail
    /// (`CachedSet.storePriceEUR`) first since it's the official current price, then Amazon, then
    /// BrickLink used/occasion as a last resort — both populated by the same batch refresh
    /// (`CollectionPriceUpdater`) and cached as `PriceQuote`s via `LocalRepository.cachedPrices`.
    /// BrickLink *new* is deliberately skipped: it's usually a third-party reseller markup over
    /// retail, not a meaningfully different signal from lego.com when that's missing.
    func effectivePriceEUR(for set: CachedSet) -> Double? {
        if let legoPrice = set.storePrice { return legoPrice }
        let quotes = localRepository.cachedPrices(setNum: set.setNum)
        if let amazon = quotes.first(where: { $0.source == .amazon }) {
            return NSDecimalNumber(decimal: amazon.amount).doubleValue
        }
        if let bricklinkUsed = quotes.first(where: { $0.source == .bricklinkUsed }) {
            return NSDecimalNumber(decimal: bricklinkUsed.amount).doubleValue
        }
        return nil
    }

    // MARK: - Collection price batch update

    /// Forwards to the same `CollectionPriceUpdater.shared` singleton `SettingsViewModel` reads
    /// from, so a run started here shows up identically if the user opens Settings instead, and
    /// vice versa — there is only ever one batch in flight.
    var isUpdatingAllPrices: Bool { CollectionPriceUpdater.shared.isRunning }
    var priceUpdateDone: Int { CollectionPriceUpdater.shared.done }
    var priceUpdateTotal: Int { CollectionPriceUpdater.shared.total }
    var hasResumablePriceUpdate: Bool { CollectionPriceUpdater.shared.hasResumableUpdate }
    var priceUpdateLastCompletedAt: Date? { CollectionPriceUpdater.shared.lastCompletedAt }

    func updateAllPrices(modelContext: ModelContext) async {
        priceUpdateErrorMessage = nil
        let sets = ownedSets.map { $0.asLegoSet() }
        guard !sets.isEmpty else {
            priceUpdateErrorMessage = "Aucun set dans votre collection."
            return
        }

        await PriceUpdateNotifier.requestAuthorizationIfNeeded()

        let result = await CollectionPriceUpdater.shared.start(
            allSets: sets,
            priceRepository: priceRepository,
            legoStoreRepository: legoStoreRepository,
            persist: CollectionPriceUpdater.persistClosure(modelContext: modelContext)
        )

        if result.completed {
            PriceUpdateNotifier.notifyCompleted(total: result.total)
            load()
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
