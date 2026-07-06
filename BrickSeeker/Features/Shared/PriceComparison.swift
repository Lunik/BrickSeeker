import Foundation

/// The "±% versus the official lego.com price" arithmetic shared by `SetDetailView`'s per-row
/// promo hint and `BatchScanItem.dealPercent`'s batch ranking.
enum PriceComparison {
    /// Rounded percentage gap between a quote and the store price. `nil` when there's no usable
    /// store price or the currencies differ (comparing across currencies would be meaningless).
    /// A 0% result is returned as 0, not nil — display call sites decide whether to hide it.
    static func percentVsStore(
        amount: Decimal,
        currency: String,
        storeAmount: Double?,
        storeCurrency: String?
    ) -> Int? {
        guard let storeAmount, storeAmount > 0, (storeCurrency ?? "EUR") == currency else { return nil }
        let source = (amount as NSDecimalNumber).doubleValue
        return Int((((source - storeAmount) / storeAmount) * 100).rounded())
    }
}
