import Foundation
import SwiftData

/// Source key used for `PriceHistoryEntry` rows from the official lego.com price, which (unlike
/// `PriceQuote`) has no `PriceSource` case of its own.
let legoStoreHistorySource = "legoStore"

@MainActor
final class LocalRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func cacheSet(_ legoSet: LegoSet, isInCollection: Bool, listId: Int?, listName: String?) {
        let existing = try? modelContext.fetch(
            FetchDescriptor<CachedSet>(predicate: #Predicate { $0.setNum == legoSet.setNum })
        ).first

        if let existing {
            existing.name = legoSet.name
            existing.year = legoSet.year
            existing.numParts = legoSet.numParts
            existing.setImgUrl = legoSet.setImgUrl
            existing.setUrl = legoSet.setUrl
            existing.lastScannedAt = Date()
            existing.isInCollection = isInCollection
            existing.currentListId = listId
            existing.currentListName = listName
        } else {
            let cached = CachedSet(from: legoSet, isInCollection: isInCollection, currentListId: listId, currentListName: listName)
            modelContext.insert(cached)
        }
        try? modelContext.save()
    }

    /// Mirrors ScannerViewModel.state/HomeView's lookupViewModel.state into the cache after a
    /// resolution completes. Both Scanner and Home drive the same resolve flow, so this is the
    /// single place that keeps History/Collection in sync — see AGENTS.md "Local SwiftData cache".
    func cacheFoundState(_ state: ScannerState) {
        guard case .found(let legoSet, let collectionStatus) = state else { return }
        let isInCollection: Bool
        let listId: Int?
        switch collectionStatus {
        case .inCollection(let userSet):
            isInCollection = true
            listId = userSet.listId
        case .notInCollection, .unknown:
            isInCollection = false
            listId = nil
        }
        cacheSet(legoSet, isInCollection: isInCollection, listId: listId, listName: nil)
    }

    func recentlyScannedSets(limit: Int = 50) -> [CachedSet] {
        let descriptor = FetchDescriptor<CachedSet>(
            predicate: #Predicate { $0.wasScanned },
            sortBy: [SortDescriptor(\.lastScannedAt, order: .reverse)]
        )
        let results = try? modelContext.fetch(descriptor)
        return Array((results ?? []).prefix(limit))
    }

    func scannedSetsCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedSet>(predicate: #Predicate { $0.wasScanned }))) ?? 0
    }

