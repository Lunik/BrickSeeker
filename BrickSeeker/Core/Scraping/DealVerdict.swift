import Foundation

/// Verdict tiers for the "prix vu en magasin" check (issue #12 / #94) — a price the user typed
/// in, weighed against the reference prices already loaded for this set.
enum DealVerdict {
    case good
    case fair
    case bad

    var emoji: String {
        switch self {
        case .good: return "🟢"
        case .fair: return "🟡"
        case .bad: return "🔴"
        }
    }

    var label: String {
        switch self {
        case .good: return "Bonne affaire"
        case .fair: return "Correct"
        case .bad: return "À éviter"
        }
    }
}

/// One reference price the seen price was measured against, with the €/% gap already computed
/// so the view has nothing left to calculate.
struct DealComparison: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let referenceAmount: Decimal
    let differenceAmount: Decimal
    let percent: Int
}

struct DealVerdictResult {
    let verdict: DealVerdict
    let comparisons: [DealComparison]
}

/// Pure verdict logic — no network, no view-model dependency — comparing a price seen in store
/// against the lego.com retail price and the scraped `PriceQuote`s already held in memory by
/// `SetDetailViewModel`. Mirrors `PriceRepository.fetchPrices`'s "a source that fails is simply
/// omitted": any reference that isn't loaded, or isn't in the same currency, is left out of the
/// comparison rather than blocking the verdict.
enum DealVerdictCalculator {
    static func evaluate(
        priceSeen: Decimal,
        storeAmount: Double?,
        storeCurrency: String?,
        quotes: [PriceQuote],
        currency: String = "EUR"
    ) -> DealVerdictResult? {
        var comparisons: [DealComparison] = []

        if let storeAmount, storeAmount > 0, (storeCurrency ?? currency) == currency {
            comparisons.append(makeComparison(
                label: "lego.com (officiel)",
                reference: Decimal(storeAmount),
                priceSeen: priceSeen
            ))
        }

        for source in [PriceSource.bricklinkNew, .amazon, .bricklinkUsed] {
            guard let quote = quotes.first(where: { $0.source == source }), quote.currency == currency else { continue }
            comparisons.append(makeComparison(label: source.displayName, reference: quote.amount, priceSeen: priceSeen))
        }

        guard !comparisons.isEmpty else { return nil }

        let verdict: DealVerdict
        if comparisons.allSatisfy({ $0.percent < 0 }) {
            verdict = .good
        } else if comparisons.allSatisfy({ $0.percent > 0 }) {
            verdict = .bad
        } else {
            verdict = .fair
        }

        return DealVerdictResult(verdict: verdict, comparisons: comparisons)
    }

    private static func makeComparison(label: String, reference: Decimal, priceSeen: Decimal) -> DealComparison {
        let difference = priceSeen - reference
        let referenceDouble = (reference as NSDecimalNumber).doubleValue
        let differenceDouble = (difference as NSDecimalNumber).doubleValue
        let percent = referenceDouble != 0 ? Int(((differenceDouble / referenceDouble) * 100).rounded()) : 0
        return DealComparison(label: label, referenceAmount: reference, differenceAmount: difference, percent: percent)
    }
}
