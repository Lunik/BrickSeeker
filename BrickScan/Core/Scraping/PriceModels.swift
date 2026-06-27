import Foundation

enum PriceSource: String, Codable, CaseIterable {
    case bricklinkUsed
    case bricklinkNew
    case amazon

    var displayName: String {
        switch self {
        case .bricklinkUsed: return "BrickLink (occasion)"
        case .bricklinkNew: return "BrickLink (neuf)"
        case .amazon: return "Amazon (neuf)"
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