    func ownedSets() -> [CachedSet] {
        let descriptor = FetchDescriptor<CachedSet>(
            predicate: #Predicate { $0.isInCollection },
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func ownedSetsCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedSet>(predicate: #Predicate { $0.isInCollection }))) ?? 0
    }

    func cachedSet(setNum: String) -> CachedSet? {
        try? modelContext.fetch(
            FetchDescriptor<CachedSet>(predicate: #Predicate { $0.setNum == setNum })
        ).first
    }

    /// No-ops if no CachedSet row exists yet — the price is only meaningful attached to a set
    /// already reached through the normal resolve flow (which always caches one first).
    func cacheStorePrice(setNum: String, price: StorePrice) {
        guard let existing = cachedSet(setNum: setNum) else { return }
        existing.storePriceEUR = price.amount
        existing.storeAvailability = price.availability
        existing.storePriceFetchedAt = Date()
        if let amount = price.amount {
            recordPriceHistory(setNum: setNum, source: legoStoreHistorySource, amount: Decimal(amount), currency: price.currency ?? "EUR")
        }
        try? modelContext.save()
    }

    func lastFullSyncAt() -> Date? {
        (try? modelContext.fetch(FetchDescriptor<CollectionSyncState>()).first)?.lastFullSyncAt
    }

    /// Full collection sync (offline browsing of owned sets). Distinct from the per-set
    /// fetchUserSet check (always live) — see AGENTS.md before touching either.
    func syncCollection(_ userSets: [UserSet], lists: [SetList]) {
        let listNameById = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.name) })

        // A set owned in multiple lists appears multiple times; keep only the first occurrence
        // since CachedSet (like the rest of the app) assumes one current list per set.
        var firstOccurrenceByNum: [String: UserSet] = [:]
        for userSet in userSets where firstOccurrenceByNum[userSet.setNum] == nil {
            firstOccurrenceByNum[userSet.setNum] = userSet
        }

        for (setNum, userSet) in firstOccurrenceByNum {
            let listName = userSet.listId.flatMap { listNameById[$0] }
            let existing = try? modelContext.fetch(
                FetchDescriptor<CachedSet>(predicate: #Predicate { $0.setNum == setNum })
            ).first
            if let existing {
                existing.name = userSet.legoSet.name
                existing.year = userSet.legoSet.year
                existing.themeId = userSet.legoSet.themeId
                existing.numParts = userSet.legoSet.numParts
                existing.setImgUrl = userSet.legoSet.setImgUrl
                existing.setUrl = userSet.legoSet.setUrl
                existing.quantity = userSet.quantity
                existing.isInCollection = true
                existing.currentListId = userSet.listId
                existing.currentListName = listName
                existing.lastSyncedAt = Date()
            } else {
                let cached = CachedSet(from: userSet.legoSet, isInCollection: true, currentListId: userSet.listId, currentListName: listName)
                cached.wasScanned = false
                cached.quantity = userSet.quantity
                cached.lastSyncedAt = Date()
                modelContext.insert(cached)
            }
        }

        let ownedSetNums = Set(firstOccurrenceByNum.keys)
        let previouslyOwned = (try? modelContext.fetch(
            FetchDescriptor<CachedSet>(predicate: #Predicate { $0.isInCollection })
        )) ?? []
        for cached in previouslyOwned where !ownedSetNums.contains(cached.setNum) {
            if cached.wasScanned {
                cached.isInCollection = false
                cached.currentListId = nil
                cached.currentListName = nil
            } else {
                modelContext.delete(cached)
            }
        }

        cacheSetLists(lists)
        if let syncState = try? modelContext.fetch(FetchDescriptor<CollectionSyncState>()).first {
            syncState.lastFullSyncAt = Date()
        } else {
            modelContext.insert(CollectionSyncState(lastFullSyncAt: Date()))
        }
        try? modelContext.save()
    }

    func cacheSetLists(_ setLists: [SetList]) {
        for setList in setLists {
            let existing = try? modelContext.fetch(
                FetchDescriptor<CachedSetList>(predicate: #Predicate { $0.listId == setList.id })
            ).first
            if let existing {
                existing.name = setList.name
                existing.numSets = setList.numSets
                existing.lastFetchedAt = Date()
            } else {
                modelContext.insert(CachedSetList(from: setList))
            }
        }
        try? modelContext.save()
    }

    func cachedSetLists() -> [CachedSetList] {
        (try? modelContext.fetch(FetchDescriptor<CachedSetList>())) ?? []
    }

    func clearAll() {
        if let sets = try? modelContext.fetch(FetchDescriptor<CachedSet>()) {
            sets.forEach { modelContext.delete($0) }
        }
        if let lists = try? modelContext.fetch(FetchDescriptor<CachedSetList>()) {
            lists.forEach { modelContext.delete($0) }
        }
        if let prices = try? modelContext.fetch(FetchDescriptor<CachedSetPrice>()) {
            prices.forEach { modelContext.delete($0) }
        }
        if let history = try? modelContext.fetch(FetchDescriptor<PriceHistoryEntry>()) {
            history.forEach { modelContext.delete($0) }
        }
        if let syncStates = try? modelContext.fetch(FetchDescriptor<CollectionSyncState>()) {
            syncStates.forEach { modelContext.delete($0) }
        }
        try? modelContext.save()
    }

    /// Non-expired cached price quotes for a set, regardless of source.
    func cachedPrices(setNum: String) -> [PriceQuote] {
        let cached = (try? modelContext.fetch(
            FetchDescriptor<CachedSetPrice>(predicate: #Predicate { $0.setNum == setNum })
        )) ?? []
        return cached.filter { !$0.isExpired }.compactMap(\.quote)
    }

    func cachePrices(_ quotes: [PriceQuote], setNum: String) {
        for quote in quotes {
            let source = quote.source.rawValue
            let existing = try? modelContext.fetch(
                FetchDescriptor<CachedSetPrice>(predicate: #Predicate { $0.setNum == setNum && $0.source == source })
            ).first

            if let existing {
                existing.amount = quote.amount
                existing.currency = quote.currency
                existing.sourceURLString = quote.sourceURL?.absoluteString
                existing.fetchedAt = quote.fetchedAt
            } else {
                modelContext.insert(CachedSetPrice(setNum: setNum, quote: quote))
            }
            recordPriceHistory(setNum: setNum, source: source, amount: quote.amount, currency: quote.currency)
        }
        try? modelContext.save()
    }

    /// Appends a price reading for `setNum`+`source`, skipping the insert if one was already
    /// recorded today — keeps the history one point per day per source (see issue #5) instead of
    /// stacking duplicates every time `SetDetail` is opened or refreshed. Also trims entries older
    /// than 180 days so the table doesn't grow unbounded.
    private func recordPriceHistory(setNum: String, source: String, amount: Decimal, currency: String) {
        let existing = (try? modelContext.fetch(
            FetchDescriptor<PriceHistoryEntry>(predicate: #Predicate { $0.setNum == setNum && $0.source == source })
        )) ?? []

        if let mostRecent = existing.max(by: { $0.fetchedAt < $1.fetchedAt }),
           Calendar.current.isDateInToday(mostRecent.fetchedAt) {
            return
        }

        modelContext.insert(PriceHistoryEntry(setNum: setNum, source: source, amount: amount, currency: currency))

        let cutoff = Date().addingTimeInterval(-180 * 24 * 60 * 60)
        for entry in existing where entry.fetchedAt < cutoff {
            modelContext.delete(entry)
        }
    }

    /// All recorded price readings for a set, oldest first, for the history chart in `SetDetail`.
    func priceHistory(setNum: String) -> [PriceHistoryEntry] {
        let entries = (try? modelContext.fetch(
            FetchDescriptor<PriceHistoryEntry>(predicate: #Predicate { $0.setNum == setNum })
        )) ?? []
        return entries.sorted { $0.fetchedAt < $1.fetchedAt }
    }
}
