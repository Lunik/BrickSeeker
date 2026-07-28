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
    /// actually paid when it's known, falling back to the official retail price — so the number
    /// reads as "what my copy gained" for a tracked purchase, and as "how the market moved versus
    /// catalogue price" otherwise.
    enum Basis: Equatable {
        case paid
        case retail
        case unknown
    }

    /// Current estimated value of one unit, condition-aware. `nil` when no source has a price.
    let currentValueEUR: Double?
    /// The reference the growth is computed from (paid price, else retail). `nil` when neither is known.
    let basisEUR: Double?
    let basis: Basis
    /// The `ListCondition` `currentValueEUR` actually represents — not necessarily the list's own
    /// condition, since the resolvers cross-fall-back as a last resort (#194/#203). Lets the UI
    /// label the amount honestly ("valeur occasion") instead of trusting the nominal list.
    let valuedCondition: ListCondition?
    /// `(current − basis) / basis × 100`. `nil` unless *both* values are known, so a missing price
    /// never renders as a fake 0 %.
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
