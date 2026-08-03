import Foundation
import SwiftData

/// Decides whether a `PriceAlert` should fire, and posts the notification when it should (#229).
///
/// Called from every point that persists a freshly-fetched price — `CollectionPriceUpdater`'s
/// persist closure (the collection batch, the per-selection refresh, and the background pass) and
/// `SetDetailView`'s live refreshes. It reads the just-written cache rather than taking quotes as
/// arguments, so a new price path only has to call `evaluate(setNum:in:)` once instead of threading
/// quotes/store price through to here.
@MainActor
enum PriceAlertEvaluator {
    /// Floor between two notifications for the same alert. Crossing detection alone already stops
    /// the common "still cheap" repeat; this covers a price oscillating around the threshold, which
    /// would otherwise re-cross (and re-notify) on every refresh.
    static let minimumNotificationInterval: TimeInterval = 12 * 60 * 60

    /// Evaluates both of a set's alerts (neuf and occasion are independent) against the currently
    /// cached prices. Safe to call for a set with no alert — it's a single indexed fetch that
    /// returns nothing.
    static func evaluate(setNum: String, in modelContext: ModelContext) {
        let repository = LocalRepository(modelContext: modelContext)
        let alerts = repository.priceAlerts(setNum: setNum).filter(\.isEnabled)
        guard !alerts.isEmpty else { return }

        let cached = repository.cachedSet(setNum: setNum)
        let quotes = repository.cachedPrices(setNum: setNum)

        for alert in alerts {
            evaluate(alert, storePriceEUR: cached?.storePriceEUR, quotes: quotes)
        }
        try? modelContext.save()
    }

    /// The price this alert watches, resolved through the app's **existing** chains — never a new
    /// one (#194):
    /// - `.newSet`: `resolveNewPrice` (lego.com retail → best of Amazon/Cdiscount → BrickLink neuf).
    /// - `.used`: the BrickLink occasion quote, and only that. No cross-fallback to a new price
    ///   here, unlike `resolveCollectionPrice`: an "occasion" alert that fired off a retail price
    ///   would be reporting something the user didn't ask to be told about (#229's own verification
    ///   asks for exactly the opposite).
    static func watchedPrice(
        condition: ListCondition,
        storePriceEUR: Double?,
        quotes: [PriceQuote]
    ) -> Double? {
        switch condition {
        case .newSet:
            return resolveNewPrice(storePriceEUR: storePriceEUR, quotes: quotes)
        case .used:
            return quotes.first(where: { $0.source == .bricklinkUsed })
                .map { ($0.amount as NSDecimalNumber).doubleValue }
        }
    }

    /// Mutates the alert's evaluation state and posts the notification on a genuine crossing.
    /// Does not save — the caller batches that.
    private static func evaluate(_ alert: PriceAlert, storePriceEUR: Double?, quotes: [PriceQuote]) {
        guard let threshold = alert.effectiveThresholdEUR else { return }
        // No price for this condition yet (an occasion alert on a set BrickLink has never sold, a
        // neuf alert before any source answered) — leave `wasBelowThreshold` untouched rather than
        // resetting it, so "no data" doesn't silently re-arm the crossing detector.
        guard let price = watchedPrice(condition: alert.condition, storePriceEUR: storePriceEUR, quotes: quotes) else { return }

        alert.lastObservedPriceEUR = price
        let isBelow = price <= threshold
        let wasBelow = alert.wasBelowThreshold
        alert.wasBelowThreshold = isBelow

        guard isBelow, !wasBelow else { return }
        if let lastNotifiedAt = alert.lastNotifiedAt,
           Date().timeIntervalSince(lastNotifiedAt) < minimumNotificationInterval {
            return
        }

        alert.lastNotifiedAt = Date()
        PriceUpdateNotifier.notifyPriceAlert(
            setNum: alert.setNum,
            setName: alert.setName,
            condition: alert.condition,
            price: price,
            threshold: threshold
        )
    }
}
