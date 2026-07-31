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
    /// When `basis` is `.retail` this is a **market** quote (Amazon/Cdiscount/BrickLink), the
    /// lego.com retail price having been excluded so it can't be compared against itself — see
    /// `SetValuationCalculator.make`. It therefore doesn't always match the Collection row's price.
    let currentValueEUR: Double?
    /// The reference the growth is computed from (paid price, else retail). `nil` when neither is known.
    let basisEUR: Double?
    let basis: Basis
    /// The `ListCondition` `currentValueEUR` actually represents — not necessarily the list's own
    /// condition, since the resolvers cross-fall-back as a last resort (#194/#203). Lets the UI
    /// label the amount honestly ("valeur occasion") instead of trusting the nominal list.
    let valuedCondition: ListCondition?
    /// `(current − basis) / basis × 100`. `nil` unless both values are known *and* the value comes
    /// from a source independent of the reference — see `GrowthUnavailability` for the two ways
    /// this stays `nil`.
    let growthPercent: Double?
    /// Why `growthPercent` is `nil`, so the UI can explain the "—" instead of just showing it.
    /// `nil` exactly when `growthPercent` is non-`nil`.
    let growthUnavailability: GrowthUnavailability?

    /// The two reasons a growth figure can't be stated. Kept explicit rather than collapsing both
    /// into a bare `nil`, because they call for opposite UI: one is "go fetch a price", the other
    /// is "no market has quoted this set".
    enum GrowthUnavailability: Equatable {
        /// No current value, or no basis at all — nothing to compare. A refresh may fix it.
        case missingPrice
        /// The basis is the lego.com retail price and **no market source quotes this item at all**
        /// (no Amazon/Cdiscount, no BrickLink new or used), so the only number left to display is
        /// that same retail price. Comparing it against itself would report 0 % by construction
        /// rather than by measurement — the misleading kind of zero, since a retired set quoted at
        /// twice retail on Cdiscount would still read "+0 %" (issue #227). With the market-only
        /// resolution below this is now the *rare* case it was always meant to describe: it means
        /// "no market signal", not "we happened to read retail twice".
        case valuedAtBasis
    }

    static let empty = SetValuation(
        currentValueEUR: nil,
        basisEUR: nil,
        basis: .unknown,
        valuedCondition: nil,
        growthPercent: nil,
        growthUnavailability: .missingPrice
    )

    var hasValue: Bool { currentValueEUR != nil }
}

enum SetValuationCalculator {
    /// Builds a `SetValuation` for one set or minifig.
    ///
    /// The current value is resolved through the existing single sources of truth —
    /// `resolveCollectionPrice`/`resolveCollectionPriceCondition` for a set, `resolveMinifigPrice`
    /// for a `fig-…` (a minifig only ever has BrickLink quotes, #175/#203). Re-deriving a second
    /// chain here is exactly how the header card, the Collection row and the Statistics total would
    /// start disagreeing about the same set — the drift #194 had to fix. The one deliberate
    /// exception is the retail-basis case below, which reuses those very resolvers with
    /// `storePriceEUR: nil` rather than open-coding a new chain.
    ///
    /// **Breaking the circularity (#227).** With no paid price recorded the basis is the lego.com
    /// retail price — and `resolveCollectionPrice`'s new-price chain returns that same retail price
    /// first, so value and reference used to be one field read twice, and the card fell back to
    /// "évolution non mesurable" for nearly every owned set. So when (and only when) the basis is
    /// retail, the value is resolved from **market sources only** — Amazon/Cdiscount, BrickLink
    /// new/used — by passing `storePriceEUR: nil` to the same resolver. The comparison then measures
    /// something real (a retired set quoted at twice retail reads "+85 %", not "+0 %"), and
    /// `.valuedAtBasis` survives only for the genuinely signal-less case: retail known, no market
    /// quote anywhere. A `.paid` basis is never circular, so it keeps the full chain untouched.
    ///
    /// This makes the card's amount diverge from the Collection row / Statistics total for a
    /// retail-priced set with a market quote — intentionally. `resolveCollectionPrice` itself is
    /// **not** modified (that would desync all three, #194); the narrower resolution is local to
    /// this calculator, which is the only caller that has to compare its value against a reference.
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

        let currentValue: Double?
        let valuedCondition: ListCondition?
        // Tracked explicitly rather than re-derived from `currentValue == basisEUR`: once the value
        // comes from a market source, a quote that lands exactly on the retail price is a real,
        // measured 0 % — indistinguishable by equality alone from the retail-read-twice case, but
        // the opposite thing. Only this branch knows which one happened.
        var isValuedAtBasis = false
        if setNum.isMinifig {
            // A minifig has no `storePriceEUR` at all (#175), so its basis is `.paid` or `.unknown`
            // — never `.retail`, and never circular. Nothing to break here.
            currentValue = resolveMinifigPrice(condition: condition, quotes: quotes)
            // `resolveMinifigPrice` doesn't expose which side it picked; report the requested
            // condition (defaulting the way that resolver does) rather than inventing one.
            valuedCondition = currentValue == nil ? nil : (condition ?? .used)
        } else if basis == .retail,
                  let marketValue = resolveCollectionPrice(
                      storePriceEUR: nil,
                      condition: condition,
                      quotes: quotes
                  ) {
            currentValue = marketValue
            valuedCondition = resolveCollectionPriceCondition(
                storePriceEUR: nil,
                condition: condition,
                quotes: quotes
            )
        } else {
            // Either the basis isn't retail (no circularity to break), or no market source quotes
            // this set — in which case the full chain falls back to the retail price itself, and
            // that self-comparison is exactly what `.valuedAtBasis` exists to suppress.
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
            isValuedAtBasis = basis == .retail && currentValue != nil
        }

        let growthPercent: Double?
        let growthUnavailability: SetValuation.GrowthUnavailability?
        if let currentValue, let basisEUR, basisEUR > 0, !isValuedAtBasis {
            growthPercent = (currentValue - basisEUR) / basisEUR * 100
            growthUnavailability = nil
        } else {
            growthPercent = nil
            growthUnavailability = isValuedAtBasis ? .valuedAtBasis : .missingPrice
        }

        return SetValuation(
            currentValueEUR: currentValue,
            basisEUR: basisEUR,
            basis: basis,
            valuedCondition: valuedCondition,
            growthPercent: growthPercent,
            growthUnavailability: growthUnavailability
        )
    }
}
