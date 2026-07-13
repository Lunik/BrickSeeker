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

    init(setNum: String, quote: PriceQuote) {
        self.setNum = setNum
        self.source = quote.source.rawValue
        self.amount = quote.amount
        self.currency = quote.currency
        self.sourceURLString = quote.sourceURL?.absoluteString
        self.fetchedAt = quote.fetchedAt
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
            fetchedAt: fetchedAt
        )
    }
}

/// An append-only price reading, kept separate from `CachedSetPrice` (which only ever holds the
/// latest value per set+source for the short-lived TTL cache). One entry is recorded per
/// set+source+day, at the same point where a price is already fetched for display — no extra
/// network calls, no background polling (see GitHub issue #5).
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
