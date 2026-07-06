import Foundation

/// Fetches BrickLink new/used prices via the official Price Guide API (`GET
/// /items/{type}/{no}/price`, OAuth 1.0a — see `BrickLinkOAuth1`/`BrickLinkClient`), replacing the
/// previous `WKWebView` scrape of the public `catalogPG.asp` page (App Store 5.2.2 compliance,
/// #104/#111). `guide_type=sold` matches what the old scraper read from the page's "Last 6 Months
/// Sales" quadrant (as opposed to `guide_type=stock`, current listings), so the surfaced numbers
/// don't change meaning for existing consumers (`DealVerdict`, `SetRowView`, price history).
///
/// Resolving *which* BrickLink catalog item (type + number) a Rebrickable id maps to: most sets are
/// addressable directly by Rebrickable's own set number under BrickLink's `SET` type. Minifigs
/// (`fig-…` ids) and the handful of sets BrickLink files under a different type never have a
/// matching `SET` entry, so those fall back to `resolveViaCatalogCrossReference`, which cross-refs
/// two official APIs — Rebrickable's part `external_ids.BrickLink` and BrickLink's catalog
/// supersets/subsets — to pin the item, then caches it permanently in `BrickLinkMinifigIdStore`.
/// This replaces the previous "read the item's Rebrickable page 'External Sites' table via
/// `HeadlessWebScraper`" scrape (App Store 5.2.2 / 2.3.1(a), #117): neither BrickLink's API (no
/// endpoint accepts a Rebrickable id, no free-text search) nor Rebrickable's API expose the
/// minifig→BrickLink mapping directly — only the physical part composition, cross-referenced, does.
///
/// The cross-reference favours **precision over recall** (validated empirically on a real
/// collection, #117: ~100% precision, ~53% recall): it only accepts a *unique* candidate backed by
/// discriminant (printed) parts and confirmed by composition, and otherwise abstains (no quote)
/// rather than risk a wrong price. Unresolved items are the natural home for a future visible
/// link-out + manual-entry fallback.
struct BrickLinkPriceRepository: Sendable {
    private struct PriceGuideData: Decodable {
        let currencyCode: String
        let avgPrice: String

        enum CodingKeys: String, CodingKey {
            case currencyCode = "currency_code"
            case avgPrice = "avg_price"
        }
    }

    /// Maps the single-letter BrickLink catalog type used in its URLs/`BrickLinkCatalogRef`
    /// (`S`, `M`, …) to the full type name the API's `{type}` path segment expects.
    private static let apiTypeByLetter: [String: String] = [
        "S": "SET", "M": "MINIFIG", "P": "PART", "B": "BOOK",
        "G": "GEAR", "C": "CATALOG", "I": "INSTRUCTION",
        "O": "ORIGINAL_BOX", "U": "UNSORTED_LOT"
    ]

    /// Inverse of `apiTypeByLetter`: the full type name BrickLink returns in item payloads
    /// (`item.type == "MINIFIG"`) back to the single letter `BrickLinkCatalogRef` stores.
    private static let letterByApiType: [String: String] = [
        "SET": "S", "MINIFIG": "M", "PART": "P", "BOOK": "B",
        "GEAR": "G", "CATALOG": "C", "INSTRUCTION": "I",
        "ORIGINAL_BOX": "O", "UNSORTED_LOT": "U"
    ]

    /// Cap on how many discriminant parts we intersect supersets for — a minifig rarely has more
    /// than a few printed parts, and this bounds BrickLink calls for an edge-case set with many.
    private static let maxDiscriminantParts = 8
    /// Minimum fraction of the item's BrickLink parts that must appear in the candidate's own
    /// inventory for the composition check to accept it (see `resolveViaCatalogCrossReference`).
    private static let verifyThreshold = 0.5

    private let client: BrickLinkClient
    private let networkClient: NetworkClient
    private let minifigIdStore: BrickLinkMinifigIdStore

    init(
        client: BrickLinkClient = .shared,
        networkClient: NetworkClient = .shared,
        minifigIdStore: BrickLinkMinifigIdStore = .shared
    ) {
        self.client = client
        self.networkClient = networkClient
        self.minifigIdStore = minifigIdStore
    }

    func fetchPrices(for legoSet: LegoSet) async throws -> [PriceQuote] {
        // Fails fast without touching the network (or the resolution fallback below) when
        // credentials aren't set up yet — matches `APIError.missingCredentials`'s purpose.
        guard KeychainService.shared.brickLinkOAuth1Credentials != nil else {
            throw APIError.missingCredentials
        }

        let setNum = legoSet.setNum
        let isMinifig = setNum.hasPrefix("fig-")

        if !isMinifig, let quotes = try? await fetchPrices(ref: BrickLinkCatalogRef(type: "S", id: setNum)), !quotes.isEmpty {
            return quotes
        }

        let ref = try await resolveMappedRef(setNum: setNum, isMinifig: isMinifig)
        return try await fetchPrices(ref: ref)
    }

