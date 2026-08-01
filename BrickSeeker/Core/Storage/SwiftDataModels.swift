import Foundation
import SwiftData

@Model
final class CachedSet {
    @Attribute(.unique) var setNum: String
    var name: String
    var year: Int
    var themeId: Int = 0
    var numParts: Int
    var setImgUrl: String?
    var setUrl: String?
    var quantity: Int = 1
    var lastScannedAt: Date
    /// True if this row exists because the user scanned it; false if it only exists from a
    /// collection sync. Distinguishes History (scanned sets) from Collection (owned sets).
    var wasScanned: Bool = true
    var lastSyncedAt: Date?
    var isInCollection: Bool
    var currentListId: Int?
    var currentListName: String?
    var storePriceEUR: Double?
    var storeAvailability: String?
    var storePriceFetchedAt: Date?
    /// When the collection price *batch* (`CollectionPriceUpdater`) last processed this set,
    /// regardless of whether any price was actually found — stamped even on a fully empty result.
    /// Distinct from `storePriceFetchedAt` (lego.com only, never set for minifigs or sets absent
    /// from the store): this is the "we have already tried every source for this set" flag that
    /// tells the "Compléter les prix manquants" button a still-unpriced set is *definitively*
    /// unfindable rather than merely not-yet-fetched, so it stops looping on it (issue #194).
    var pricesFetchedAt: Date?
    /// Mirrors Brickset's `wanted` flag (see `BricksetRepository`) — deliberately independent of
    /// `isInCollection`: a set can be wishlisted, owned, both, or neither.
    var isInWishlist: Bool = false

    init(from legoSet: LegoSet, isInCollection: Bool = false, currentListId: Int? = nil, currentListName: String? = nil) {
        self.setNum = legoSet.setNum
        self.name = legoSet.name
        self.year = legoSet.year
        self.themeId = legoSet.themeId
        self.numParts = legoSet.numParts
        self.setImgUrl = legoSet.setImgUrl
        self.setUrl = legoSet.setUrl
        self.lastScannedAt = Date()
        self.isInCollection = isInCollection
        self.currentListId = currentListId
        self.currentListName = currentListName
    }

    /// Typed view of the raw `product:availability` string cached alongside the lego.com price.
    /// A row that never had a lego.com price fetched has `storeAvailability == nil` → `.unknown`,
    /// which is exactly what the "Disponibilité" filter needs to keep unchecked sets out of the
    /// three real states (#226). Computed, so nothing new is persisted.
    var storeAvailabilityStatus: StoreAvailabilityStatus {
        StoreAvailabilityStatus(rawValue: storeAvailability)
    }

    func asLegoSet() -> LegoSet {
        LegoSet(setNum: setNum, name: name, year: year, themeId: themeId, numParts: numParts, setImgUrl: setImgUrl, setUrl: setUrl)
    }

    func asCollectionStatus() -> CollectionStatus {
        guard isInCollection else { return .notInCollection }
        let userSet = UserSet(legoSet: asLegoSet(), quantity: quantity, includeSpares: false, listId: currentListId)
        return .inCollection(userSet)
    }
}

/// One append-only row per real **camera** scan of a set (non-camera lookups — manual entry,
/// photo import, History tap — are deliberately not recorded: they carry no "I was standing in a
/// store" meaning). Replaces the information lost by `CachedSet.lastScannedAt` being overwritten
/// on every scan — see GitHub issue #46.
///
/// The location fields are only ever set when the user opted in (Settings) and iOS granted
/// When-In-Use permission, and they are stripped (not the row itself) as soon as the set joins
/// the collection or the history is purged — the location's only purpose is "in which store did
/// I see this deal", which is moot once the set is bought.
@Model
final class ScanEvent {
    var setNum: String
    var scannedAt: Date
    var latitude: Double?
    var longitude: Double?
    /// Reverse-geocoded, human-readable place name for the coordinates above (e.g.
    /// "Carrefour, Nice"). Filled in asynchronously after the scan, so it can stay nil even
    /// when coordinates are present.
    var placeName: String?
    /// The in-store price the user actually typed in the "quel prix as-tu vu ?" prompt shown
    /// right after the scan — nil until they do (skipping the prompt, or scanning a set already
    /// in the collection where no prompt is shown, leaves this nil). Deliberately never
    /// backfilled from the online market price (lego.com/Amazon/BrickLink, already shown on the
    /// price card and tracked separately in `PriceHistoryEntry`) — this field means "seen with my
    /// own eyes", nothing else. Lets SetDetail flag the scan where the best in-store price was
    /// actually seen.
    var priceSeenEUR: Double?

