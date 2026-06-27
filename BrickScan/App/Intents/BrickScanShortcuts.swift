import AppIntents

struct BrickScanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckSetPriceIntent(),
            phrases: [
                "Vérifie le prix d'un set LEGO sur \(.applicationName)",
                "Quel est le prix d'un set LEGO sur \(.applicationName)"
            ],
            shortTitle: "Prix d'un set LEGO",
            systemImageName: "tag"
        )
    }
}
