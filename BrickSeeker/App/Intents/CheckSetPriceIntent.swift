import AppIntents

/// Lets Siri/Shortcuts/Spotlight check a LEGO set's price without opening the app, calling
/// straight into the same Core/ repositories the UI uses (RebrickableRepositoryProtocol,
/// LegoStoreRepository, PriceRepository) — no view model involved, none of them depend on SwiftUI.
struct CheckSetPriceIntent: AppIntent {
    static let title: LocalizedStringResource = "Vérifier le prix d'un set LEGO"
    static let description = IntentDescription(
        "Recherche le prix d'un set LEGO sur lego.com, BrickLink, Amazon et Cdiscount sans ouvrir BrickSeeker."
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Numéro de set")
    var setNumber: String

    static var parameterSummary: some ParameterSummary {
        Summary("Vérifier le prix du set LEGO \(\.$setNumber)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard KeychainService.shared.hasAPIKey else {
            return .result(
                dialog: "Aucune clé API Rebrickable configurée. Ouvre BrickSeeker et renseigne-la dans Réglages."
            )
        }

        let resolution = try await RebrickableRepository().resolveSet(setNum: setNumber)

        let legoSet: LegoSet
        switch resolution {
        case .found(let set):
            legoSet = set
        case .ambiguous:
            return .result(dialog: "Plusieurs sets correspondent à \(setNumber), ouvre BrickSeeker pour préciser.")
        case .notFound:
            return .result(dialog: "Aucun set LEGO trouvé pour \(setNumber).")
        }

        async let storePrice = try? LegoStoreRepository().fetchStorePrice(setNum: legoSet.setNum)
        async let scrapedQuotes = PriceRepository().fetchPrices(for: legoSet)

        let dialog = Self.buildDialog(legoSet: legoSet, storePrice: await storePrice, quotes: await scrapedQuotes)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    private static func buildDialog(legoSet: LegoSet, storePrice: StorePrice?, quotes: [PriceQuote]) -> String {
        let bestQuote = quotes.min(by: { $0.amount < $1.amount })

        guard let storeAmount = storePrice?.amount else {
            guard let bestQuote else {
                return "\(legoSet.setNum) : prix indisponible, réessaie dans l'app."
            }
            let price = formatPrice(NSDecimalNumber(decimal: bestQuote.amount).doubleValue, currency: bestQuote.currency)
            return "\(legoSet.setNum) : indisponible chez LEGO, \(price) sur \(bestQuote.source.displayName)"
        }

        let storeText = formatPrice(storeAmount, currency: storePrice?.currency ?? "EUR")
        guard let bestQuote else {
            return "\(legoSet.setNum) : \(storeText) chez LEGO"
        }

        let bestAmount = NSDecimalNumber(decimal: bestQuote.amount).doubleValue
        let delta = (bestAmount - storeAmount) / storeAmount * 100
        let sign = delta > 0 ? "+" : ""
        return "\(legoSet.setNum) : \(storeText) chez LEGO, \(sign)\(Int(delta.rounded()))% sur \(bestQuote.source.displayName)"
    }

    private static func formatPrice(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
    }
}