    init(setNum: String, scannedAt: Date = Date(), priceSeenEUR: Double? = nil) {
        self.setNum = setNum
        self.scannedAt = scannedAt
        self.priceSeenEUR = priceSeenEUR
    }

    var hasLocation: Bool {
        latitude != nil && longitude != nil
    }
}

/// What the user actually paid for a set they own — the local equivalent of BrickEconomy's
/// `paid_price`, and the preferred basis for the growth figure shown on `SetDetailView`.
///
/// Deliberately **not** a field on `CachedSet`, even though it is 1:1 with one: `CachedSet` rows
/// are destroyed by two routine paths — `LocalRepository.clearAll()` ("vider le cache") and
/// `syncCollection`'s cleanup of sets that dropped out of the collection — so a set temporarily
/// removed from a Rebrickable list, or a cache clear, would silently destroy a number the user
/// typed by hand and cannot recover. Same doctrine that already keeps `ScanEvent`/
/// `PriceHistoryEntry` out of `clearAll`: anything hand-entered outlives the caches.
///
/// Seeded automatically from the in-store price of the most recent priced `ScanEvent` when a set
/// enters the collection (see `LocalRepository.seedPaidPriceFromScanIfNeeded`), and editable
/// afterwards from the set's detail screen.
@Model
final class SetPurchaseRecord {
    @Attribute(.unique) var setNum: String
    var paidPriceEUR: Double
    var currency: String = "EUR"
    /// When this price was recorded — lets the UI distinguish a value seeded from a scan from one
    /// the user typed later, and is the tiebreaker if a future migration ever needs one.
    var recordedAt: Date

    init(setNum: String, paidPriceEUR: Double, currency: String = "EUR", recordedAt: Date = Date()) {
        self.setNum = setNum
        self.paidPriceEUR = paidPriceEUR
        self.currency = currency
        self.recordedAt = recordedAt
    }
}

@Model
final class CollectionSyncState {
    var lastFullSyncAt: Date?

    init(lastFullSyncAt: Date? = nil) {
        self.lastFullSyncAt = lastFullSyncAt
    }
}

/// A price quote scraped from an external source (BrickLink, Amazon),
/// cached per set+source so the price section doesn't re-scrape on every
/// screen visit. Prices move slowly, so the TTL is much longer than
/// `CachedSet`'s.
@Model
final class CachedSetPrice {
    var setNum: String
    var source: String
    var amount: Decimal
    var currency: String
    var sourceURLString: String?
    var fetchedAt: Date
    /// BrickLink's min/max + lot count for this same quote (#213). Optional columns here rather
    /// than a second `@Model`: the range is strictly 1:1 with a quote, so a separate entity would
    /// force a second fetch into every price path for no gain. Defaults keep the migration
    /// lightweight — existing rows simply read back `nil`.
    var minAmount: Decimal?
    var maxAmount: Decimal?
    var lotCount: Int?

    init(setNum: String, quote: PriceQuote) {
        self.setNum = setNum
        self.source = quote.source.rawValue
        self.amount = quote.amount
        self.currency = quote.currency
        self.sourceURLString = quote.sourceURL?.absoluteString
        self.fetchedAt = quote.fetchedAt
        self.minAmount = quote.minAmount
        self.maxAmount = quote.maxAmount
        self.lotCount = quote.lotCount
    }

    var isExpired: Bool {
        Date().timeIntervalSince(fetchedAt) > 7 * 24 * 60 * 60
    }

    var quote: PriceQuote? {
        guard let priceSource = PriceSource(rawValue: source) else { return nil }
        return PriceQuote(
            source: priceSource,
            amount: amount,
            currency: currency,
            sourceURL: sourceURLString.flatMap(URL.init),
            fetchedAt: fetchedAt,
            minAmount: minAmount,
            maxAmount: maxAmount,
            lotCount: lotCount
        )
    }
}

