import Foundation

/// Scrapes BrickLink "Price Guide" pages for LEGO items.
///
/// Most classic sets are addressable directly by set number (BrickLink's `S=`
/// catalog type) — no lookup needed. But Rebrickable and BrickLink don't
/// always agree on numbering: Rebrickable minifigs (`fig-…` prefix) use a
/// completely different scheme from BrickLink's (e.g. `fig-004396` vs
/// `oct033`), and some Rebrickable *sets* — notably individual collectible-
/// minifigure boxes, which Rebrickable numbers as their own set (e.g.
/// `71039-6`) — have no matching BrickLink set entry at all, because
/// BrickLink catalogs the physical contents as a minifig instead.
///
/// The workflow therefore is:
///   1. If this isn't a `fig-…` id, try BrickLink's `S=` catalog directly.
///   2. If that has no data (or it's a minifig, which never has one), scrape
///      the item's Rebrickable page for its "External Sites" table, which
///      links out to the matching BrickLink catalog entry — of whatever type
///      (`S`, `M`, …) BrickLink actually filed it under (confirmed by
///      inspecting a real page: the Rebrickable API doesn't expose this
///      mapping, only the rendered page does).
///   3. Fetch the price guide for that resolved reference.
///   4. If nothing matches at any step, the item has no BrickLink price.
///
/// The resolved reference is cached in `BrickLinkMinifigIdStore` (permanent
/// mapping — BrickLink never reassigns a catalog ID — so step 2 only runs
/// once per item, not on every price refresh).
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
        let href: String?
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

    // MARK: - Rebrickable "External Sites" lookup (both sets and minifigs)

    /// Waits for the "External Sites" table to render — a plain `<table>`
    /// with one `<label td>/<value td>` row per external catalog (BrickLink,
    /// BrickOwl, Brickset, …), confirmed by inspecting the live page. Present
    /// on both `/sets/{set_num}/` and `/minifigs/{set_num}/` pages.
    static let externalIdReadinessScript = """
    (function() {
        var text = document.body ? document.body.innerText : '';
        return text.indexOf('External Sites') !== -1;
    })()
    """

    /// Finds the row whose first cell reads exactly "BrickLink" and returns the linked catalog
    /// ID (e.g. "oct033") from its second cell, along with the link's `href` — the href's query
    /// string (e.g. `catalogitem.page?S=71039-1` or `?M=oct033`) tells us which BrickLink catalog
    /// type (`S`, `M`, …) the item was actually filed under, since that isn't always the same
    /// type we started the lookup with.
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

        let setNum = legoSet.setNum
        let isMinifig = setNum.hasPrefix("fig-")

        // Step 1: a minifig id never has a direct `S=` set entry, so only try this for sets.
        if !isMinifig, let quotes = try? await fetchPrices(for: BrickLinkCatalogRef(type: "S", id: setNum), scraper: scraper) {
            return quotes
        }

        // Steps 2-3: resolve the actual BrickLink catalog reference from the on-disk cache, or by
        // scraping Rebrickable's "External Sites" table if this is the first time this item is
        // looked up — the mapping is permanent, so there's no reason to re-scrape on every
        // price refresh.
        let ref: BrickLinkCatalogRef
        if let cached = await minifigIdStore.lookup(setNum: setNum) {
            ref = cached
        } else {
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
            ref = Self.catalogRef(id: externalId.id, href: externalId.href, fallbackType: isMinifig ? "M" : "S")
            await minifigIdStore.save(setNum: setNum, ref: ref)
        }

        // Step 4: fetch the price guide for the resolved reference. If this fails too, the item
        // genuinely has no BrickLink price (step 5 — "Indisponible" — happens at the UI layer).
        return try await fetchPrices(for: ref, scraper: scraper)
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

    private func fetchPrices(for ref: BrickLinkCatalogRef, scraper: HeadlessWebScraper) async throws -> [PriceQuote] {
        // `viewExclude=Y` is BrickLink's "Exclude Incomplete Sets" toggle — we
        // want the value of a complete set, not one missing pieces.
        guard let priceGuideURL = URL(string: "https://www.bricklink.com/catalogPG.asp?\(ref.type)=\(ref.id)&viewExclude=Y") else {
            throw ScrapeError.notFound
        }
        // The price guide is what we scrape; the link we surface is the item's catalog page
        // (filter options in the fragment didn't stick).
        let itemURL = URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?\(ref.type)=\(ref.id)") ?? priceGuideURL
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
