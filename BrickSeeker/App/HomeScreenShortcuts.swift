import UIKit
import Observation
import UserNotifications

/// Routes a Home Screen Quick Action (long-press on the app icon) to the entry point it mirrors.
enum HomeScreenShortcut: String {
    case scan = "com.lunik.brickseeker.scan"
    case manualEntry = "com.lunik.brickseeker.manualEntry"
    case photo = "com.lunik.brickseeker.photo"
}

/// Holds the shortcut requested by the user until `BrickSeekerApp` is ready to act on it and clears
/// it once consumed, so re-foregrounding the app doesn't replay a stale action.
@Observable
@MainActor
final class ShortcutCenter {
    static let shared = ShortcutCenter()

    var pendingShortcut: HomeScreenShortcut?

    private init() {}
}

/// SwiftUI's `App` protocol has no hook for `UIApplicationShortcutItem`s, so a minimal
/// `UIApplicationDelegate` captures both delivery paths.
final class AppDelegate: NSObject, UIApplicationDelegate {
    // Wires up notification delegation once at launch so `PriceUpdateNotifier`'s completion
    // notification still shows a banner if the batch finishes while the app is foreground —
    // by default iOS suppresses foreground banners unless a delegate opts in via `willPresent`.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Cold launch: even without a custom Info.plist scene manifest, UIKit launches SwiftUI apps
    // through the scene-connection path — `application(_:didFinishLaunchingWithOptions:)`'s
    // `.shortcutItem` launch option is never populated here, only
    // `UIScene.ConnectionOptions.shortcutItem` is.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            handle(shortcutItem)
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    // App already running in the background.
    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        handle(shortcutItem)
        completionHandler(true)
    }

    private func handle(_ shortcutItem: UIApplicationShortcutItem) {
        guard let shortcut = HomeScreenShortcut(rawValue: shortcutItem.type) else { return }
        Task { @MainActor in
            ShortcutCenter.shared.pendingShortcut = shortcut
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