/// One real, completed BrickLink sale (`price_detail[]` under `guide_type=sold`, #214) — the local
/// equivalent of BrickEconomy's `price_events_*`, plotted as a scatter under the price-history
/// lines on `SetDetailView`.
///
/// Deliberately **not** folded into `PriceHistoryEntry`: that table is our own once-a-day reading of
/// the average, and mixing third-party sales into it would triple its rows and change what the
/// trend line means. Rows here are written as a **wholesale replacement per (setNum, source)**, not
/// appended — BrickLink re-sends the entire 6-month window on every refresh, so replacing needs no
/// deduplication, while appending would multiply the same sale by the number of refreshes.
///
/// Pure cache: everything here can be re-fetched from BrickLink, so unlike `PriceHistoryEntry` this
/// *is* cleared by `LocalRepository.clearAll()`.
@Model
final class SoldListingEntry {
    var setNum: String
    /// A `PriceSource` raw value — the condition the sale was in, since BrickLink prices new and
    /// used separately and the scatter is filtered to the set's own condition.
    var source: String
    var unitAmount: Decimal
    var quantity: Int
    /// When the sale actually happened (BrickLink `date_ordered`) — the scatter's x-axis, and the
    /// reason this feature needed a live shape check before being written: without it there is no
    /// honest place to plot a point.
    var orderedAt: Date
    var currency: String
    /// When *we* retrieved it, distinct from `orderedAt` — lets a future retention pass age out
    /// rows for sets that stopped being refreshed.
    var fetchedAt: Date

    init(setNum: String, source: String, unitAmount: Decimal, quantity: Int, orderedAt: Date, currency: String, fetchedAt: Date = Date()) {
        self.setNum = setNum
        self.source = source
        self.unitAmount = unitAmount
        self.quantity = quantity
        self.orderedAt = orderedAt
        self.currency = currency
        self.fetchedAt = fetchedAt
    }
}

/// An append-only price reading, kept separate from `CachedSetPrice` (which only ever holds the
/// latest value per set+source for the short-lived TTL cache). One entry is recorded per
/// set+source+day, at the same point where a price is already fetched for display — never as a
/// fetch of its own.
///
/// Until #230 that meant "only while the app is open". A **bounded** background pass now also
/// refreshes prices (BrickLink API only, and only for the sets under watch — the wishlist plus the
/// sets carrying a `PriceAlert`), so entries can appear without the app being opened. That
/// deliberately revisits #5's "no background polling" decision, whose stated objection was that
/// polling the *whole collection* doesn't scale; see `BackgroundPriceRefresher` for the restricted
/// scope that answers it.
@Model
final class PriceHistoryEntry {
    var setNum: String
    var source: String
    var amount: Decimal
    var currency: String
    var fetchedAt: Date

    init(setNum: String, source: String, amount: Decimal, currency: String, fetchedAt: Date = Date()) {
        self.setNum = setNum
        self.source = source
        self.amount = amount
        self.currency = currency
        self.fetchedAt = fetchedAt
    }
}

/// "Préviens-moi si ce set descend sous X" (#229) — one threshold the user set by hand on one set,
/// for one condition (neuf **or** occasion, never both: the two are priced by different sources and
/// a single alert covering them would be ambiguous about which one crossed).
///
/// Deliberately **not** a field on `CachedSet`, for the same reason as `SetPurchaseRecord`: two
/// routine paths destroy `CachedSet` rows (`LocalRepository.clearAll()` and `syncCollection`'s
/// cleanup of sets that left the collection), and a threshold typed by hand must survive both. It
/// is keyed by `setNum` and carries its own copy of the name/image so the management screen can
/// render an alert whose set has no cached row at all. Same doctrine, same consequence: `clearAll()`
/// must never delete these.
///
/// This reactivates scope that #5 had explicitly abandoned ("pas d'alertes proactives",
/// `UNUserNotificationCenter` named in its "à ne PAS faire" list). That's a deliberate reversal —
/// see `PriceUpdateNotifier` and `BackgroundPriceRefresher`, whose comments carry the same note.
@Model
final class PriceAlert {
    /// `"{setNum}#{conditionRaw}"` — SwiftData has no composite unique constraint, so the pair that
    /// actually identifies an alert is folded into one attribute. Always built via `Self.key(_:_:)`.
    @Attribute(.unique) var key: String
    var setNum: String
    /// Raw value of `ListCondition` (neuf/occasion), stored as `String` like `CachedSetList` so a
    /// new case needs no migration.
    var conditionRaw: String
    /// The set's identity, copied at creation: an alert outlives its `CachedSet` row (see above),
    /// and a management screen listing bare set numbers would be unusable.
    var setName: String
    var setImgUrl: String?

