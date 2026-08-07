import Foundation

/// Per-list annotation that drives which price source is used when valuing the collection.
/// Stored as a raw `String` in SwiftData (via `CachedSetList.conditionRaw`) so that adding
/// new cases later doesn't require a schema migration.
enum ListCondition: String, Codable, CaseIterable, Identifiable {
    /// Neuf — lego.com → Amazon → BrickLink new.
    case newSet
    /// Occasion — BrickLink used only; nil when unavailable.
    case used

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newSet: return "Neuf"
        case .used: return "Occasion"
        }
    }
}

enum PriceSource: String, Codable, CaseIterable {
    case bricklinkUsed
    case bricklinkNew
    case amazon
    /// Cdiscount neuf (issue #124) — shown as its own row in `SetDetailView`, alongside `.amazon`,
    /// but `SetRowView`'s fallback chains (History/Wishlist/Collection row/valuation) still treat
    /// the two as one comparison point rather than two separate steps (see
    /// `bestAmazonOrCdiscountPrice`/`mostExpensiveAmazonOrCdiscountPrice`).
    case cdiscount

    /// True for the one source that quotes a used/second-hand price — every other case is neuf.
    var isUsed: Bool {
        self == .bricklinkUsed
    }

    var displayName: String {
        switch self {
        case .bricklinkUsed: return "BrickLink (occasion)"
        case .bricklinkNew: return "BrickLink (neuf)"
        case .amazon: return "Amazon (neuf)"
        case .cdiscount: return "Cdiscount (neuf)"
        }
    }
}

extension String {
    /// Display name for a `PriceHistoryEntry.source` raw value, covering both `PriceSource` cases
    /// and `LocalRepository.legoStoreHistorySource` (lego.com has no `PriceSource` case of its own).
    var priceHistorySourceDisplayName: String {
        if self == legoStoreHistorySource { return "lego.com (officiel)" }
        return PriceSource(rawValue: self)?.displayName ?? self
    }
}

/// One source's price for one item. `amount` is *the* number every consumer means by "the price"
/// (`DealVerdict`, `SetRowView`, the valuation kernel, the price history) — the fields below it are
/// optional context a source may or may not provide, and nothing may quietly promote one of them
/// into `amount`'s place (#213).
///
/// The trailing defaults are load-bearing: the synthesised memberwise init is called from
/// `BrickLinkPriceRepository`, `AmazonPriceScraper`, `CdiscountPriceScraper` and
/// `CachedSetPrice.quote`, and only BrickLink has anything to put in these.
struct PriceQuote: Codable, Hashable {
    let source: PriceSource
    let amount: Decimal
    let currency: String
    let sourceURL: URL?
    let fetchedAt: Date
    /// Low/high of the sales the average was computed over (BrickLink `min_price`/`max_price`).
    /// Always meaningful as a pair or not at all — see `BrickLinkPriceRepository.fetchQuote`.
    var minAmount: Decimal? = nil
    var maxAmount: Decimal? = nil
    /// How many lots that range spans (BrickLink `unit_quantity`) — the sample size behind it.
    var lotCount: Int? = nil
    /// The individual sales the average was computed over (BrickLink `price_detail[]`, #214).
    ///
    /// `nil` and `[]` mean different things, and the storage layer depends on the difference:
    /// `nil` is "this quote says nothing about sales" (a quote rebuilt from the cache, or a source
    /// that has no such concept), while `[]` is a live fetch that found **no** sale — the only one
    /// of the two allowed to clear previously stored rows.
    var sales: [SoldSale]? = nil

    /// Whether the average rests on so few sales that one atypical transaction *is* the quote.
    /// Verified on #240: `10356-1` used quotes 196,27 € — a single sale, DE → NL — which is what
    /// produced the "−48 % vs retail" that opened the issue, while the same set's current used
    /// listings sit at 260–270 €. On used, `n ≤ 3` is the common case rather than the exception
    /// (`trek001` used: 1 lot; `10356-1` used listings: 3), so this is a routine caveat.
    ///
    /// Nil `lotCount` is *not* thin: every non-BrickLink source quotes one listing rather than an
    /// average over sales, and has no sample size to be small in the first place.
    var isThinSample: Bool {
        guard let lotCount else { return false }
        return lotCount > 0 && lotCount <= 2
    }
}

/// One real, completed sale behind a `PriceQuote` — BrickLink's `price_detail[]` under
/// `guide_type=sold`. The shape was verified against a live signed call before being coded against
/// (#214, skill `check-bricklink-endpoint`): `guide_type=stock` returns current *listings* instead,
/// with no `date_ordered` at all, so the scatter is only meaningful on the `sold` guide.
///
/// Currency is deliberately absent — it is always the parent quote's, and duplicating it per sale
/// would only invite the two drifting apart.
struct SoldSale: Codable, Hashable {
    let unitAmount: Decimal
    let quantity: Int
    let orderedAt: Date
}
