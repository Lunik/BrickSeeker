import UserNotifications

/// Posts the single local notification fired when `CollectionPriceUpdater` finishes a
/// full pass over the collection. This is a one-shot "the job you started just
/// finished" ping, not a proactive/periodic alert — see AGENTS.md and issue #5 for why
/// this app deliberately avoids the latter.
enum PriceUpdateNotifier {
    private static let identifier = "com.lunik.brickscan.priceBatchUpdate"

    static func requestAuthorizationIfNeeded() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
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
}
