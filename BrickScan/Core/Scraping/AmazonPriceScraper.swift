import Foundation

/// Scrapes an Amazon search results page for a LEGO set's price.
///
/// Amazon has no per-product URL keyed by LEGO set number, so this searches
/// `LEGO {setNum}` and reads the price off the first result card that looks
/// like the genuine set: the title is brand-first ("LEGO …"), carries the set
/// number, and isn't a third-party accessory (lighting kits and the like that
/// merely say "compatible avec 10294" / "pour LEGO" are rejected). This is the
/// least reliable price source in the app (Amazon's anti-bot detection is the
/// most aggressive of the two): any failure here — CAPTCHA, no matching card,
/// layout change — is caught by the caller and simply omits the Amazon quote,
/// it never blocks BrickLink's result.
struct AmazonPriceScraper: Sendable {
    private struct RawResult: Decodable {
        let price: String
        let url: String?
    }

    // Neither HeadlessWebScraper.shared nor AppMarketplace.shared are defaulted here:
    // both are main-actor-isolated static properties, and a default argument value must
    // be evaluable in this (nonisolated) init's context. Both are resolved lazily in
    // `fetchPrice` instead, where `await` can hop onto the main actor.
    private let scraper: HeadlessWebScraper?
    private let marketplaceOverride: Marketplace?

    init(scraper: HeadlessWebScraper? = nil, marketplace: Marketplace? = nil) {
        self.scraper = scraper
        self.marketplaceOverride = marketplace
    }

    func fetchPrice(legoSet: LegoSet) async throws -> PriceQuote {
        let setDigits = legoSet.setNum.split(separator: "-").first.map(String.init) ?? legoSet.setNum
        let market: Marketplace
        if let override = marketplaceOverride {
            market = override
        } else {
            market = await MainActor.run { AppMarketplace.shared.marketplace }
        }

        var components = URLComponents(string: "https://www.\(market.amazonDomain)/s")!
        components.queryItems = [URLQueryItem(name: "k", value: "LEGO \(setDigits)")]
        guard let url = components.url else { throw ScrapeError.notFound }

        let scraper: HeadlessWebScraper
        if let injected = self.scraper {
            scraper = injected
        } else {
            scraper = await HeadlessWebScraper.shared
        }
        let json = try await scraper.loadAndExtract(
            url: url,
            readinessScript: Self.readinessScript,
            extractScript: Self.extractScript(setDigits: setDigits, rejectPattern: market.amazonRejectPattern)
        )
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawResult.self, from: data),
              let amount = PriceParsing.amount(from: raw.price) else {
            throw ScrapeError.parsingFailed
        }

        return PriceQuote(
            source: .amazon,
            amount: amount,
            currency: PriceParsing.currency(from: raw.price),
            sourceURL: raw.url.flatMap(URL.init),
            fetchedAt: Date()
        )
    }

    static let readinessScript = """
    (function() {
        var text = document.body ? document.body.innerText : '';
        if (/Enter the characters|Saisissez les caract\\u00e8res/i.test(text)) return true;
        return document.querySelectorAll('[data-component-type="s-search-result"]').length > 0;
    })()
    """

    static func extractScript(setDigits: String, rejectPattern: String) -> String {
        """
        (function() {
            var text = document.body ? document.body.innerText : '';
            if (/Enter the characters|Saisissez les caract\\u00e8res/i.test(text)) return null;
            var cards = Array.from(document.querySelectorAll('[data-component-type="s-search-result"]'));
            // Third-party accessories that merely reference a set number — most
            // often LED lighting kits "compatible avec"/"pour LEGO", which never
            // include the set itself.
            var reject = new RegExp(\(#""\#(rejectPattern)""#), 'i');
            function priceFrom(card) {
                var titleEl = card.querySelector('h2');
                var title = (titleEl ? titleEl.textContent : '').trim();
                // Genuine listings are brand-first and carry the set number;
                // accessories are neither.
                if (!/^lego\\b/i.test(title)) return null;
                if (title.indexOf('\(setDigits)') === -1) return null;
                if (reject.test(title)) return null;
                var priceEl = card.querySelector('.a-price .a-offscreen');
                if (!priceEl) return null;
                var linkEl = card.querySelector('h2 a') || card.querySelector('a.a-link-normal');
                return JSON.stringify({
                    price: priceEl.textContent.trim(),
                    url: linkEl ? linkEl.href : null
                });
            }
            for (var i = 0; i < cards.length; i++) {
                var match = priceFrom(cards[i]);
                if (match) return match;
            }
            return null;
        })()
        """
    }
}
