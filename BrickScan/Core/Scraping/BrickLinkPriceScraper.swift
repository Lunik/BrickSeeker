import Foundation

/// Scrapes the BrickLink "Price Guide" page for a set, which is addressable
/// directly by set number — no search step needed.
///
/// The page is a deeply nested table with four "Last 6 Months Sales" summary
/// quadrants (New-sold, Used-sold, New-for-sale, Used-for-sale) followed by a
/// per-month breakdown. The JS below walks the DOM by *visible row labels*
/// instead of CSS class names (undocumented, first to break on a redesign).
///
/// The reliable anchor is the "Times Sold:" stat row: the New-sold and
/// Used-sold summary quadrants are the first two such rows on the page and
/// appear adjacently, before the for-sale quadrants (which carry no
/// "Times Sold:") and before the monthly detail. For each we read the next
/// "Avg Price:" value. Matching is done on the *exact* leaf-cell label, so
/// outer wrapper rows (whose text is the whole quadrant blob) and the
/// "Qty Avg Price:" row are skipped — that exact-match is what an earlier
/// adjacency-based walk got wrong, mistakenly returning the "Times Sold" count.
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
        function textOf(el) { return (el.textContent || '').replace(/\\u00a0/g, ' ').replace(/\\s+/g, ' ').trim(); }
        function cellsOf(row) { return Array.from(row.querySelectorAll('td,th')); }
        // The leaf stat rows are exactly two cells: a label and its value. The
        // label compares equal only on its own row, never on an outer wrapper
        // row whose text is the whole quadrant blob.
        function labelOf(cell) { return textOf(cell).replace(/[:\\s]+$/, '').toLowerCase(); }
        var rows = Array.from(document.querySelectorAll('tr'));
        // Avg Price of the next sold-summary quadrant after a "Times Sold:" row.
        var soldAvg = [];
        for (var i = 0; i < rows.length; i++) {
            var cells = cellsOf(rows[i]);
            if (cells.length < 2 || labelOf(cells[0]) !== 'times sold') continue;
            // A quadrant with no sales has an empty count — skip it so we don't
            // borrow the next quadrant's Avg Price.
            if (!/[0-9]/.test(textOf(cells[1]))) { soldAvg.push(null); continue; }
            var avg = null;
            for (var j = i + 1; j < rows.length && j < i + 10; j++) {
                var cj = cellsOf(rows[j]);
                if (cj.length < 2) continue;
                var lj = labelOf(cj[0]);
                if (lj === 'avg price') { avg = textOf(cj[1]); break; }
                if (lj === 'times sold') break;
            }
            soldAvg.push(avg);
        }
        return JSON.stringify({
            new: soldAvg[0] || null,
            used: soldAvg[1] || null
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
        // `viewExclude=Y` is BrickLink's "Exclude Incomplete Sets" toggle — we
        // want the value of a complete set, not one missing pieces.
        guard let priceGuideURL = URL(string: "https://www.bricklink.com/catalogPG.asp?S=\(setNum)&viewExclude=Y") else {
            throw ScrapeError.notFound
        }
        // The price guide is what we scrape; the link we surface is the set's
        // catalog item page (filter options in the fragment didn't stick).
        let itemURL = URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?S=\(setNum)") ?? priceGuideURL

        let scraper: HeadlessWebScraper
        if let injected = self.scraper {
            scraper = injected
        } else {
            scraper = await HeadlessWebScraper.shared
        }
        let json = try await scraper.loadAndExtract(
            url: priceGuideURL,
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
                sourceURL: itemURL,
                fetchedAt: fetchedAt
            ))
        }
        if let new = raw.new, let amount = PriceParsing.amount(from: new) {
            quotes.append(PriceQuote(
                source: .bricklinkNew,
                amount: amount,
                currency: PriceParsing.currency(from: new),
                sourceURL: itemURL,
                fetchedAt: fetchedAt
            ))
        }
        guard !quotes.isEmpty else { throw ScrapeError.notFound }
        return quotes
    }
}
