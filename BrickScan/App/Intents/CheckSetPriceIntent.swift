import AppIntents
import Foundation

/// Exposes the existing lookup/price pipeline (`RebrickableRepository`, `LegoStoreRepository`,
/// `PriceRepository` — all plain, SwiftUI-independent classes per `RebrickableRepositoryProtocol`'s
/// DI seam) to Siri, Shortcuts.app and Spotlight, so a price can be checked without opening the app.
struct CheckSetPriceIntent: AppIntent {
    static var title: LocalizedStringResource = "Vérifier le prix d'un set LEGO"
    static var description = IntentDescription(
        "Recherche un set LEGO par son numéro et compare son prix entre lego.com, BrickLink et Amazon."
    )

    @Parameter(title: "Numéro de set", requestValueDialog: "Quel est le numéro du set LEGO ?")
    var setNumber: String

    static var parameterSummary: some ParameterSummary {
        Summary("Vérifier le prix du set \(\.$setNumber)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard KeychainService.shared.hasAPIKey else {
            return .result(
                dialog: IntentDialog("Configurez d'abord votre clé API Rebrickable dans BrickScan (Réglages).")
            )
        }

        let repository: RebrickableRepositoryProtocol = RebrickableRepository()
        do {
            let resolution = try await repository.resolveSet(setNum: setNumber)
            switch resolution {
            case .notFound:
                return .result(dialog: IntentDialog("Aucun set LEGO trouvé pour le numéro \(setNumber)."))
            case .ambiguous(let sets):
                let names = sets.prefix(3).map(\.name).joined(separator: ", ")
                return .result(
                    dialog: IntentDialog("Plusieurs sets correspondent à \(setNumber) : \(names). Ouvrez BrickScan pour préciser.")
                )
            case .found(let legoSet):
                let summary = await Self.priceSummary(for: legoSet)
                return .result(dialog: IntentDialog(stringLiteral: summary))
            }
        } catch let error as APIError {
            return .result(dialog: IntentDialog(stringLiteral: error.errorDescription ?? "Une erreur est survenue."))
        }
    }

    /// Mirrors the "Prix" card in `SetDetailView`: lego.com is the reference price, the scraped
    /// sources (BrickLink/Amazon, via `PriceRepository`) are reported as a `±%` delta against it —
    /// same comparison shown on-screen, just spoken/printed by Siri instead.
    private static func priceSummary(for legoSet: LegoSet) async -> String {
        async let storePriceTask: StorePrice? = try? LegoStoreRepository().fetchStorePrice(setNum: legoSet.setNum)
        async let quotesTask = PriceRepository().fetchPrices(for: legoSet)

        let storePrice = await storePriceTask
        let quotes = await quotesTask

        var parts = ["\(legoSet.name) (\(legoSet.setNum))"]

        if let amount = storePrice?.amount {
            let currency = storePrice?.currency ?? "EUR"
            parts.append("\(formatPrice(amount, currency: currency)) chez LEGO")
            for quote in quotes {
                let quoteAmount = Double(truncating: quote.amount as NSNumber)
                let deltaPercent = ((quoteAmount - amount) / amount) * 100
                let sign = deltaPercent >= 0 ? "+" : ""
                parts.append("\(sign)\(Int(deltaPercent.rounded())) % sur \(quote.source.displayName)")
            }
        } else if let firstQuote = quotes.first {
            let quoteAmount = Double(truncating: firstQuote.amount as NSNumber)
            parts.append("\(formatPrice(quoteAmount, currency: firstQuote.currency)) sur \(firstQuote.source.displayName)")
        } else {
            parts.append("prix indisponible pour le moment")
        }

        return parts.joined(separator: " : ")
    }

    private static func formatPrice(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
    }
}

/// Registers the Siri/Shortcuts/Spotlight phrases for `CheckSetPriceIntent`. Each phrase must embed
/// `\(.applicationName)` per App Intents' requirements.
struct BrickScanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckSetPriceIntent(),
            phrases: [
                "Vérifie le prix d'un set LEGO avec \(.applicationName)",
                "Quel est le prix de ce set LEGO sur \(.applicationName)",
                "Check le prix LEGO sur \(.applicationName)"
            ],
            shortTitle: "Prix d'un set LEGO",
            systemImageName: "tag"
        )
    }
}
