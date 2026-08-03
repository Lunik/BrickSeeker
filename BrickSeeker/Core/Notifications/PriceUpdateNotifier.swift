import Foundation
import Observation
import UserNotifications

/// Posts the app's local notifications: the one-shot "the batch you started just finished" ping,
/// and the price-drop alerts of #229.
///
/// The second kind is proactive, which #5 had explicitly ruled out ("pas d'alertes proactives",
/// `UNUserNotificationCenter` named in its "à ne PAS faire" list). #229 reverses that deliberately
/// and on a much narrower footing: an alert only ever exists because the user typed a threshold on
/// a specific set, and it only fires on a genuine downward crossing of that threshold (see
/// `PriceAlertEvaluator`).
enum PriceUpdateNotifier {
    private static let identifier = "com.lunik.brickseeker.priceBatchUpdate"
    private static let alertIdentifierPrefix = "com.lunik.brickseeker.priceAlert."
    /// `userInfo` key carrying the set a price-alert notification is about, read back by
    /// `AppDelegate`'s `didReceive` so tapping it opens that set's detail sheet.
    static let setNumUserInfoKey = "setNum"

    static func requestAuthorizationIfNeeded() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Whether the user has actually granted notification permission — price alerts are useless
    /// without it, so the alert UI says so rather than silently never firing.
    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Reuses a fixed identifier so a later run's notification replaces this one in
    /// Notification Center instead of stacking duplicates.
    static func notifyCompleted(total: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Prix mis à jour")
        content.body = total > 1
            ? String(localized: "Les prix de \(total) sets de votre collection ont été actualisés.")
            : String(localized: "Les prix de \(total) set de votre collection ont été actualisés.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// One price-drop alert. Unlike `notifyCompleted`, the identifier is **per set and condition**:
    /// the fixed identifier above is right for "the job finished" (a later run genuinely supersedes
    /// the earlier one) and disastrous here, where each alert is about a different set and replacing
    /// the previous one would silently swallow every alert but the last.
    static func notifyPriceAlert(
        setNum: String,
        setName: String,
        condition: ListCondition,
        price: Double,
        threshold: Double
    ) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Baisse de prix : \(setNum.baseSetNum)")
        content.body = String(
            localized: "\(setName) — \(formatted(price)) en \(condition.displayName.lowercased()), sous votre seuil de \(formatted(threshold))."
        )
        content.sound = .default
        content.userInfo = [setNumUserInfoKey: setNum]
        let request = UNNotificationRequest(
            identifier: alertIdentifierPrefix + PriceAlert.key(setNum: setNum, condition: condition),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func formatted(_ amount: Double) -> String {
        Decimal(amount).formatted(.currency(code: "EUR").locale(Locale(identifier: "fr_FR")))
    }
}

/// Holds the set a tapped price-alert notification points at, until `HomeView` is ready to open it.
/// Same shape and reasoning as `ShortcutCenter`: `AppDelegate` runs long before the view tree
/// exists on a cold launch, and re-foregrounding the app must not replay a stale tap.
@Observable
@MainActor
final class PriceAlertRouter {
    static let shared = PriceAlertRouter()

    var pendingSetNum: String?

    private init() {}
}
