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

struct PriceQuote: Codable, Hashable {
    let source: PriceSource
    let amount: Decimal
    let currency: String
    let sourceURL: URL?
    let fetchedAt: Date
}
