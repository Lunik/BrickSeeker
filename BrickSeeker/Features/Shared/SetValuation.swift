import Foundation

/// What one set (or minifig) is worth right now, and how that compares to what it cost — the
/// local equivalent of BrickEconomy's `current_value` + `growth` pair, computed entirely from
/// data the app already fetches (lego.com retail, BrickLink new/used, Amazon/Cdiscount) with no
/// new network call and no third-party valuation service.
///
/// Deliberately a *pure* value type with a pure calculator, like `DealVerdictCalculator` and
/// `PriceComparison`: no repository, no `ModelContext`, no network. Callers read the pieces they
/// need from SwiftData and hand them in, which keeps this testable by inspection and reusable
/// from any screen.
struct SetValuation: Equatable {
    /// Which reference `growthPercent` is measured against. The user's decision: the price they
    /// actually paid when it's known, and **the lego.com retail price — nothing else — as the
    /// default** when it isn't. A marketplace quote (Amazon, Cdiscount, BrickLink) is never
    /// promoted to reference: those are what the set is worth *now*, not what it cost, and using
    /// one as the reference would make the percentage compare two market readings instead of
    /// measuring a gain. No paid price and no retail price therefore means no reference at all
    /// (`.unknown`) and no growth figure, rather than a growth measured against a stand-in.
    enum Basis: Equatable {
        case paid
        case retail
        case unknown
    }

    /// Current estimated value of one unit, condition-aware. `nil` when no source has a price.
    /// Resolved by `resolveCollectionPrice`/`resolveMinifigPrice`, so it always matches the same
    /// set's Collection row and its share of the Statistics total (#194).
    let currentValueEUR: Double?
    /// The reference the growth is computed from: the paid price, else the lego.com retail price.
    /// `nil` when neither is known — see `Basis` for why nothing else fills in.
    let basisEUR: Double?
    let basis: Basis
    /// The `ListCondition` `currentValueEUR` actually represents — not necessarily the list's own
    /// condition, since the resolvers cross-fall-back as a last resort (#194/#203). Lets the UI
    /// label the amount honestly ("valeur occasion") instead of trusting the nominal list.
    let valuedCondition: ListCondition?
    /// `(current − basis) / basis × 100`. `nil` exactly when there is no current value or no
    /// reference to compare it to; the UI shows "—" and the caption says which piece is missing.
    let growthPercent: Double?

    static let empty = SetValuation(
        currentValueEUR: nil,
        basisEUR: nil,
        basis: .unknown,
        valuedCondition: nil,
        growthPercent: nil
    )

    var hasValue: Bool { currentValueEUR != nil }
}

enum SetValuationCalculator {
    /// Builds a `SetValuation` for one set or minifig.
    ///
    /// The current value is **never** resolved here: it delegates to the existing single sources of
    /// truth — `resolveCollectionPrice`/`resolveCollectionPriceCondition` for a set,
    /// `resolveMinifigPrice` for a `fig-…` (a minifig only ever has BrickLink quotes, #175/#203).
    /// Re-deriving a second chain here is exactly how the header card, the Collection row and the
    /// Statistics total would start disagreeing about the same set — the drift #194 had to fix.
    ///
    /// The reference follows one rule and no other (issue #227): the paid price when recorded,
    /// **the lego.com retail price as the sole default**, and nothing at all otherwise. So:
    /// - a set with a retail price always has a reference, and therefore always shows a growth
    ///   figure — "évolution indisponible" is now reserved for the genuinely reference-less case;
    /// - when the value resolves to that same retail price (an in-stock sealed set, where the
    ///   new-price chain returns retail first), the honest reading is "worth what it lists for",
    ///   and the card shows a neutral 0 % rather than refusing to answer;
    /// - a minifig has no lego.com retail price at all (#175), so it gets no default reference and
    ///   keeps showing "—" until a paid price is recorded. That is deliberate, not an oversight: a
    ///   minifig is never sold at retail on lego.com, so there is no catalogue price to move away
    ///   from, and its BrickLink quote must not stand in for one.
    ///
    /// - Parameters:
    ///   - setNum: used only to tell a minifig from a set (`String.isMinifig`).
    ///   - storePriceEUR: lego.com retail (`CachedSet.storePriceEUR`); always `nil` for a minifig.
    ///   - paidPriceEUR: what the user paid, when known (`SetPurchaseRecord`).
    ///   - condition: the owning list's condition; `nil` for a set that isn't in the collection.
    ///   - quotes: non-expired cached quotes for this item (`LocalRepository.cachedPrices`).
    static func make(
        setNum: String,
        storePriceEUR: Double?,
        paidPriceEUR: Double?,
        condition: ListCondition?,
        quotes: [PriceQuote]
    ) -> SetValuation {
        let currentValue: Double?
        let valuedCondition: ListCondition?
        if setNum.isMinifig {
            currentValue = resolveMinifigPrice(condition: condition, quotes: quotes)
            // `resolveMinifigPrice` doesn't expose which side it picked; report the requested
            // condition (defaulting the way that resolver does) rather than inventing one.
            valuedCondition = currentValue == nil ? nil : (condition ?? .used)
        } else {
            currentValue = resolveCollectionPrice(
                storePriceEUR: storePriceEUR,
                condition: condition,
                quotes: quotes
            )
            valuedCondition = resolveCollectionPriceCondition(
                storePriceEUR: storePriceEUR,
                condition: condition,
                quotes: quotes
            )
        }

        let basisEUR: Double?
        let basis: SetValuation.Basis
        if let paidPriceEUR, paidPriceEUR > 0 {
            basisEUR = paidPriceEUR
            basis = .paid
        } else if let storePriceEUR, storePriceEUR > 0 {
            // The retail price stands in for the paid price. Nothing else may: see `Basis`.
            basisEUR = storePriceEUR
            basis = .retail
        } else {
            basisEUR = nil
            basis = .unknown
        }

        let growthPercent: Double?
        if let currentValue, let basisEUR, basisEUR > 0 {
            growthPercent = (currentValue - basisEUR) / basisEUR * 100
        } else {
            growthPercent = nil
        }

        return SetValuation(
            currentValueEUR: currentValue,
            basisEUR: basisEUR,
            basis: basis,
            valuedCondition: valuedCondition,
            growthPercent: growthPercent
        )
    }
}
