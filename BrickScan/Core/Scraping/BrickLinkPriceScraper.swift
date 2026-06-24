import Foundation

/// Scrapes the BrickLink "Price Guide" page for a set, which is addressable
/// directly by set number — no search step needed.
///
/// The JS below walks the DOM by *visible text* ("Used" / "New" block
/// headers, "Avg Price" row labels) instead of CSS class names, since
/// BrickLink's markup isn't documented and class names are the first thing
/// to break on a redesign. If BrickLink changes their wording, this needs
/// updating — see `BrickLinkPriceScraperTests` for the expected shape.
struct BrickLinkPriceScraper: Sendable {
    private struct RawPrices: Decodable {
        let used: String?
        let new: String?
    }

    static let readinessScript = """
    (function() {
        var text = document.body ? document.body.innerText.toLowerCase() : '';
        return text.indexOf('avg price') !== -1 || text.indexOf('no price data') !== -1;
    })()
    """

    static let extractScript = """
    (function() {
        function textOf(el) { return (el.textContent || '').replace(/\\s+/g, ' ').trim(); }
        var rows = Array.from(document.querySelectorAll('tr'));
        function blockStart(label) {
            return rows.findIndex(function(r) { return new RegExp('^' + label + '$', 'i').test(textOf(r)); });
        }
        function avgPriceAfter(startIndex) {
            if (startIndex < 0) return null;
            for (var i = startIndex; i < rows.length && i < startIndex + 12; i++) {
                var cells = Array.from(rows[i].querySelectorAll('td,th'));
                for (var c = 0; c < cells.length; c++) {
                    if (/avg price/i.test(textOf(cells[c])) && cells[c + 1]) {
                        return textOf(cells[c + 1]);
                    }
                }
            }
            return null;
        }
        return JSON.stringify({
            used: avgPriceAfter(blockStart('used')),
            new: avgPriceAfter(blockStart('new'))
        });
    })()
    """

    // Not defaulted to `.shared` here: that's a main-actor-isolated static
    // property, and a default argument value must be evaluable in this
    // (nonisolated) init's context. Resolved lazily in `fetchPrices` instead,
    // where `await` can hop onto the main actor.
    private let scraper: HeadlessWebScraper?

    init(scraper: HeadlessWebScraper? = nil) {
        self.scraper = scraper
    }

    func fetchPrices(setNum: String) async throws -> [PriceQuote] {
        guard let url = URL(string: "https://www.bricklink.com/catalogPG.asp?S=\(setNum)") else {
            throw ScrapeError.notFound
        }

        let scraper = await self.scraper ?? HeadlessWebScraper.shared
        let json = try await scraper.loadAndExtract(
            url: url,
            readinessScript: Self.readinessScript,
            extractScript: Self.extractScript
        )
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawPrices.self, from: data) else {
            throw ScrapeError.parsingFailed
        }

        let fetchedAt = Date()
        var quotes: [PriceQuote] = []
        if let used = raw.used, let amount = PriceParsing.amount(from: used) {
            quotes.append(PriceQuote(
                source: .bricklinkUsed,
                amount: amount,
                currency: PriceParsing.currency(from: used),
                sourceURL: url,
                fetchedAt: fetchedAt
            ))
        }
        if let new = raw.new, let amount = PriceParsing.amount(from: new) {
            quotes.append(PriceQuote(
                source: .bricklinkNew,
                amount: amount,
                currency: PriceParsing.currency(from: new),
                sourceURL: url,
                fetchedAt: fetchedAt
            ))
        }
        guard !quotes.isEmpty else { throw ScrapeError.notFound }
        return quotes
    }
}