    private func fetchPrices(ref: BrickLinkCatalogRef) async throws -> [PriceQuote] {
        guard let apiType = Self.apiTypeByLetter[ref.type] else { throw ScrapeError.notFound }
        let itemURL = URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?\(ref.type)=\(ref.id)")

        async let newQuote = try? fetchQuote(apiType: apiType, id: ref.id, newOrUsed: "N", source: .bricklinkNew, itemURL: itemURL)
        async let usedQuote = try? fetchQuote(apiType: apiType, id: ref.id, newOrUsed: "U", source: .bricklinkUsed, itemURL: itemURL)

        let quotes = [await newQuote, await usedQuote].compactMap { $0 }
        guard !quotes.isEmpty else { throw ScrapeError.notFound }
        return quotes
    }

    private func fetchQuote(
        apiType: String,
        id: String,
        newOrUsed: String,
        source: PriceSource,
        itemURL: URL?
    ) async throws -> PriceQuote {
        let data: PriceGuideData = try await client.get(
            path: "/items/\(apiType)/\(id)/price",
            queryItems: [
                URLQueryItem(name: "guide_type", value: "sold"),
                URLQueryItem(name: "new_or_used", value: newOrUsed),
                // No region setting exists yet (#40) — EUR matches this app's other price
                // sources (lego.com, amazon.fr), which already assume the French/EUR market.
                URLQueryItem(name: "currency_code", value: "EUR")
            ]
        )
        guard let amount = Decimal(string: data.avgPrice), amount > 0 else {
            throw ScrapeError.notFound
        }
        return PriceQuote(source: source, amount: amount, currency: data.currencyCode, sourceURL: itemURL, fetchedAt: Date())
    }

    /// Reads the on-disk cache, or (first lookup only) resolves and saves it by cross-referencing
    /// the official Rebrickable/BrickLink catalog APIs — see the type's doc comment. Only successes
    /// are cached; an unresolved item throws (yielding no quote) and is retried on the next refresh.
    private func resolveMappedRef(setNum: String, isMinifig: Bool) async throws -> BrickLinkCatalogRef {
        if let cached = await minifigIdStore.lookup(setNum: setNum) {
            return cached
        }
        // Skip re-running the multi-call, throttled cross-reference for an item that recently
        // failed — ~half of minifigs legitimately don't resolve, and without this a collection-wide
        // refresh would re-attempt every one of them each time. TTL'd (see the store), so it retries
        // eventually.
        if await minifigIdStore.hasRecentMiss(setNum: setNum) {
            throw ScrapeError.notFound
        }
        do {
            let ref = try await resolveViaCatalogCrossReference(setNum: setNum, isMinifig: isMinifig)
            await minifigIdStore.save(setNum: setNum, ref: ref)
            return ref
        } catch ScrapeError.notFound {
            // Genuine "can't resolve" (no parts / no discriminant / ambiguous / verify failed) —
            // remember it so we don't retry until the TTL. Transient errors (network, throttle,
            // decode) are a different error type and fall through to propagate *without* being
            // cached as a miss, so they retry on the next refresh.
            await minifigIdStore.recordMiss(setNum: setNum)
            throw ScrapeError.notFound
        }
    }

    /// Pins the BrickLink catalog item for a Rebrickable minifig/edge-case set using only official
    /// APIs (no HTML scraping, #117):
    ///  1. Rebrickable — the item's parts, each carrying its BrickLink part id (`external_ids`).
    ///  2. BrickLink — intersect the *supersets* (containing items) of the **printed/discriminant**
    ///     parts only; generic torso/legs are shared across thousands of figs and produce false
    ///     positives. Accept only a single surviving candidate (abstain on ties — precision first).
    ///  3. BrickLink — verify by composition: the candidate's own inventory (subsets) must cover
    ///     the item's parts, else reject. This catches the residual variant/false-positive cases.
    private func resolveViaCatalogCrossReference(setNum: String, isMinifig: Bool) async throws -> BrickLinkCatalogRef {
        let parts = try await rebrickableBrickLinkParts(setNum: setNum, isMinifig: isMinifig)
        guard !parts.isEmpty else { throw ScrapeError.notFound }

        var discriminant: [String] = []
        var seen = Set<String>()
        for part in parts where part.isPrinted && seen.insert(part.blPartId).inserted {
            discriminant.append(part.blPartId)
        }
        guard !discriminant.isEmpty else { throw ScrapeError.notFound }

        // A Rebrickable *set* number can resolve to a BrickLink minifig (CMF singles) or a set;
        // a Rebrickable minifig always resolves to a BrickLink minifig.
        let acceptedTypes: Set<String> = isMinifig ? ["MINIFIG"] : ["MINIFIG", "SET"]

        var intersection: Set<BrickLinkCatalogRef>?
        for partId in discriminant.prefix(Self.maxDiscriminantParts) {
            // A part BrickLink's catalog doesn't recognise (stale Rebrickable mapping) shouldn't
            // abandon the whole figure — skip it and keep narrowing with the others. Other errors
            // (decode/transport) still propagate so real problems surface.
            let supersets: Set<BrickLinkCatalogRef>
            do {
                supersets = try await self.supersets(ofPart: partId, acceptedTypes: acceptedTypes)
            } catch APIError.notFound {
                continue
            }
            guard !supersets.isEmpty else { continue }
            intersection = intersection.map { $0.intersection(supersets) } ?? supersets
            if intersection?.isEmpty == true { break }
        }
        guard let survivors = intersection, survivors.count == 1, let candidate = survivors.first else {
            throw ScrapeError.notFound
        }

        let candidateParts: Set<String>
        do {
            candidateParts = try await subsetPartNumbers(of: candidate)
        } catch APIError.notFound {
            candidateParts = []
        }
        let itemParts = Set(parts.map { $0.blPartId })
        let overlap = Double(itemParts.intersection(candidateParts).count) / Double(itemParts.count)
        guard overlap >= Self.verifyThreshold else { throw ScrapeError.notFound }
        return candidate
    }