    /// Exactly one of these two is set. `discountPercent` is resolved against `referencePriceEUR`,
    /// **frozen at creation** — a "−20 %" only means something against a stated reference, and
    /// re-resolving it on every evaluation would let the threshold drift as the market moves (the
    /// same reference question as #227).
    var thresholdEUR: Double?
    var discountPercent: Double?
    /// The reference `discountPercent` applies to: the lego.com retail price when known (stable,
    /// public), otherwise the set's current resolved value for this condition, frozen at creation.
    /// `nil` only for a pure-amount alert.
    var referencePriceEUR: Double?
    /// Human-readable name of where `referencePriceEUR` came from ("lego.com (officiel)",
    /// "BrickLink (occasion)", …), so the UI can say which line the percentage was taken off rather
    /// than implying it was always retail.
    var referenceSourceName: String?

    var isEnabled: Bool = true
    var createdAt: Date

    // MARK: Evaluation state (anti-spam, see `PriceAlertEvaluator`)

    /// Whether the last evaluation found the price at or below the threshold. The notification
    /// fires on the **crossing** (`false` → `true`) only, never on every refresh that finds the
    /// price still low. Starts `false`, so an alert created above the current price fires on its
    /// first evaluation — which is the behaviour #229 asks for.
    var wasBelowThreshold: Bool = false
    /// Last price seen for this alert's condition — shown in the management screen so a threshold
    /// can be judged against something, and the value quoted in the notification body.
    var lastObservedPriceEUR: Double?
    var lastNotifiedAt: Date?

    /// When the background refresher (#230) should next fetch this set — drawn at random over the
    /// coming 7 days (`PriceWatchSchedule`) so watched sets spread out instead of all coming due at
    /// once, and re-drawn after every pass. It lives here, not on `CachedSet`, for two reasons: an
    /// alert must keep being served even when no `CachedSet` row exists for its set, and an alert is
    /// now the *only* thing that puts a set under background surveillance.
    var nextRefreshDue: Date

    init(
        setNum: String,
        condition: ListCondition,
        setName: String,
        setImgUrl: String?,
        thresholdEUR: Double?,
        discountPercent: Double?,
        referencePriceEUR: Double?,
        referenceSourceName: String?,
        createdAt: Date = Date(),
        nextRefreshDue: Date
    ) {
        self.key = Self.key(setNum: setNum, condition: condition)
        self.setNum = setNum
        self.conditionRaw = condition.rawValue
        self.setName = setName
        self.setImgUrl = setImgUrl
        self.thresholdEUR = thresholdEUR
        self.discountPercent = discountPercent
        self.referencePriceEUR = referencePriceEUR
        self.referenceSourceName = referenceSourceName
        self.createdAt = createdAt
        self.nextRefreshDue = nextRefreshDue
    }

    static func key(setNum: String, condition: ListCondition) -> String {
        "\(setNum)#\(condition.rawValue)"
    }

    var condition: ListCondition {
        get { ListCondition(rawValue: conditionRaw) ?? .newSet }
        set { conditionRaw = newValue.rawValue }
    }

    /// The amount the price is actually compared against — the typed amount, or the percentage
    /// applied to the frozen reference. `nil` for a percentage alert whose reference was never
    /// resolvable (no retail price, no quote at all at creation time), which `PriceAlertEvaluator`
    /// treats as "cannot be evaluated" rather than guessing a threshold.
    var effectiveThresholdEUR: Double? {
        if let thresholdEUR { return thresholdEUR }
        guard let discountPercent, let referencePriceEUR else { return nil }
        let raw = referencePriceEUR * (1 - discountPercent / 100)
        return (raw * 100).rounded() / 100
    }
}

@Model
final class CachedSetList {
    @Attribute(.unique) var listId: Int
    var name: String
    var numSets: Int
    var lastFetchedAt: Date
    /// Raw value of `ListCondition`; stored as String so adding new cases needs no migration.
    var conditionRaw: String = ListCondition.newSet.rawValue

    init(from setList: SetList) {
        self.listId = setList.id
        self.name = setList.name
        self.numSets = setList.numSets
        self.lastFetchedAt = Date()
    }

    var condition: ListCondition {
        get { ListCondition(rawValue: conditionRaw) ?? .newSet }
        set { conditionRaw = newValue.rawValue }
    }
}
