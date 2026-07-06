import Foundation

/// Fetches BrickLink new/used prices via the official Price Guide API (`GET
/// /items/{type}/{no}/price`, OAuth 1.0a — see `BrickLinkOAuth1`/`BrickLinkClient`), replacing the
/// previous `WKWebView` scrape of the public `catalogPG.asp` page (App Store 5.2.2 compliance,
/// #104/#111). `guide_type=sold` matches what the old scraper read from the page's "Last 6 Months
/// Sales" quadrant (as opposed to `guide_type=stock`, current listings), so the surfaced numbers
/// don't change meaning for existing consumers (`DealVerdict`, `SetRowView`, price history).
///
/// Resolving *which* BrickLink catalog item (type + number) a Rebrickable id maps to is
/// unchanged from before: most sets are addressable directly by Rebrickable's own set number
/// under BrickLink's `SET` type. Minifigs (`fig-…` ids) and the handful of sets BrickLink files
/// under a different type never have a matching `SET` entry, so those fall back to the permanent
/// `BrickLinkMinifigIdStore` cache, resolved (once per item, ever) by reading the item's
/// Rebrickable page's "External Sites" table — BrickLink's API has no endpoint that accepts a
/// Rebrickable id, and Rebrickable's own API doesn't expose this mapping either, only the
/// rendered page does. This one remaining scrape is out of scope for #111 (which targets the
/// BrickLink price-guide scrape specifically) — tracked separately in #117.
struct BrickLinkPriceRepository: Sendable {
    private struct PriceGuideData: Decodable {
        let currencyCode: String
        let avgPrice: String

        enum CodingKeys: String, CodingKey {
            case currencyCode = "currency_code"
            case avgPrice = "avg_price"
        }
    }

    private struct RawExternalId: Decodable {
        let id: String
        let href: String?
    }

    /// Maps the single-letter BrickLink catalog type used in its URLs/`BrickLinkCatalogRef`
    /// (`S`, `M`, …) to the full type name the Price Guide API's `{type}` path segment expects.
    private static let apiTypeByLetter: [String: String] = [
        "S": "SET", "M": "MINIFIG", "P": "PART", "B": "BOOK",
        "G": "GEAR", "C": "CATALOG", "I": "INSTRUCTION",
        "O": "ORIGINAL_BOX", "U": "UNSORTED_LOT"
    ]

    static let externalIdReadinessScript = """
    (function() {
        var text = document.body ? document.body.innerText : '';
        return text.indexOf('External Sites') !== -1;
    })()
    """

    static let externalIdExtractScript = """
    (function() {
        var rows = Array.from(document.querySelectorAll('tr'));
        for (var i = 0; i < rows.length; i++) {
            var cells = rows[i].querySelectorAll('td');
            if (cells.length < 2) continue;
            if (cells[0].textContent.trim() !== 'BrickLink') continue;
            var link = cells[1].querySelector('a');
            var href = link ? link.getAttribute('href') : null;
            var id = (link ? link.textContent : cells[1].textContent).trim();
            if (id) return JSON.stringify({ id: id, href: href });
        }
        return null;
    })()
    """

    // Not defaulted to `.shared` here: that's a main-actor-isolated static property, and a default
    // argument value must be evaluable in this (nonisolated) init's context. Resolved lazily in
    // `resolveMappedRef`, where `await` can hop onto the main actor.
    private let client: BrickLinkClient
    private let scraper: HeadlessWebScraper?
    private let minifigIdStore: BrickLinkMinifigIdStore

    init(
        client: BrickLinkClient = .shared,
        scraper: HeadlessWebScraper? = nil,
        minifigIdStore: BrickLinkMinifigIdStore = .shared
    ) {
        self.client = client
        self.scraper = scraper
        self.minifigIdStore = minifigIdStore
    }

    func fetchPrices(for legoSet: LegoSet) async throws -> [PriceQuote] {
        // Fails fast without touching the network (or the Rebrickable-page fallback below) when
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

    /// Reads the on-disk cache, or (first lookup only) resolves and saves it by scraping the
    /// item's Rebrickable page's "External Sites" table — see the type's doc comment.
    private func resolveMappedRef(setNum: String, isMinifig: Bool) async throws -> BrickLinkCatalogRef {
        if let cached = await minifigIdStore.lookup(setNum: setNum) {
            return cached
        }

        let scraper: HeadlessWebScraper
        if let injected = self.scraper {
            scraper = injected
        } else {
            scraper = await HeadlessWebScraper.shared
        }

        let rebrickablePath = isMinifig ? "minifigs" : "sets"
        guard let rebrickableURL = URL(string: "https://rebrickable.com/\(rebrickablePath)/\(setNum)/") else {
            throw ScrapeError.notFound
        }
        let externalIdJson = try await scraper.loadAndExtract(
            url: rebrickableURL,
            readinessScript: Self.externalIdReadinessScript,
            extractScript: Self.externalIdExtractScript
        )
        guard let externalIdData = externalIdJson.data(using: .utf8),
              let externalId = try? JSONDecoder().decode(RawExternalId.self, from: externalIdData) else {
            throw ScrapeError.parsingFailed
        }
        let ref = Self.catalogRef(id: externalId.id, href: externalId.href, fallbackType: isMinifig ? "M" : "S")
        await minifigIdStore.save(setNum: setNum, ref: ref)
        return ref
    }

    /// Reads the BrickLink catalog type (`S`, `M`, …) from an "External Sites" link's `href`
    /// query string — that's the ground truth for which catalog the item was actually filed
    /// under, since it isn't always the same type the lookup started with (e.g. a Rebrickable
    /// *set* number can resolve to a BrickLink *minifig* entry). Falls back to `fallbackType`
    /// only if the href is missing or unparseable.
    private static func catalogRef(id: String, href: String?, fallbackType: String) -> BrickLinkCatalogRef {
        if let href, let components = URLComponents(string: href),
           let first = components.queryItems?.first, let value = first.value {
            return BrickLinkCatalogRef(type: first.name, id: value)
        }
        return BrickLinkCatalogRef(type: fallbackType, id: id)
    }
}
