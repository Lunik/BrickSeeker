import Foundation

/// Scrapes a Cdiscount search results page for a LEGO set's price (issue #124), same shape as
/// `AmazonPriceScraper`: no per-product URL keyed by LEGO set number, so this searches
/// `LEGO {setNum}` and reads the price off the first result card that looks like the genuine set.
///
/// Cdiscount sits behind its own JS bot challenge ("Baleen", confirmed via a plain `curl` — the
/// server returns a no-op challenge page, not the real search results) — same class of problem as
/// Amazon/lego.com, handled the same way via `HeadlessWebScraper`'s hidden `WKWebView`. Unlike
/// Amazon, Cdiscount doesn't expose a stable `data-component-type`-style test hook for result
/// cards, so this keys off the one stable thing Cdiscount product pages are known to share: a
/// `/f-<categoryId>-<sku>.html` URL segment — confirmed against real search results (on-device,
/// via `simulator-ui-testing`) to be a single `<a>` wrapping the whole card (title, rating, price).
///
/// That on-device check also caught two bugs a static read of the markup wouldn't have: the
/// card's `.innerText` reads as empty (a WebKit quirk on this list's off-screen/virtualized rows —
/// `.textContent` doesn't have the problem, so this reads that instead), and a promo card's text
/// contains **two** prices back to back — the crossed-out original, then the "-N%" badge, then the
/// actual current price (e.g. `"239,99 €-8%219,99 €"`) — so this takes the *last* price match in
/// the card, not the first, or it silently returns the pre-discount price.
///
/// Reading the whole card's `.textContent` (title + reference + price, no dedicated price element
/// to hook like Amazon's `.a-price .a-offscreen`) has a third failure mode (#207): when the set
/// reference sits directly against the price digits with no separator in the flattened text (e.g.
/// `"...30368" + "5,99 €..."`), a loose price regex reads straight through the boundary and
/// matches `"303685,99 €"` as one number — confirmed live (set 30368's card text is literally
/// `"...- 303685,99 €Ajouter"`, no separator at all). The regex itself can't be tightened to
/// reject this shape: Cdiscount doesn't consistently thousands-separate its own prices (also
/// confirmed live — a promo card for set 10307 renders `"1174,00 €"`, four digits, no separator),
/// which is the exact same shape as a glued-on reference. So the fix isolates instead of
/// pattern-matching harder: the reference substring is stripped from the card text before the
/// price regex runs, and a decoded amount implausible for a retail LEGO set is rejected as a
/// backstop rather than returned.
struct CdiscountPriceScraper: Sendable {
    private struct RawResult: Decodable {
        let price: String
        let url: String?
    }

    // No standard retail LEGO set is priced anywhere near this. A decoded amount above it means
    // the extractor read something other than a genuine price (#207 — the classic case is the set
    // number itself bleeding into the digits) — better to surface the source as unavailable than a
    // fabricated price.
    private static let plausibleMaxAmount: Decimal = 5000

    // Not defaulted to `.shared` here for the same reason as `AmazonPriceScraper`: that's a
    // main-actor-isolated static property, and a default argument value must be evaluable in this
    // (nonisolated) init's context. Resolved lazily in `fetchPrice` instead.
    private let scraper: HeadlessWebScraper?

    init(scraper: HeadlessWebScraper? = nil) {
        self.scraper = scraper
    }

    func fetchPrice(legoSet: LegoSet) async throws -> PriceQuote {
        let setDigits = legoSet.setNum.split(separator: "-").first.map(String.init) ?? legoSet.setNum

        let query = "LEGO \(setDigits)"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
                .replacingOccurrences(of: " ", with: "+"),
              let url = URL(string: "https://www.cdiscount.com/search/10/\(encodedQuery).html") else {
            throw ScrapeError.notFound
        }

        let scraper: HeadlessWebScraper
        if let injected = self.scraper {
            scraper = injected
        } else {
            scraper = await HeadlessWebScraper.shared
        }
        let json = try await scraper.loadAndExtract(
            url: url,
            readinessScript: Self.readinessScript,
            extractScript: Self.extractScript(setDigits: setDigits)
        )
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawResult.self, from: data),
              let amount = PriceParsing.amount(from: raw.price),
              amount <= Self.plausibleMaxAmount else {
            throw ScrapeError.parsingFailed
        }

        return PriceQuote(
            source: .cdiscount,
            amount: amount,
            currency: PriceParsing.currency(from: raw.price),
            sourceURL: raw.url.flatMap(URL.init),
            fetchedAt: Date()
        )
    }

    static let readinessScript = """
    (function() {
        var text = document.body ? document.body.innerText : '';
        if (/aucun r\\u00e9sultat/i.test(text)) return true;
        return document.querySelectorAll('a[href*="/f-"]').length > 0;
    })()
    """

    static func extractScript(setDigits: String) -> String {
        """
        (function() {
            var text = document.body ? document.body.innerText : '';
            if (/aucun r\\u00e9sultat/i.test(text)) return null;
            var links = Array.from(document.querySelectorAll('a[href*="/f-"]'));
            // Same accessory/third-party rejection list as Amazon, plus occasion/reconditionné —
            // Cdiscount's marketplace mixes used goods into "neuf" search results more than Amazon does.
            var reject = /compatible|pour lego|for lego|\\u00e9clairage|eclairage|\\bled\\b|lighting|non inclus|not included|pas inclus|sans la|briksmax|vonado|lightailing|occasion|reconditionn/i;
            var priceRegex = /\\d[\\d\\s]*,\\d{2}\\s*\\u20ac/g;
            for (var i = 0; i < links.length; i++) {
                var link = links[i];
                // `.textContent` (not `.innerText`, which reads empty on this list's off-screen/
                // virtualized rows) — the card's whole title/rating/price text lives inside the
                // `<a>` itself, no need to walk up to a parent.
                var cardText = (link.textContent || '').trim();
                if (cardText.toLowerCase().indexOf('lego') === -1) continue;
                if (cardText.indexOf('\(setDigits)') === -1) continue;
                if (reject.test(cardText)) continue;
                // Strip the set reference before matching (#207) — title/reference/price all live
                // in one flattened `.textContent` string with no reliable delimiter between them,
                // so the reference digits can sit directly against the price digits.
                var priceText = cardText.split('\(setDigits)').join(' ');
                var matches = priceText.match(priceRegex);
                if (!matches || !matches.length) continue;
                // A promo card lists the crossed-out original price first, then the "-N%" badge,
                // then the actual current price — the last match is always the one to buy at.
                return JSON.stringify({ price: matches[matches.length - 1], url: link.href });
            }
            return null;
        })()
        """
    }
}
