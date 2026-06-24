import Foundation

/// Scrapes an Amazon.fr search results page for a LEGO set's price.
///
/// Amazon has no per-product URL keyed by LEGO set number, so this searches
/// `LEGO {setNum}` and reads the price off the first result card whose title
/// contains both "LEGO" and the set number. This is the least reliable price
/// source in the app (Amazon's anti-bot detection is the most aggressive of
/// the two): any failure here — CAPTCHA, no matching card, layout change —
/// is caught by the caller and simply omits the Amazon quote, it never
/// blocks BrickLink's result.
struct AmazonPriceScraper: Sendable {
    private struct RawResult: Decodable {
        let price: String
        let url: String?
    }

    // Not defaulted to `.shared` here: that's a main-actor-isolated static
    // property, and a default argument value must be evaluable in this
    // (nonisolated) init's context. Resolved lazily in `fetchPrice` instead,
    // where `await` can hop onto the main actor.
    private let scraper: HeadlessWebScraper?

    init(scraper: HeadlessWebScraper? = nil) {
        self.scraper = scraper
    }

    func fetchPrice(legoSet: LegoSet) async throws -> PriceQuote {
        let setDigits = legoSet.setNum.split(separator: "-").first.map(String.init) ?? legoSet.setNum

        var components = URLComponents(string: "https://www.amazon.fr/s")!
        components.queryItems = [URLQueryItem(name: "k", value: "LEGO \(setDigits)")]
        guard let url = components.url else { throw ScrapeError.notFound }

        let scraper = await self.scraper ?? HeadlessWebScraper.shared
        let json = try await scraper.loadAndExtract(
            url: url,
            readinessScript: Self.readinessScript,
            extractScript: Self.extractScript(setDigits: setDigits)
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

    static func extractScript(setDigits: String) -> String {
        """
        (function() {
            var text = document.body ? document.body.innerText : '';
            if (/Enter the characters|Saisissez les caract\\u00e8res/i.test(text)) return null;
            var cards = Array.from(document.querySelectorAll('[data-component-type="s-search-result"]'));
            function priceFrom(card) {
                var titleEl = card.querySelector('h2');
                var title = titleEl ? titleEl.textContent : '';
                if (!/lego/i.test(title)) return null;
                var priceEl = card.querySelector('.a-price .a-offscreen');
                if (!priceEl) return null;
                var linkEl = card.querySelector('h2 a') || card.querySelector('a.a-link-normal');
                return JSON.stringify({
                    price: priceEl.textContent.trim(),
                    url: linkEl ? linkEl.href : null
                });
            }
            for (var i = 0; i < cards.length; i++) {
                var title = (cards[i].querySelector('h2') || {}).textContent || '';
                if (title.indexOf('\(setDigits)') === -1) continue;
                var match = priceFrom(cards[i]);
                if (match) return match;
            }
            for (var j = 0; j < cards.length; j++) {
                var match = priceFrom(cards[j]);
                if (match) return match;
            }
            return null;
        })()
        """
    }
}
