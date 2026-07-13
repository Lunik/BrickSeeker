import SwiftUI

/// Trailing selection mark for list rows in multi-select mode (Collection/History/Wishlist/
/// batch scan session summary) — drawn by hand and placed at the end of the row rather than
/// using `List(selection:)`'s native circle, which SwiftUI always pins to the leading edge with
/// no repositioning modifier (#161).
struct RowSelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? AppTheme.shared.accent : Color.secondary.opacity(0.5))
            .accessibilityHidden(true)
    }
}

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
                        // VoiceOver read the bare "×2" as "multiplication 2" (#143) — an explicit
                        // label says what it actually means.
                        Text("×\(quantity)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(quantity) exemplaires")
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

/// Combines Amazon and Cdiscount into a single comparison point (issue #124): both are neuf
/// marketplace scrapes with the same reliability profile, so every fallback chain below treats
/// them as one step rather than two, picking whichever `amount` `pick` prefers. Returns the lone
/// quote when only one of the two is present, `nil` when neither is.
private func amazonOrCdiscountPrice(in quotes: [PriceQuote], pick: (Double, Double) -> Double) -> Double? {
    let amazon = quotes.first(where: { $0.source == .amazon }).map { ($0.amount as NSDecimalNumber).doubleValue }
    let cdiscount = quotes.first(where: { $0.source == .cdiscount }).map { ($0.amount as NSDecimalNumber).doubleValue }
    switch (amazon, cdiscount) {
    case let (a?, c?): return pick(a, c)
    case let (a?, nil): return a
    case let (nil, c?): return c
    case (nil, nil): return nil
    }
}

/// The cheaper of Amazon/Cdiscount — used wherever the fallback chain is about finding the best
/// deal to buy at (History, Wishlist, and `SetDetailView`'s merged "Amazon" row).
func bestAmazonOrCdiscountPrice(in quotes: [PriceQuote]) -> Double? {
    amazonOrCdiscountPrice(in: quotes, pick: min)
}

/// The pricier of Amazon/Cdiscount — used for collection valuation (issue #124): the total
/// estimated value shouldn't drop just because one marketplace happened to be cheaper that day.
func mostExpensiveAmazonOrCdiscountPrice(in quotes: [PriceQuote]) -> Double? {
    amazonOrCdiscountPrice(in: quotes, pick: max)
}

/// New-price fallback chain used by HistoryView: lego.com retail → best(Amazon, Cdiscount) →
/// BrickLink new. Never returns a used price.
func resolveNewPrice(storePriceEUR: Double?, quotes: [PriceQuote]) -> Double? {
    if let retail = storePriceEUR { return retail }
    if let amazonOrCdiscount = bestAmazonOrCdiscountPrice(in: quotes) { return amazonOrCdiscount }
    if let q = quotes.first(where: { $0.source == .bricklinkNew }) {
        return (q.amount as NSDecimalNumber).doubleValue
    }
    return nil
}

/// Same chain as `resolveNewPrice`, but takes the pricier of Amazon/Cdiscount rather than the
/// cheaper (issue #124) — collection valuation (`resolveCollectionPrice`) shouldn't under-value a
/// set based on which marketplace happened to be cheaper that day.
private func resolveNewPriceForValuation(storePriceEUR: Double?, quotes: [PriceQuote]) -> Double? {
    if let retail = storePriceEUR { return retail }
    if let amazonOrCdiscount = mostExpensiveAmazonOrCdiscountPrice(in: quotes) { return amazonOrCdiscount }
    if let q = quotes.first(where: { $0.source == .bricklinkNew }) {
        return (q.amount as NSDecimalNumber).doubleValue
    }
    return nil
}

/// The single source of truth for what one owned set is worth — used both for the CollectionView
/// row price **and** for collection valuation (`StatisticsViewModel`'s total / coverage counter
/// and `CollectionPriceUpdateSection`'s "prix manquants"), so the list and the stats total can
/// never disagree about a set's price (issue #194). The list condition stays the *primary* source,
/// with a cross-fallback to the other condition only as a last resort:
/// - `.newSet` (or no list): new-price chain first, then BrickLink used as last resort.
/// - `.used`: BrickLink used first, then the new-price chain as last resort.
///
/// The used↔new cross-fallback deliberately reverses the earlier "honest valuation" decision of
/// #47/#87 (which returned `nil` rather than value an occasion set off a retail proxy): #194 found
/// that dropping such sets from the total both under-counted the collection value and left the
/// "Compléter les prix manquants" button looping on sets a re-fetch could never fix. The fallback
/// is strictly last-resort and does **not** reorder the new-price precedence (lego.com > Amazon/
/// Cdiscount > BrickLink new, see #124). `nil` still means "no price at any source" — genuinely
/// unfindable, not merely un-fetched.
func resolveCollectionPrice(
    storePriceEUR: Double?,
    condition: ListCondition?,
    quotes: [PriceQuote]
) -> Double? {
    let usedPrice = quotes.first(where: { $0.source == .bricklinkUsed })
        .map { ($0.amount as NSDecimalNumber).doubleValue }
    switch condition ?? .newSet {
    case .newSet:
        return resolveNewPriceForValuation(storePriceEUR: storePriceEUR, quotes: quotes) ?? usedPrice
    case .used:
        return usedPrice ?? resolveNewPriceForValuation(storePriceEUR: storePriceEUR, quotes: quotes)
    }
}

/// Price resolution for `WishlistView` (issue #109/#121): best(Amazon, Cdiscount) → lego.com
/// retail → BrickLink new → BrickLink used — Amazon/Cdiscount before lego.com, reversed from
/// `resolveNewPrice`'s order, per request on the wishlist specifically.
func resolveWishlistPrice(storePriceEUR: Double?, quotes: [PriceQuote]) -> Double? {
    if let amazonOrCdiscount = bestAmazonOrCdiscountPrice(in: quotes) { return amazonOrCdiscount }
    if let retail = storePriceEUR { return retail }
    for source in [PriceSource.bricklinkNew, .bricklinkUsed] {
        if let q = quotes.first(where: { $0.source == source }) {
            return (q.amount as NSDecimalNumber).doubleValue
        }
    }
    return nil
}
