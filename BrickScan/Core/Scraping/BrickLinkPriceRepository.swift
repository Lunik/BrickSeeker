import Foundation

/// Fetches BrickLink new/used prices via the official Price Guide API (`GET
/// /items/{type}/{no}/price`, OAuth 1.0a — see `BrickLinkOAuth1`/`BrickLinkClient`), replacing the
/// previous `WKWebView` scrape of the public `catalogPG.asp` page (App Store 5.2.2 compliance,
/// #104/#111). `guide_type=sold` matches what the old scraper read from the page's "Last 6 Months
/// Sales" quadrant (as opposed to `guide_type=stock`, current listings), so the surfaced numbers
/// don't change meaning for existing consumers (`DealVerdict`, `SetRowView`, price history).
///
/// Resolving *which* BrickLink catalog item (type + number) a Rebrickable id maps to: most sets
/// are addressable directly by Rebrickable's own set number under BrickLink's `SET` type — no
/// lookup needed. Minifigs (`fig-…` ids) and the handful of sets BrickLink files under a
/// different type (e.g. individual collectible-minifig boxes) never have a matching `SET` entry;
/// those only resolve from the **existing, permanent** `BrickLinkMinifigIdStore` cache, entries
/// the old scraper wrote by reading the item's Rebrickable page's "External Sites" table.
/// Deliberately **not replicated here**: BrickLink's API has no endpoint that accepts a
/// Rebrickable id, and re-scraping Rebrickable's rendered page to keep populating this cache
/// would just be trading one compliance-violating hidden-`WKWebView` scrape (BrickLink) for
/// another (Rebrickable) — see `app-review-rules.md`'s 5.2.2 entry, which documents this as a
/// deliberate, known gap rather than an oversight: a `fig-…` item never looked up before this
/// change (nothing in `BrickLinkMinifigIdStore`) simply has no BrickLink price, same as any other
/// source with no data for that item, until a compliant mapping source exists.
struct BrickLinkPriceRepository: Sendable {
    private struct PriceGuideData: Decodable {
        let currencyCode: String
        let avgPrice: String

        enum CodingKeys: String, CodingKey {
            case currencyCode = "currency_code"
            case avgPrice = "avg_price"
        }
    }

    /// Maps the single-letter BrickLink catalog type stored in `BrickLinkCatalogRef` (`S`, `M`,
    /// …, from the old scraper's cached mappings) to the full type name the Price Guide API's
    /// `{type}` path segment expects.
    private static let apiTypeByLetter: [String: String] = [
        "S": "SET", "M": "MINIFIG", "P": "PART", "B": "BOOK",
        "G": "GEAR", "C": "CATALOG", "I": "INSTRUCTION",
        "O": "ORIGINAL_BOX", "U": "UNSORTED_LOT"
    ]

    private let client: BrickLinkClient
    private let minifigIdStore: BrickLinkMinifigIdStore

    init(client: BrickLinkClient = .shared, minifigIdStore: BrickLinkMinifigIdStore = .shared) {
        self.client = client
        self.minifigIdStore = minifigIdStore
    }

    func fetchPrices(for legoSet: LegoSet) async throws -> [PriceQuote] {
        // Fails fast without touching the network when credentials aren't set up yet — matches
        // `APIError.missingCredentials`'s purpose.
        guard KeychainService.shared.brickLinkOAuth1Credentials != nil else {
            throw APIError.missingCredentials
        }

        let setNum = legoSet.setNum
        let isMinifig = setNum.hasPrefix("fig-")

        if !isMinifig, let quotes = try? await fetchPrices(ref: BrickLinkCatalogRef(type: "S", id: setNum)), !quotes.isEmpty {
            return quotes
        }

        guard let ref = await minifigIdStore.lookup(setNum: setNum) else {
            throw ScrapeError.notFound
        }
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
}