    // MARK: - Catalog cross-reference primitives

    /// One page (up to 100) of the item's inventory parts from Rebrickable, flattened to
    /// `(BrickLink part id, isPrinted)`. One page is enough: minifigs have a handful of parts, and
    /// the printed ones we need are among the first for edge-case sets too.
    private func rebrickableBrickLinkParts(setNum: String, isMinifig: Bool) async throws -> [(blPartId: String, isPrinted: Bool)] {
        let category = isMinifig ? "minifigs" : "sets"
        let page: RebrickableInventoryPartsResponse = try await networkClient.get(
            path: "/lego/\(category)/\(setNum)/parts/",
            queryItems: [
                URLQueryItem(name: "inc_part_details", value: "1"),
                URLQueryItem(name: "page_size", value: "100")
            ]
        )
        var result: [(String, Bool)] = []
        for entry in page.results {
            guard let blIds = entry.part.externalIds?.brickLink else { continue }
            for blId in blIds {
                result.append((blId, Self.isPrinted(blId: blId, name: entry.part.name)))
            }
        }
        return result
    }

    /// BrickLink catalog items (of `acceptedTypes`) that contain the given part.
    private func supersets(ofPart blPartId: String, acceptedTypes: Set<String>) async throws -> Set<BrickLinkCatalogRef> {
        let encoded = blPartId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? blPartId
        let groups: [BrickLinkCatalogGroup] = try await client.get(path: "/items/PART/\(encoded)/supersets", queryItems: [])
        var refs = Set<BrickLinkCatalogRef>()
        for group in groups {
            for entry in group.entries where acceptedTypes.contains(entry.item.type) {
                guard let letter = Self.letterByApiType[entry.item.type] else { continue }
                refs.insert(BrickLinkCatalogRef(type: letter, id: entry.item.no))
            }
        }
        return refs
    }

    /// The BrickLink part numbers that make up a catalog item (its inventory), for the
    /// composition-verification step.
    private func subsetPartNumbers(of ref: BrickLinkCatalogRef) async throws -> Set<String> {
        guard let apiType = Self.apiTypeByLetter[ref.type] else { return [] }
        let encoded = ref.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref.id
        let groups: [BrickLinkCatalogGroup] = try await client.get(path: "/items/\(apiType)/\(encoded)/subsets", queryItems: [])
        var ids = Set<String>()
        for group in groups {
            for entry in group.entries where entry.item.type == "PART" {
                ids.insert(entry.item.no)
            }
        }
        return ids
    }

    /// Whether a part is printed/decorated — the only kind specific enough to pin a single minifig.
    /// Matches a printed BrickLink id suffix (`…pb…`, `…pr…`, e.g. `973pb3509c01`, `3626px298`) or
    /// a "Print"/"Pattern"/"Decorated" mention in the Rebrickable part name.
    private static func isPrinted(blId: String, name: String) -> Bool {
        if blId.range(of: "p[brx][0-9]", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        let lower = name.lowercased()
        return lower.contains("print") || lower.contains("pattern") || lower.contains("decorat")
    }
}

// MARK: - Wire models

/// Rebrickable inventory-parts response (`/lego/{minifigs|sets}/{num}/parts/?inc_part_details=1`).
/// In this inventory context `external_ids.BrickLink` is a flat array of part-number strings
/// (distinct from the `/lego/parts/{num}/` shape which nests `ext_ids`/`ext_descrs`).
private struct RebrickableInventoryPartsResponse: Decodable {
    let results: [Entry]

    struct Entry: Decodable {
        let part: Part
    }

    struct Part: Decodable {
        let name: String
        let externalIds: ExternalIds?

        enum CodingKeys: String, CodingKey {
            case name
            case externalIds = "external_ids"
        }
    }

    struct ExternalIds: Decodable {
        let brickLink: [String]?

        enum CodingKeys: String, CodingKey {
            case brickLink = "BrickLink"
        }
    }
}

/// A BrickLink supersets/subsets group. Both endpoints return `data` as an array of colour/match
/// groups, each wrapping `entries` whose `item` carries the catalog `no` + full `type`.
private struct BrickLinkCatalogGroup: Decodable {
    let entries: [Entry]

    struct Entry: Decodable {
        let item: Item
    }

    struct Item: Decodable {
        let no: String
        let type: String
    }
}
