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
    @ViewBuilder let trailingContent: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            SetThumbnailView(imageUrl: setImgUrl)

            VStack(alignment: .leading, spacing: 3) {
                Text(setNum).font(.headline)
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
