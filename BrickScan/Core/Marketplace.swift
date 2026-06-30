import Foundation
import SwiftUI

/// A supported price marketplace: Amazon domain, lego.com locale, and the native currency.
enum Marketplace: String, CaseIterable, Identifiable {
    case fr, de, gb, us

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fr: "France (EUR)"
        case .de: "Allemagne (EUR)"
        case .gb: "Royaume-Uni (GBP)"
        case .us: "États-Unis (USD)"
        }
    }

    var amazonDomain: String {
        switch self {
        case .fr: "amazon.fr"
        case .de: "amazon.de"
        case .gb: "amazon.co.uk"
        case .us: "amazon.com"
        }
    }

    /// The locale path segment used on lego.com (e.g. "fr-fr", "de-de").
    var legoLocale: String {
        switch self {
        case .fr: "fr-fr"
        case .de: "de-de"
        case .gb: "en-gb"
        case .us: "en-us"
        }
    }

    var currency: String {
        switch self {
        case .fr: "EUR"
        case .de: "EUR"
        case .gb: "GBP"
        case .us: "USD"
        }
    }

    /// JavaScript regex pattern (no delimiters) that rejects third-party accessories
    /// (LED kits, "compatible" listings) from Amazon search results.
    /// Each market has locale-specific wording — must stay strict to avoid matching
    /// LED kits as the genuine set (regression fixed in prior commits).
    var amazonRejectPattern: String {
        switch self {
        case .fr:
            // French: "compatible avec", "pour LEGO", "éclairage"/"eclairage", LED, "non inclus", "pas inclus", "sans la", known brands
            return #"compatible|pour lego|for lego|éclairage|eclairage|\bled\b|lighting|non inclus|not included|pas inclus|sans la|briksmax|vonado|lightailing"#
        case .de:
            // German: "kompatibel", "für LEGO", "Beleuchtung", LED, "nicht enthalten", "ohne", known brands
            return #"kompatibel|für lego|for lego|beleuchtung|\bled\b|lighting|nicht enthalten|without|ohne|briksmax|vonado|lightailing"#
        case .gb, .us:
            // English: "compatible", "for LEGO", lighting/LED, "not included", "without", known brands
            return #"compatible|for lego|lighting|\bled\b|not included|without|briksmax|vonado|lightailing"#
        }
    }
}

/// App-wide marketplace selection: which Amazon domain / lego.com locale / currency to use
/// for price fetching. Persisted to `UserDefaults`. Defaults to `.fr` to preserve existing
/// behaviour for existing users.
@MainActor
@Observable
final class AppMarketplace {
    static let shared = AppMarketplace()

    private enum Keys {
        static let marketplace = "appMarketplace.marketplace"
    }

    var marketplace: Marketplace {
        didSet { UserDefaults.standard.set(marketplace.rawValue, forKey: Keys.marketplace) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Keys.marketplace) ?? ""
        marketplace = Marketplace(rawValue: raw) ?? .fr
    }
}
