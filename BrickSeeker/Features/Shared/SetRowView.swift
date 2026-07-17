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
    /// What kind of price `resolvedPrice` is (issue #157) — "Neuf"/"Occasion"/"Meilleure offre",
    /// resolved per-screen since the same bold € amount means different things depending on which
    /// list is rendering it. `nil` renders no caption (never shown without a price either way).
    var priceLabel: String? = nil
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
                    if let priceLabel {
                        Text(priceLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
    resolveCollectionPriceDetailed(storePriceEUR: storePriceEUR, condition: condition, quotes: quotes)?.amount
}

/// Which `ListCondition` actually produced `resolveCollectionPrice`'s number (issue #157) —
/// usually matches the list's own condition, but differs when the #194 cross-fallback kicked in
/// (e.g. a `.used` list with no BrickLink used quote yet, priced off the new-price chain
/// instead). Lets `CollectionView` label its row price honestly rather than trusting the list's
/// nominal condition.
func resolveCollectionPriceCondition(
    storePriceEUR: Double?,
    condition: ListCondition?,
    quotes: [PriceQuote]
) -> ListCondition? {
    resolveCollectionPriceDetailed(storePriceEUR: storePriceEUR, condition: condition, quotes: quotes)?.condition
}

/// Shared branching behind `resolveCollectionPrice`/`resolveCollectionPriceCondition` — a single
/// source of truth so the amount and its label can never drift apart.
private func resolveCollectionPriceDetailed(
    storePriceEUR: Double?,
    condition: ListCondition?,
    quotes: [PriceQuote]
) -> (amount: Double, condition: ListCondition)? {
    let usedPrice = quotes.first(where: { $0.source == .bricklinkUsed })
        .map { ($0.amount as NSDecimalNumber).doubleValue }
    let newPrice = resolveNewPriceForValuation(storePriceEUR: storePriceEUR, quotes: quotes)
    switch condition ?? .newSet {
    case .newSet:
        if let newPrice { return (newPrice, .newSet) }
        if let usedPrice { return (usedPrice, .used) }
        return nil
    case .used:
        if let usedPrice { return (usedPrice, .used) }
        if let newPrice { return (newPrice, .newSet) }
        return nil
    }
}

/// BrickLink-only price resolution for a minifig (issue #203) — a minifig only ever has BrickLink
/// new/used quotes (#175: `PriceRepository.fetchPrices` special-cases `isMinifig`, no retail/
/// Amazon/Cdiscount scrape), so this reduces to a condition-aware pick with a last-resort fallback
/// to the other condition — the same "primary source, cross-fallback as last resort" shape as
/// `resolveCollectionPriceDetailed`'s used↔new fallback (#194), minus the new-price chain (no
/// `storePriceEUR`/Amazon/Cdiscount for a minifig). `condition` is the `ListCondition` of the
/// minifig's owned containing set(s) (`MinifigGalleryView.conditionByFigNum`); `nil` — a minifig
/// with no owned containing set, i.e. a silhouette — defaults to `.used` rather than
/// `resolveCollectionPriceDetailed`'s `.newSet` default, matching this resolver's pre-#203 primary
/// (and, until now, only) source.
func resolveMinifigPrice(condition: ListCondition?, quotes: [PriceQuote]) -> Double? {
    let usedPrice = quotes.first(where: { $0.source == .bricklinkUsed })
        .map { ($0.amount as NSDecimalNumber).doubleValue }
    let newPrice = quotes.first(where: { $0.source == .bricklinkNew })
        .map { ($0.amount as NSDecimalNumber).doubleValue }
    switch condition ?? .used {
    case .used: return usedPrice ?? newPrice
    case .newSet: return newPrice ?? usedPrice
    }
}

/// Price resolution for `WishlistView` (issue #109/#121): best(Amazon, Cdiscount) → lego.com
/// retail → BrickLink new → BrickLink used — Amazon/Cdiscount before lego.com, reversed from
/// `resolveNewPrice`'s order, per request on the wishlist specifically.
func resolveWishlistPrice(storePriceEUR: Double?, quotes: [PriceQuote]) -> Double? {
    resolveWishlistPriceDetailed(storePriceEUR: storePriceEUR, quotes: quotes)?.amount
}

/// Which `ListCondition` `resolveWishlistPrice`'s number actually represents (issue #157) — the
/// chain's first three steps are always new, but the final BrickLink-used fallback means a
/// wishlisted set with no surviving new-price source (common for retired/hard-to-find sets, the
/// exact profile a wishlist skews toward) can silently resolve to a used price.
func resolveWishlistPriceCondition(storePriceEUR: Double?, quotes: [PriceQuote]) -> ListCondition? {
    resolveWishlistPriceDetailed(storePriceEUR: storePriceEUR, quotes: quotes)?.condition
}

private func resolveWishlistPriceDetailed(storePriceEUR: Double?, quotes: [PriceQuote]) -> (amount: Double, condition: ListCondition)? {
    if let amazonOrCdiscount = bestAmazonOrCdiscountPrice(in: quotes) { return (amazonOrCdiscount, .newSet) }
    if let retail = storePriceEUR { return (retail, .newSet) }
    if let newQuote = quotes.first(where: { $0.source == .bricklinkNew }) {
        return ((newQuote.amount as NSDecimalNumber).doubleValue, .newSet)
    }
    if let usedQuote = quotes.first(where: { $0.source == .bricklinkUsed }) {
        return ((usedQuote.amount as NSDecimalNumber).doubleValue, .used)
    }
    return nil
}
