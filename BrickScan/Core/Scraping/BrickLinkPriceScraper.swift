import Foundation

/// Scrapes BrickLink "Price Guide" pages for LEGO items.
///
/// For classic sets the item is addressable directly by set number — no
/// lookup needed. For minifigs (Rebrickable `fig-…` prefix), Rebrickable and
/// BrickLink use completely different ID schemes (e.g. `fig-004396` vs
/// `oct033`) and the Rebrickable API doesn't expose the mapping (confirmed by
/// inspecting a real `/lego/minifigs/{set_num}/` response: no `bricklink_id`
/// or similar field). The mapping *is* rendered on the Rebrickable minifig's
/// own web page though, in an "External Sites" table — so for minifigs we
/// scrape that page first to resolve the BrickLink `M=` ID, then fetch the
/// price guide as normal. The resolved ID is cached in `BrickLinkMinifigIdStore`
/// (permanent mapping, never re-scraped once known).
///
/// The price guide page is a deeply nested table with four "Last 6 Months Sales"
/// summary quadrants (New-sold, Used-sold, New-for-sale, Used-for-sale) followed
/// by a per-month breakdown. The JS below walks the DOM by *visible row labels*
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

    private struct RawExternalId: Decodable {
        let id: String
    }

    // MARK: - Price guide scripts (shared between set and minifig flows)

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

    // MARK: - Rebrickable "External Sites" lookup (minifigs only)

    /// Waits for the "External Sites" table to render — a plain `<table>`
    /// with one `<label td>/<value td>` row per external catalog (BrickLink,
    /// BrickOwl, Brickset, …), confirmed by inspecting the live page.
    static let externalIdReadinessScript = """
    (function() {
        var text = document.body ? document.body.innerText : '';
        return text.indexOf('External Sites') !== -1;
    })()
    """

    /// Finds the row whose first cell reads exactly "BrickLink" and returns
    /// the linked catalog ID (e.g. "oct033") from its second cell.
    static let externalIdExtractScript = """
    (function() {
        var rows = Array.from(document.querySelectorAll('tr'));
        for (var i = 0; i < rows.length; i++) {
            var cells = rows[i].querySelectorAll('td');
            if (cells.length < 2) continue;
            if (cells[0].textContent.trim() !== 'BrickLink') continue;
            var link = cells[1].querySelector('a');
            var id = (link ? link.textContent : cells[1].textContent).trim();
            if (id) return JSON.stringify({ id: id });
        }
        return null;
    })()
    """

    // Not defaulted to `.shared` here: that's a main-actor-isolated static
    // property, and a default argument value must be evaluable in this
    // (nonisolated) init's context. Resolved lazily in `fetchPrices` instead,
    // where `await` can hop onto the main actor.
    private let scraper: HeadlessWebScraper?
    private let minifigIdStore: BrickLinkMinifigIdStore

    init(scraper: HeadlessWebScraper? = nil, minifigIdStore: BrickLinkMinifigIdStore = .shared) {
        self.scraper = scraper
        self.minifigIdStore = minifigIdStore
    }

    func fetchPrices(for legoSet: LegoSet) async throws -> [PriceQuote] {
        let scraper: HeadlessWebScraper
        if let injected = self.scraper {
            scraper = injected
        } else {
            scraper = await HeadlessWebScraper.shared
        }

        if legoSet.setNum.hasPrefix("fig-") {
            return try await fetchMinifigPrices(setNum: legoSet.setNum, scraper: scraper)
        } else {
            return try await fetchSetPrices(setNum: legoSet.setNum, scraper: scraper)
        }
    }

    private func fetchSetPrices(setNum: String, scraper: HeadlessWebScraper) async throws -> [PriceQuote] {
        // `viewExclude=Y` is BrickLink's "Exclude Incomplete Sets" toggle — we
        // want the value of a complete set, not one missing pieces.
        guard let priceGuideURL = URL(string: "https://www.bricklink.com/catalogPG.asp?S=\(setNum)&viewExclude=Y") else {
            throw ScrapeError.notFound
        }
        // The price guide is what we scrape; the link we surface is the set's
        // catalog item page (filter options in the fragment didn't stick).
        let itemURL = URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?S=\(setNum)") ?? priceGuideURL
        return try await fetchPricesFromGuide(priceGuideURL: priceGuideURL, itemURL: itemURL, scraper: scraper)
    }

    private func fetchMinifigPrices(setNum: String, scraper: HeadlessWebScraper) async throws -> [PriceQuote] {
        // Step 1: resolve the BrickLink `M=` ID, from the on-disk cache if a
        // previous lookup already resolved it — the mapping is permanent, so
        // there's no reason to re-scrape Rebrickable's minifig page every time.
        let bricklinkId: String
        if let cached = await minifigIdStore.lookup(setNum: setNum) {
            bricklinkId = cached
        } else {
            guard let rebrickableURL = URL(string: "https://rebrickable.com/minifigs/\(setNum)/") else {
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
            bricklinkId = externalId.id
            await minifigIdStore.save(setNum: setNum, bricklinkId: bricklinkId)
        }

        // Step 2: fetch the price guide for the resolved BrickLink minifig ID.
        guard let priceGuideURL = URL(string: "https://www.bricklink.com/catalogPG.asp?M=\(bricklinkId)&viewExclude=Y") else {
            throw ScrapeError.notFound
        }
        let itemURL = URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?M=\(bricklinkId)") ?? priceGuideURL
        return try await fetchPricesFromGuide(priceGuideURL: priceGuideURL, itemURL: itemURL, scraper: scraper)
    }

    private func fetchPricesFromGuide(
        priceGuideURL: URL,
        itemURL: URL,
        scraper: HeadlessWebScraper
    ) async throws -> [PriceQuote] {
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
