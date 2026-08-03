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
            seedPaidPriceFromScanIfNeeded(setNum: legoSet.setNum)
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

    /// Local-cache mirror of the collection-status half of `cacheSet`, for the Collection/
    /// Wishlist bulk "actions" menu (#141) — those callers already hold the `CachedSet` for each
    /// selected row and only need to reflect a remote move/add/remove that already succeeded via
    /// `RebrickableRepository`, not `cacheSet`'s full `LegoSet` upsert. No-ops if no row exists.
    func setCollectionStatus(setNum: String, isInCollection: Bool, listId: Int?, listName: String?) {
        guard let existing = cachedSet(setNum: setNum) else { return }
        existing.isInCollection = isInCollection
        existing.currentListId = listId
        existing.currentListName = listName
        if isInCollection {
            seedPaidPriceFromScanIfNeeded(setNum: setNum)
        }
        try? modelContext.save()
    }

    // MARK: - Paid price (`SetPurchaseRecord`)

    /// The price the user paid for this set, if recorded. Unlike the `CachedSet` setters above this
    /// never needs an existing `CachedSet` row — the purchase record is deliberately independent of
    /// the caches (see `SetPurchaseRecord`).
    func paidPrice(setNum: String) -> Double? {
        purchaseRecord(setNum: setNum)?.paidPriceEUR
    }

    /// Batch form for the collection-wide screens (Statistics), so they don't issue one fetch per
    /// set — same shape and intent as `conditionByListId()`.
    func paidPriceBySetNum() -> [String: Double] {
        let records = (try? modelContext.fetch(FetchDescriptor<SetPurchaseRecord>())) ?? []
        return Dictionary(records.map { ($0.setNum, $0.paidPriceEUR) }, uniquingKeysWith: { _, latest in latest })
    }

    /// Records (or overwrites) what the user paid. Passing `nil` clears the record, so the growth
    /// figure falls back to the retail basis rather than keeping a stale number.
    func setPaidPrice(setNum: String, paidPriceEUR: Double?) {
        let existing = purchaseRecord(setNum: setNum)
        guard let paidPriceEUR, paidPriceEUR > 0 else {
            if let existing { modelContext.delete(existing) }
            try? modelContext.save()
            return
        }
        if let existing {
            existing.paidPriceEUR = paidPriceEUR
            existing.recordedAt = Date()
        } else {
            modelContext.insert(SetPurchaseRecord(setNum: setNum, paidPriceEUR: paidPriceEUR))
        }
        try? modelContext.save()
    }

    /// Copies the in-store price the user typed at scan time into a purchase record, the moment a
    /// set enters the collection — "I saw it at 39,99 € and bought it" is by far the common case,
    /// and re-typing the same number would be busywork.
    ///
    /// Called from the two choke points every *in-app* add-to-collection path funnels through
    /// (`cacheSet` and `setCollectionStatus`) rather than from the six UI call sites
    /// (`SetDetailViewModel`, `CollectionView`, `HistoryView`, `WishlistView`, `NewSetsView`,
    /// `BatchSessionSummaryView`), which would be six chances to forget one.
    ///
    /// Deliberately **not** wired into `syncCollection`: a set added from the Rebrickable website
    /// and pulled down by a full sync gets no seed, even if a priced scan exists for it. Seeding
    /// there would attribute a shelf price to a purchase this device never witnessed — and the
    /// set's own detail screen seeds it on the next open anyway, via `cacheSet`.
    ///
    /// **Idempotent**: never overwrites an existing record, so a price the user edited by hand
    /// survives a later re-add or collection sync. Picks the **most recent** priced scan (the
    /// purchase follows the last time they looked at the shelf) — deliberately *not*
    /// `SetDetailView.bestPriceScanID`'s "cheapest scan" rule, which answers a different question
    /// ("where was it cheapest?"). Safe against `stripScanLocations`, which clears coordinates only
    /// and never `priceSeenEUR`.
    func seedPaidPriceFromScanIfNeeded(setNum: String) {
        guard purchaseRecord(setNum: setNum) == nil else { return }
        var descriptor = FetchDescriptor<ScanEvent>(
            predicate: #Predicate { $0.setNum == setNum && $0.priceSeenEUR != nil },
            sortBy: [SortDescriptor(\.scannedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let price = (try? modelContext.fetch(descriptor))?.first?.priceSeenEUR, price > 0 else { return }
        modelContext.insert(SetPurchaseRecord(setNum: setNum, paidPriceEUR: price))
        try? modelContext.save()
    }

    private func purchaseRecord(setNum: String) -> SetPurchaseRecord? {
        try? modelContext.fetch(
            FetchDescriptor<SetPurchaseRecord>(predicate: #Predicate { $0.setNum == setNum })
        ).first
    }

    // MARK: - Price alerts (issue #229)

    func priceAlerts() -> [PriceAlert] {
        let alerts = (try? modelContext.fetch(FetchDescriptor<PriceAlert>())) ?? []
        return alerts.sorted { $0.createdAt > $1.createdAt }
    }

    /// Both conditions' alerts for one set — `SetDetailView` shows the neuf and occasion alerts as
    /// two independent rows, since they're two independent alerts.
    func priceAlerts(setNum: String) -> [PriceAlert] {
        (try? modelContext.fetch(
            FetchDescriptor<PriceAlert>(predicate: #Predicate { $0.setNum == setNum })
        )) ?? []
    }

    func priceAlert(setNum: String, condition: ListCondition) -> PriceAlert? {
        let key = PriceAlert.key(setNum: setNum, condition: condition)
        return (try? modelContext.fetch(
            FetchDescriptor<PriceAlert>(predicate: #Predicate { $0.key == key })
        ))?.first
    }

    /// Creates or replaces the alert for `setNum`+`condition`. Exactly one of `thresholdEUR` /
    /// `discountPercent` is meaningful; the caller (`PriceAlertEntryView`) resolves the percentage's
    /// reference once, here it's only stored. Overwriting resets `wasBelowThreshold` — a new
    /// threshold is a new question, so the next evaluation must be free to fire even if the old one
    /// had already reported the price as low.
    ///
    /// `isEnabled` is a real parameter rather than a hardcoded `true`: the entry sheet now carries an
    /// on/off toggle, and saving from it must be able to *disable* an alert. Forcing `true` here
    /// would silently re-arm an alert the user had just switched off in the same sheet.
    @discardableResult
    func upsertPriceAlert(
        setNum: String,
        condition: ListCondition,
        setName: String,
        setImgUrl: String?,
        thresholdEUR: Double?,
        discountPercent: Double?,
        referencePriceEUR: Double?,
        referenceSourceName: String?,
        isEnabled: Bool = true
    ) -> PriceAlert {
        let alert: PriceAlert
        if let existing = priceAlert(setNum: setNum, condition: condition) {
            existing.setName = setName
            existing.setImgUrl = setImgUrl
            existing.thresholdEUR = thresholdEUR
            existing.discountPercent = discountPercent
            existing.referencePriceEUR = referencePriceEUR
            existing.referenceSourceName = referenceSourceName
            existing.isEnabled = isEnabled
            existing.wasBelowThreshold = false
            existing.lastNotifiedAt = nil
            alert = existing
        } else {
            let inserted = PriceAlert(
                setNum: setNum,
                condition: condition,
                setName: setName,
                setImgUrl: setImgUrl,
                thresholdEUR: thresholdEUR,
                discountPercent: discountPercent,
                referencePriceEUR: referencePriceEUR,
                referenceSourceName: referenceSourceName,
                nextRefreshDue: PriceWatchSchedule.nextDueDate()
            )
            inserted.isEnabled = isEnabled
            modelContext.insert(inserted)
            alert = inserted
        }
        try? modelContext.save()
        return alert
    }

    func setPriceAlertEnabled(_ alert: PriceAlert, isEnabled: Bool) {
        alert.isEnabled = isEnabled
        // Re-arms the crossing detector: a re-enabled alert should be able to notify again on the
        // next evaluation rather than staying silent because the price was already low when it was
        // switched off.
        if isEnabled { alert.wasBelowThreshold = false }
        try? modelContext.save()
    }

    func deletePriceAlert(_ alert: PriceAlert) {
        modelContext.delete(alert)
        try? modelContext.save()
    }

    /// Every set the background refresher is allowed to touch (#230): **only** the sets carrying at
    /// least one enabled alert. Deliberately not the whole collection — that was #5's objection to
    /// background refreshing, and this restricted scope is what answers it.
    ///
    /// The gift list was in scope originally, and was removed deliberately. The background pass can
    /// only query BrickLink (no window for a `WKWebView`), while `resolveWishlistPrice` reads
    /// best(Amazon, Cdiscount) → lego.com → BrickLink neuf → BrickLink occasion — so for any
    /// wishlisted set with a marketplace or retail price cached, which is the common case, the pass
    /// was refreshing a number the gift list doesn't display. It cost ~99% of the background work
    /// (a ~150-set gift list against a handful of alerts) to keep a mostly-invisible BrickLink
    /// history series warm. An alert, by contrast, is watched precisely because the user asked to be
    /// told about it. Don't put the wishlist back without first making a non-BrickLink source usable
    /// in the background — which `AGENTS.md` explains isn't possible.
    ///
    /// Returns one entry per set number, with the `LegoSet` reconstructed from the cache when a row
    /// exists and from the alert's own copy of the name otherwise (an alert outlives its
    /// `CachedSet`, so its set can genuinely have no row left).
    func priceWatchTargets() -> [PriceWatchTarget] {
        var targets: [String: PriceWatchTarget] = [:]

        let cachedBySetNum = Dictionary(
            ((try? modelContext.fetch(FetchDescriptor<CachedSet>())) ?? []).map { ($0.setNum, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for alert in priceAlerts() where alert.isEnabled {
            let legoSet = cachedBySetNum[alert.setNum]?.asLegoSet()
                ?? LegoSet(
                    setNum: alert.setNum,
                    name: alert.setName,
                    year: 0,
                    themeId: 0,
                    numParts: 0,
                    setImgUrl: alert.setImgUrl,
                    setUrl: nil
                )
            // A set can hold two alerts (neuf and occasion) — one fetch serves both, so the earlier
            // due date wins rather than the set being processed twice.
            let dueAt = min(targets[alert.setNum]?.dueAt ?? .distantFuture, alert.nextRefreshDue)
            targets[alert.setNum] = PriceWatchTarget(legoSet: legoSet, dueAt: dueAt)
        }

        return targets.values.sorted { $0.dueAt < $1.dueAt }
    }

    /// Re-draws the next due date for every alert on `setNum`, after a background pass processed it.
    /// All of them together: a set watched in both conditions must not come straight back due
    /// through the alert that wasn't reset.
    func rescheduleWatch(setNum: String) {
        let due = PriceWatchSchedule.nextDueDate()
        for alert in priceAlerts(setNum: setNum) {
            alert.nextRefreshDue = due
        }
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

    /// Records that the price batch (`CollectionPriceUpdater`) has fully processed this set — the
    /// caller stamps this after fetching *every* source, whether or not a price was found, so a set
    /// that still has no resolvable price afterwards is treated as "prix introuvable" rather than
    /// re-offered forever by "Compléter les prix manquants" (issue #194). No-ops if no row exists.
    func markPricesFetched(setNum: String) {
        guard let existing = cachedSet(setNum: setNum) else { return }
        existing.pricesFetchedAt = Date()
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
    /// `SetPurchaseRecord` is kept too, and for the strongest version of that reason: a paid
    /// price is typed by hand and cannot be re-fetched from anywhere. `PriceAlert` (#229) is kept
    /// for exactly the same reason — a threshold is hand-typed and unrecoverable — which is also
    /// why it lives in its own model rather than as a `CachedSet` column. `CollectionValueSnapshot`
    /// (#216) is kept on the `PriceHistoryEntry` reasoning taken to its limit: a past month's value
    /// isn't merely expensive to re-fetch, it is *unobtainable* — no source can tell us today what
    /// the collection was worth last March.
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
        // Unlike `PriceHistoryEntry` above, these *are* purged: BrickLink re-sends its whole
        // 6-month sales window on the next refresh, so nothing here is lost for good (#214).
        if let soldListings = try? modelContext.fetch(FetchDescriptor<SoldListingEntry>()) {
            soldListings.forEach { modelContext.delete($0) }
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

    /// Every cached price row in one fetch, for callers that need quotes for *many* sets at once
    /// (collection-wide valuation). Pair with `SetPriceIndex.pricesBySetNum` — calling
    /// `cachedPrices(setNum:)` in a loop issues one SwiftData fetch per set, which on a several-
    /// hundred-set collection is the difference between one query and hundreds per recompute.
    func allCachedPrices() -> [CachedSetPrice] {
        (try? modelContext.fetch(FetchDescriptor<CachedSetPrice>())) ?? []
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
                // Assigned unconditionally, `nil` included: a source that stopped reporting a
                // range must not keep showing the previous refresh's numbers next to a fresh
                // average.
                existing.minAmount = quote.minAmount
                existing.maxAmount = quote.maxAmount
                existing.lotCount = quote.lotCount
            } else {
                let inserted = CachedSetPrice(setNum: setNum, quote: quote)
                modelContext.insert(inserted)
                cachedBySource[source] = inserted // a duplicated source in `quotes` updates, not re-inserts
            }
            recordPriceHistory(setNum: setNum, source: source, amount: quote.amount, currency: quote.currency)
            // Only a quote that actually carries sales information may rewrite the stored rows —
            // `nil` means "this quote says nothing about sales" (a cache-rebuilt quote, or a source
            // with no such concept) and must leave them alone. See `PriceQuote.sales`.
            if let sales = quote.sales {
                replaceSoldListings(setNum: setNum, source: source, sales: sales, currency: quote.currency)
            }
        }
        try? modelContext.save()
    }

    /// Wholesale replacement of a set+source's sold listings (#214) — never an append. BrickLink
    /// re-sends its whole 6-month window on every refresh, so deleting first is both the simplest
    /// correct behaviour and the only one that can't accumulate the same sale once per refresh.
    /// An empty `sales` from a live fetch legitimately clears the rows: the sales aged out of the
    /// window, and keeping them would show a scatter BrickLink no longer stands behind.
    private func replaceSoldListings(setNum: String, source: String, sales: [SoldSale], currency: String) {
        let existing = (try? modelContext.fetch(
            FetchDescriptor<SoldListingEntry>(predicate: #Predicate { $0.setNum == setNum && $0.source == source })
        )) ?? []
        existing.forEach { modelContext.delete($0) }

        let fetchedAt = Date()
        for sale in sales {
            modelContext.insert(SoldListingEntry(
                setNum: setNum,
                source: source,
                unitAmount: sale.unitAmount,
                quantity: sale.quantity,
                orderedAt: sale.orderedAt,
                currency: currency,
                fetchedAt: fetchedAt
            ))
        }
    }

    /// Recorded BrickLink sales for a set, oldest first — the scatter series on `SetDetailView`'s
    /// price chart. Both conditions are returned; filtering to the set's own is the view's call.
    func soldListings(setNum: String) -> [SoldListingEntry] {
        let entries = (try? modelContext.fetch(
            FetchDescriptor<SoldListingEntry>(predicate: #Predicate { $0.setNum == setNum })
        )) ?? []
        return entries.sorted { $0.orderedAt < $1.orderedAt }
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

    // MARK: - Collection value history (issue #216)

    /// Records what the whole collection is worth this month — one `CollectionValueSnapshot` per
    /// calendar month, updated in place while the month is current. Built on the same fetch-most-
    /// recent-then-update-or-insert shape as `recordPriceHistory` above rather than an
    /// `@Attribute(.unique)` on `monthKey`: SwiftData's behaviour on a uniqueness conflict is
    /// subtler than this pattern, which is already proven here.
    ///
    /// Idempotent by design, because both callers fire freely — opening Statistiques and finishing a
    /// price batch — and neither knows what the other already wrote today.
    ///
    /// **The coverage guard is the load-bearing part.** `CachedSetPrice.isExpired` is 7 days, so a
    /// collection nobody has refreshed for a week resolves to a near-zero total; overwriting the
    /// current month with that would destroy a good reading and put a fictional crash in the chart.
    /// So: nothing is written at zero coverage, and an existing row for the current month is only
    /// replaced by a reading that priced **at least as many** sets as it did.
    func recordCollectionValueSnapshot(
        totalValueEUR: Double,
        setsCount: Int,
        unitsCount: Int,
        pricedSetsCount: Int,
        now: Date = Date()
    ) {
        guard pricedSetsCount > 0 else { return }

        let monthKey = CollectionValueSnapshot.monthKey(for: now)
        // Only the newest row can be this month's — sort + fetchLimit 1 instead of loading all 48.
        var latestDescriptor = FetchDescriptor<CollectionValueSnapshot>(
            sortBy: [SortDescriptor(\.monthKey, order: .reverse)]
        )
        latestDescriptor.fetchLimit = 1
        let latest = (try? modelContext.fetch(latestDescriptor))?.first

        if let latest, latest.monthKey == monthKey {
            guard pricedSetsCount >= latest.pricedSetsCount else { return }
            latest.capturedAt = now
            latest.totalValueEUR = totalValueEUR
            latest.setsCount = setsCount
            latest.unitsCount = unitsCount
            latest.pricedSetsCount = pricedSetsCount
        } else {
            modelContext.insert(CollectionValueSnapshot(
                monthKey: monthKey,
                capturedAt: now,
                totalValueEUR: totalValueEUR,
                setsCount: setsCount,
                unitsCount: unitsCount,
                pricedSetsCount: pricedSetsCount
            ))
            purgeCollectionValueSnapshotsBeyondRetention()
        }

        try? modelContext.save()
    }

    /// Keeps the newest 48 months, matching the depth BrickEconomy's `periods` exposes. Only ever
    /// runs right after an insert (an in-place update can't grow the table), and the table is ~48
    /// rows, so the full fetch here is deliberate — a predicate on a computed cutoff key would buy
    /// nothing.
    private func purgeCollectionValueSnapshotsBeyondRetention() {
        let all = (try? modelContext.fetch(
            FetchDescriptor<CollectionValueSnapshot>(sortBy: [SortDescriptor(\.monthKey, order: .reverse)])
        )) ?? []
        for snapshot in all.dropFirst(48) {
            modelContext.delete(snapshot)
        }
    }

    /// The collection's monthly value readings, oldest first — the series behind the
    /// "Valeur de la collection" chart.
    func collectionValueSnapshots() -> [CollectionValueSnapshot] {
        (try? modelContext.fetch(
            FetchDescriptor<CollectionValueSnapshot>(sortBy: [SortDescriptor(\.monthKey, order: .forward)])
        )) ?? []
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
