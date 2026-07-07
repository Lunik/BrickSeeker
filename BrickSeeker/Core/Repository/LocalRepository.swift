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

    /// `markAsScanned` gates `wasScanned`/`lastScannedAt` specifically — those two drive whether
    /// (and where, in History's sort order) this set shows up as "scanned" (issue #133), separate
    /// from the rest of this metadata (name/collection status/etc.), which is always worth
    /// refreshing regardless of why the set was looked up. Pass `false` for a reconcile of an
    /// already-open detail view (`SetDetailView.syncCache`, reached by History/Collection/
    /// Wishlist/Statistics reopens just as often as by a fresh scan) so simply looking at a set
    /// again doesn't silently mark it "scanned" or bump it to the top of History.
    func cacheSet(_ legoSet: LegoSet, isInCollection: Bool, listId: Int?, listName: String?, markAsScanned: Bool) {
        let existing = try? modelContext.fetch(
            FetchDescriptor<CachedSet>(predicate: #Predicate { $0.setNum == legoSet.setNum })
        ).first

        if let existing {
            existing.name = legoSet.name
            existing.year = legoSet.year
            existing.numParts = legoSet.numParts
            existing.setImgUrl = legoSet.setImgUrl
            existing.setUrl = legoSet.setUrl
            if markAsScanned {
                existing.wasScanned = true
                existing.lastScannedAt = Date()
            }
            existing.isInCollection = isInCollection
            existing.currentListId = listId
            existing.currentListName = listName
        } else {
            let cached = CachedSet(from: legoSet, isInCollection: isInCollection, currentListId: listId, currentListName: listName)
            if !markAsScanned {
                cached.wasScanned = false
            }
            modelContext.insert(cached)
        }
        if isInCollection {
            stripScanLocations(setNums: [legoSet.setNum])
        }
        try? modelContext.save()
    }

    /// Mirrors ScannerViewModel.state/HomeView's lookupViewModel.state into the cache after a
    /// resolution completes. Both Scanner and Home drive the same resolve flow, so this is the
    /// single place that keeps History/Collection in sync — see AGENTS.md "Local SwiftData cache".
    func cacheFoundState(_ state: ScannerState, markAsScanned: Bool) {
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
        cacheSet(legoSet, isInCollection: isInCollection, listId: listId, listName: nil, markAsScanned: markAsScanned)
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

    func wishlistSetsCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedSet>(predicate: #Predicate { $0.isInWishlist }))) ?? 0
    }

    func cachedSet(setNum: String) -> CachedSet? {
        try? modelContext.fetch(
            FetchDescriptor<CachedSet>(predicate: #Predicate { $0.setNum == setNum })
        ).first
    }

    /// No-ops if no CachedSet row exists yet — wishlist status is only meaningful attached to a
    /// set already reached through the normal resolve flow (which always caches one first).
    func setWishlistStatus(setNum: String, isInWishlist: Bool) {
        guard let existing = cachedSet(setNum: setNum) else { return }
        existing.isInWishlist = isInWishlist
        try? modelContext.save()
    }

    /// No-ops if no CachedSet row exists yet, mirroring `setWishlistStatus` — `cacheSet` never
    /// touches `quantity` (only `syncCollection`'s full reconcile does), so a quantity edit needs
    /// this dedicated setter rather than being folded into `cacheSet`.
    func setQuantity(setNum: String, quantity: Int) {
        guard let existing = cachedSet(setNum: setNum) else { return }
        existing.quantity = quantity
        try? modelContext.save()
    }

    /// Reconciles every *already-cached* set's `isInWishlist` against Brickset's wanted-sets
    /// list — mirrors `syncCollection`'s reconcile approach. Never creates new rows itself (no
    /// `LegoSet` data to populate one with here); pair with `cachedSetNums()`/`cacheWishlistSet`
    /// (see `WishlistSync.apply`) to also cover wanted sets with no local row yet — a set never
    /// scanned or owned wouldn't otherwise appear anywhere in the app despite being wanted.
    func syncWishlist(wantedSetNums: Set<String>) {
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedSet>())) ?? []
        for cached in allCached {
            let shouldBeWanted = wantedSetNums.contains(cached.setNum)
            if cached.isInWishlist != shouldBeWanted {
                cached.isInWishlist = shouldBeWanted
            }
        }
        try? modelContext.save()
    }

    /// Every set number currently in the local cache — used to find which of Brickset's wanted
    /// sets (see `syncWishlist`) have no cached row yet and need `cacheWishlistSet`.
    func cachedSetNums() -> Set<String> {
        Set((try? modelContext.fetch(FetchDescriptor<CachedSet>()))?.map(\.setNum) ?? [])
    }

    /// Inserts a wishlist-only row for a set with no existing cache entry (never scanned or
    /// owned) — the counterpart to `syncWishlist`'s reconcile-only pass, using catalog data
    /// already fetched by the caller (`WishlistSync.apply`) since this type has no network
    /// access of its own. No-ops if a row already exists (race with a concurrent cache write).
    func cacheWishlistSet(_ legoSet: LegoSet) {
        guard cachedSet(setNum: legoSet.setNum) == nil else { return }
        let cached = CachedSet(from: legoSet)
        cached.wasScanned = false
        cached.isInWishlist = true
        modelContext.insert(cached)
        try? modelContext.save()
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
        // External API data — a duplicated list id must not crash the sync (first wins).
        let listNameById = Dictionary(lists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        // A set owned in multiple lists appears multiple times; keep only the first occurrence
        // since CachedSet (like the rest of the app) assumes one current list per set.
        var firstOccurrenceByNum: [String: UserSet] = [:]
        for userSet in userSets where firstOccurrenceByNum[userSet.setNum] == nil {
            firstOccurrenceByNum[userSet.setNum] = userSet
        }

        // One fetch of every cached set, indexed by setNum, instead of one fetch per owned set
        // (a 500-set collection used to mean 500 fetches here, on every sync). The same array
        // also serves the "previously owned but gone from the sync" cleanup below, which used to
        // be its own re-fetch.
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedSet>())) ?? []
        let cachedBySetNum = Dictionary(allCached.map { ($0.setNum, $0) }, uniquingKeysWith: { first, _ in first })

        for (setNum, userSet) in firstOccurrenceByNum {
            let listName = userSet.listId.flatMap { listNameById[$0] }
            if let existing = cachedBySetNum[setNum] {
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

        // `isInCollection` is read after the upsert loop mutated these same instances, so a row
        // that just became owned is current here — and skipped via `ownedSetNums` regardless,
        // exactly like the old post-upsert re-fetch behaved.
        let ownedSetNums = Set(firstOccurrenceByNum.keys)
        for cached in allCached where cached.isInCollection && !ownedSetNums.contains(cached.setNum) {
            if cached.wasScanned {
                cached.isInCollection = false
                cached.currentListId = nil
                cached.currentListName = nil
            } else {
                modelContext.delete(cached)
            }
        }

        // Owned sets lose their scan locations — the position's only purpose is "in which store
        // did I see this deal", moot once the set is in the collection (issue #46).
        stripScanLocations(setNums: ownedSetNums)

        cacheSetLists(lists)
        if let syncState = try? modelContext.fetch(FetchDescriptor<CollectionSyncState>()).first {
            syncState.lastFullSyncAt = Date()
        } else {
            modelContext.insert(CollectionSyncState(lastFullSyncAt: Date()))
        }
        try? modelContext.save()
    }

    func cacheSetLists(_ setLists: [SetList]) {
        // One fetch indexed by listId instead of one fetch per list.
        let cached = (try? modelContext.fetch(FetchDescriptor<CachedSetList>())) ?? []
        let cachedByListId = Dictionary(cached.map { ($0.listId, $0) }, uniquingKeysWith: { first, _ in first })
        for setList in setLists {
            if let existing = cachedByListId[setList.id] {
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

    func conditionByListId() -> [Int: ListCondition] {
        Dictionary(uniqueKeysWithValues: cachedSetLists().map { ($0.listId, $0.condition) })
    }

    /// Deliberately does NOT touch `PriceHistoryEntry` — the price-evolution chart in
    /// `SetDetail` is the whole point of recording it over time, and "vider le cache"
    /// is meant to discard reconstructible short-TTL data (cached sets/lists/current
    /// prices), not a history the app can't get back by re-fetching. `ScanEvent` rows are
    /// kept for the same reason (they're the "when did I scan this" history), but their
    /// location fields are stripped: purging the history revokes the "where" (issue #46).
    func clearAll() {
        stripScanLocations(setNums: nil)
        if let sets = try? modelContext.fetch(FetchDescriptor<CachedSet>()) {
            sets.forEach { modelContext.delete($0) }
        }
        if let lists = try? modelContext.fetch(FetchDescriptor<CachedSetList>()) {
            lists.forEach { modelContext.delete($0) }
        }
        if let prices = try? modelContext.fetch(FetchDescriptor<CachedSetPrice>()) {
            prices.forEach { modelContext.delete($0) }
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

    /// `reconcile` should only be `true` when `quotes` comes from a genuine live fetch attempt
    /// (not a cache-only read) — it deletes any cached source missing from `quotes`, so a source
    /// that went "Indisponible" stops showing its last known price for the rest of the 7-day
    /// cache TTL. Left `false` for cache-only writes (e.g. the collection-wide batch updater),
    /// where an empty/partial result can't be distinguished from a transient network hiccup.
    func cachePrices(_ quotes: [PriceQuote], setNum: String, reconcile: Bool = false) {
        // One fetch of this set's cached price rows, indexed by source, instead of one fetch per
        // quote — it also serves the reconcile pass.
        let cached = (try? modelContext.fetch(
            FetchDescriptor<CachedSetPrice>(predicate: #Predicate { $0.setNum == setNum })
        )) ?? []
        var cachedBySource = Dictionary(cached.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })

        if reconcile {
            let fetchedSources = Set(quotes.map { $0.source.rawValue })
            for entry in cached where !fetchedSources.contains(entry.source) {
                modelContext.delete(entry)
            }
        }
        for quote in quotes {
            let source = quote.source.rawValue
            if let existing = cachedBySource[source] {
                existing.amount = quote.amount
                existing.currency = quote.currency
                existing.sourceURLString = quote.sourceURL?.absoluteString
                existing.fetchedAt = quote.fetchedAt
            } else {
                let inserted = CachedSetPrice(setNum: setNum, quote: quote)
                modelContext.insert(inserted)
                cachedBySource[source] = inserted // a duplicated source in `quotes` updates, not re-inserts
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
        // "Already recorded today?" needs only the most recent entry — sort + fetchLimit 1
        // instead of loading the set's whole history into memory to run max(by:) on it.
        var latestDescriptor = FetchDescriptor<PriceHistoryEntry>(
            predicate: #Predicate { $0.setNum == setNum && $0.source == source },
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        latestDescriptor.fetchLimit = 1
        if let mostRecent = (try? modelContext.fetch(latestDescriptor))?.first,
           Calendar.current.isDateInToday(mostRecent.fetchedAt) {
            return
        }

        modelContext.insert(PriceHistoryEntry(setNum: setNum, source: source, amount: amount, currency: currency))

        let cutoff = Date().addingTimeInterval(-180 * 24 * 60 * 60)
        let staleEntries = (try? modelContext.fetch(
            FetchDescriptor<PriceHistoryEntry>(
                predicate: #Predicate { $0.setNum == setNum && $0.source == source && $0.fetchedAt < cutoff }
            )
        )) ?? []
        for entry in staleEntries {
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

    // MARK: - Scan events (issue #46)

    /// Appends one `ScanEvent` — called from `ScannerViewModel.resolveSet` for camera scans only
    /// (see the doc on `ScanEvent`). Returned so the caller can attach a location fix later.
    func recordScanEvent(setNum: String, priceSeenEUR: Double? = nil) -> ScanEvent {
        let event = ScanEvent(setNum: setNum, priceSeenEUR: priceSeenEUR)
        modelContext.insert(event)
        try? modelContext.save()
        return event
    }

    /// Overwrites the auto-resolved "price seen" with what the user actually typed in the
    /// "quel prix as-tu vu ?" prompt shown right after a camera scan.
    func updateScanEventPrice(_ event: ScanEvent, priceSeenEUR: Double?) {
        event.priceSeenEUR = priceSeenEUR
        try? modelContext.save()
    }

    /// Attaches a (possibly late-arriving) location fix to a scan event. No-ops if the set
    /// joined the collection in the meantime — the strip-on-add rule must win the race against
    /// a slow GPS fix, or a just-bought set would end up located anyway.
    func attachLocation(to event: ScanEvent, latitude: Double, longitude: Double, placeName: String?) {
        guard cachedSet(setNum: event.setNum)?.isInCollection != true else { return }
        event.latitude = latitude
        event.longitude = longitude
        event.placeName = placeName
        try? modelContext.save()
    }

    /// Removes the location fields (never the rows — the "when" history stays) from scan
    /// events. `setNums == nil` strips everything (history purge).
    func stripScanLocations(setNums: Set<String>?) {
        let located = (try? modelContext.fetch(
            FetchDescriptor<ScanEvent>(predicate: #Predicate { $0.latitude != nil })
        )) ?? []
        for event in located where setNums?.contains(event.setNum) != false {
            event.latitude = nil
            event.longitude = nil
            event.placeName = nil
        }
        try? modelContext.save()
    }

    /// Removes a single `ScanEvent` occurrence — the "supprimer ce scan" swipe on `SetDetailView`
    /// (issue #88). Never touches `CachedSet` itself, except that `lastScannedAt` is recomputed
    /// from the remaining rows when the deleted event was the most recent one, since that field
    /// otherwise keeps pointing at a scan that no longer exists.
    func deleteScanEvent(_ event: ScanEvent) {
        let setNum = event.setNum
        let wasNewest = (try? modelContext.fetch(
            FetchDescriptor<ScanEvent>(
                predicate: #Predicate<ScanEvent> { $0.setNum == setNum },
                sortBy: [SortDescriptor(\.scannedAt, order: .reverse)]
            )
        ))?.first?.persistentModelID == event.persistentModelID

        modelContext.delete(event)

        if wasNewest, let cached = cachedSet(setNum: setNum) {
            let remaining = (try? modelContext.fetch(
                FetchDescriptor<ScanEvent>(
                    predicate: #Predicate<ScanEvent> { $0.setNum == setNum },
                    sortBy: [SortDescriptor(\.scannedAt, order: .reverse)]
                )
            ))?.first
            if let mostRecent = remaining {
                cached.lastScannedAt = mostRecent.scannedAt
            }
        }

        try? modelContext.save()
    }

    /// Removes a set from the History screen (issue #88, swipe on `HistoryView`'s row). `CachedSet`
    /// is a single row shared between History and Collection (`wasScanned` distinguishes their
    /// origin — see `AGENTS.md`), so a set still owned must not disappear from the Collection: it
    /// only loses `wasScanned`, falling back to a collection-only row exactly as if it had never
    /// been scanned. A set no longer owned is deleted outright, taking its `ScanEvent` rows with it.
    func deleteFromHistory(setNum: String) {
        guard let cached = cachedSet(setNum: setNum) else { return }
        if cached.isInCollection {
            cached.wasScanned = false
        } else {
            modelContext.delete(cached)
            let events = (try? modelContext.fetch(
                FetchDescriptor<ScanEvent>(predicate: #Predicate<ScanEvent> { $0.setNum == setNum })
            )) ?? []
            events.forEach { modelContext.delete($0) }
        }
        try? modelContext.save()
    }
}
