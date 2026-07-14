import Foundation
import Observation

struct BatchScanItem: Identifiable, Equatable {
    let id: String
    let legoSet: LegoSet
    let collectionStatus: CollectionStatus
    var storePrice: StorePrice?
    var priceQuotes: [PriceQuote] = []
    var isLoadingPrice = true

    /// The best (most negative) "± vs store" gap (`PriceComparison.percentVsStore`, same
    /// comparison `SetDetailView` shows per-row) and which source produced it. Shared behind
    /// `dealPercent`/`dealSource` so the two can never disagree about which quote won.
    ///
    /// Neuf sources are preferred outright, falling back to the BrickLink-occasion quote only
    /// when no neuf source has one — a used listing being cheaper than lego.com retail isn't a
    /// "deal" the way a discounted new one is, so letting it silently win the ranking whenever it
    /// happened to be more negative made the badge conflate two different comparisons.
    ///
    /// Surfacing the source also matters because BrickLink/Amazon/Cdiscount are live, time-
    /// sensitive scrapes fetched independently here and again when `SetDetailView` opens (its own
    /// `loadPricesIfNeeded` deliberately never trusts a cached "found" value for a source that
    /// might have gone unavailable since) — a quote this batch fetch found can simply fail to
    /// reproduce moments later, leaving the detail page showing "Indisponible" for the very
    /// source that produced this percentage. Without a label, that made the number look like it
    /// corresponded to nothing (issue #157 follow-up); with one, it's still explained even if the
    /// source itself is no longer reachable.
    private var bestDeal: (percent: Int, source: PriceSource)? {
        func best(in quotes: [PriceQuote]) -> (percent: Int, source: PriceSource)? {
            quotes.compactMap { quote -> (percent: Int, source: PriceSource)? in
                guard let percent = PriceComparison.percentVsStore(
                    amount: quote.amount,
                    currency: quote.currency,
                    storeAmount: storePrice?.amount,
                    storeCurrency: storePrice?.currency
                ) else { return nil }
                return (percent, quote.source)
            }.min(by: { $0.percent < $1.percent })
        }
        let newQuotes = priceQuotes.filter { !$0.source.isUsed }
        let usedQuotes = priceQuotes.filter(\.source.isUsed)
        return best(in: newQuotes) ?? best(in: usedQuotes)
    }

    /// `nil` until both the store price and at least one matching-currency quote are in.
    var dealPercent: Int? { bestDeal?.percent }

    /// Which source produced `dealPercent` — see `bestDeal`'s doc comment.
    var dealSource: PriceSource? { bestDeal?.source }
}

/// Holds the sets accumulated while "mode lot" is active in `ScannerView` — scanning a set adds
/// it here instead of opening the blocking detail sheet, so the camera keeps running. Prices are
/// fetched one set at a time (not fanned out across the whole session at once) since each fetch
/// already opens its own WKWebView per source — see `AGENTS.md` on scraping cost.
@Observable
@MainActor
final class BatchScanSession {
    private(set) var items: [BatchScanItem] = []

    private let legoStoreRepository: LegoStoreRepositoryProtocol
    private let priceRepository: PriceRepositoryProtocol
    private var pendingSetNums: [String] = []
    private var isProcessingQueue = false

    init(
        legoStoreRepository: LegoStoreRepositoryProtocol = LegoStoreRepository(),
        priceRepository: PriceRepositoryProtocol = PriceRepository()
    ) {
        self.legoStoreRepository = legoStoreRepository
        self.priceRepository = priceRepository
    }

    var isEmpty: Bool { items.isEmpty }

    /// Items sorted best-deal-first (largest discount vs lego.com), with sets whose price isn't
    /// in yet (loading or unavailable) trailing in scan order.
    var sortedByDeal: [BatchScanItem] {
        items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.dealPercent, rhs.element.dealPercent) {
            case let (l?, r?): return l < r
            case (nil, nil): return lhs.offset < rhs.offset
            case (nil, _): return false
            case (_, nil): return true
            }
        }.map(\.element)
    }

    /// Returns `true` if a new item was appended, `false` if this set is already in the session
    /// (e.g. the live reconcile after a cache-instant add resolves the same set again).
    @discardableResult
    func add(_ legoSet: LegoSet, collectionStatus: CollectionStatus) -> Bool {
        guard !items.contains(where: { $0.id == legoSet.setNum }) else { return false }
        items.append(BatchScanItem(id: legoSet.setNum, legoSet: legoSet, collectionStatus: collectionStatus))
        pendingSetNums.append(legoSet.setNum)
        processQueueIfNeeded()
        return true
    }

    func clear() {
        items = []
        pendingSetNums = []
    }

    /// 1-based position in the fetch queue for a still-loading item (issue #157) — 1 while
    /// actively being fetched, 2 for the next one waiting, etc. `nil` once resolved either way
    /// (`isLoadingPrice == false`). The item being fetched right now has already been removed
    /// from `pendingSetNums` by `processQueue()` before its `await` starts, so it's the one
    /// loading item absent from that list; everything else is still in it, in wait order.
    func queuePosition(for setNum: String) -> Int? {
        guard let item = items.first(where: { $0.id == setNum }), item.isLoadingPrice else { return nil }
        if let pendingIndex = pendingSetNums.firstIndex(of: setNum) { return pendingIndex + 2 }
        return 1
    }

    private func processQueueIfNeeded() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        Task { await processQueue() }
    }

    private func processQueue() async {
        while !pendingSetNums.isEmpty {
            let setNum = pendingSetNums.removeFirst()
            await fetchPrice(for: setNum)
        }
        isProcessingQueue = false
    }

    private func fetchPrice(for setNum: String) async {
        guard let legoSet = items.first(where: { $0.id == setNum })?.legoSet,
              NetworkMonitor.shared.isConnected else {
            setItem(setNum) { $0.isLoadingPrice = false }
            return
        }
        async let storePrice = try? legoStoreRepository.fetchStorePrice(setNum: setNum)
        async let quotes = priceRepository.fetchPrices(for: legoSet)
        let resolvedStorePrice = await storePrice
        let resolvedQuotes = await quotes
        setItem(setNum) { item in
            item.storePrice = resolvedStorePrice
            item.priceQuotes = resolvedQuotes
            item.isLoadingPrice = false
        }
    }

    private func setItem(_ setNum: String, _ mutate: (inout BatchScanItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == setNum }) else { return }
        mutate(&items[index])
    }
}
