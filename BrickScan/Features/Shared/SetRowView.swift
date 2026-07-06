import SwiftUI

/// Shared row component for History and Collection list items.
/// The caller is responsible for resolving `resolvedPrice` according to its own rules —
/// History always uses new-price sources, Collection uses new or used depending on list condition.
struct SetRowView<Trailing: View>: View {
    let setNum: String
    let name: String
    let setImgUrl: String?
    var subtitle: String? = nil
    var resolvedPrice: Double? = nil
    var isInWishlist: Bool = false
    /// Copies owned (issue #115) — only ever passed > 1 by CollectionView, so the "×N" badge
    /// stays invisible everywhere else (History/Wishlist rows aren't about owned copies).
    var quantity: Int = 1
    @ViewBuilder let trailingContent: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            SetThumbnailView(imageUrl: setImgUrl)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(setNum.baseSetNum).font(.headline)
                    if quantity > 1 {
                        Text("×\(quantity)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    if isInWishlist {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                            .accessibilityLabel("Dans ta liste cadeaux")
                    }
                }
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let price = resolvedPrice {
                    Text(price, format: .currency(code: "EUR"))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                }
                trailingContent()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Price resolution helpers

/// New-price fallback chain used by HistoryView: lego.com retail → Amazon → BrickLink new.
/// Never returns a used price.
func resolveNewPrice(storePriceEUR: Double?, quotes: [PriceQuote]) -> Double? {
    if let retail = storePriceEUR { return retail }
    for source in [PriceSource.amazon, .bricklinkNew] {
        if let q = quotes.first(where: { $0.source == source }) {
            return (q.amount as NSDecimalNumber).doubleValue
        }
    }
    return nil
}

/// Price resolution for a single owned set in CollectionView.
/// - `.newSet` (or no list): new-price chain first, then BrickLink used as last resort.
/// - `.used`: BrickLink used first, then new-price chain as last resort.
func resolveCollectionPrice(
    storePriceEUR: Double?,
    condition: ListCondition?,
    quotes: [PriceQuote]
) -> Double? {
    let usedPrice = quotes.first(where: { $0.source == .bricklinkUsed })
        .map { ($0.amount as NSDecimalNumber).doubleValue }
    switch condition ?? .newSet {
    case .newSet:
        return resolveNewPrice(storePriceEUR: storePriceEUR, quotes: quotes) ?? usedPrice
    case .used:
        return usedPrice ?? resolveNewPrice(storePriceEUR: storePriceEUR, quotes: quotes)
    }
}

/// Price resolution for `WishlistView` (issue #109/#121): Amazon → lego.com retail → BrickLink
/// new → BrickLink used — Amazon before lego.com, reversed from `resolveNewPrice`'s order, per
/// request on the wishlist specifically.
func resolveWishlistPrice(storePriceEUR: Double?, quotes: [PriceQuote]) -> Double? {
    if let q = quotes.first(where: { $0.source == .amazon }) {
        return (q.amount as NSDecimalNumber).doubleValue
    }
    if let retail = storePriceEUR { return retail }
    for source in [PriceSource.bricklinkNew, .bricklinkUsed] {
        if let q = quotes.first(where: { $0.source == source }) {
            return (q.amount as NSDecimalNumber).doubleValue
        }
    }
    return nil
}

/// Price resolution used for collection **valuation** (total estimated value / coverage counter,
/// see issue #47/#87) — unlike `resolveCollectionPrice`, it does NOT cross-fall-back between new
/// and used sources: an occasion set with no BrickLink-used quote stays priceless rather than
/// being valued off a retail proxy, and vice versa. Shared by `StatisticsViewModel` (the "X / Y
/// sets" coverage counter) and `CollectionPriceUpdateSection` (the "compléter les prix manquants"
/// button) so both agree on what counts as "missing".
func effectiveValuationPrice(
    storePriceEUR: Double?,
    condition: ListCondition?,
    quotes: [PriceQuote]
) -> Double? {
    switch condition ?? .newSet {
    case .newSet:
        return resolveNewPrice(storePriceEUR: storePriceEUR, quotes: quotes)
    case .used:
        return quotes.first(where: { $0.source == .bricklinkUsed })
            .map { ($0.amount as NSDecimalNumber).doubleValue }
    }
}
