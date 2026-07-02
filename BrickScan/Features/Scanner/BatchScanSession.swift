import Foundation
import Observation

struct BatchScanItem: Identifiable, Equatable {
    let id: String
    let legoSet: LegoSet
    let collectionStatus: CollectionStatus
    var storePrice: StorePrice?
    var priceQuotes: [PriceQuote] = []
    var isLoadingPrice = true

    /// Best (most negative) percentage gap between a scraped market price and the official
    /// lego.com price — the same "± vs store" comparison `SetDetailView` shows per-row
    /// (`PriceComparison.percentVsStore`), used here to pick the single number that ranks a set
    /// across a whole batch session. `nil` until both the store price and at least one
    /// matching-currency quote are in.
    var dealPercent: Int? {
        priceQuotes.compactMap { quote in
            PriceComparison.percentVsStore(
                amount: quote.amount,
                currency: quote.currency,
                storeAmount: storePrice?.amount,
                storeCurrency: storePrice?.currency
            )
        }.min()
    }
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
