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

struct PriceQuote: Codable, Hashable {
    let source: PriceSource
    let amount: Decimal
    let currency: String
    let sourceURL: URL?
    let fetchedAt: Date
}
