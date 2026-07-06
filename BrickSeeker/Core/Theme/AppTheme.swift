import SwiftUI

/// One of LEGO's three primary brand colors, selectable in Settings, matching the
/// "BrickSeeker — Identité LEGO" design tokens.
enum BrandColor: String, CaseIterable, Identifiable {
    case red, yellow, blue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .red: "Rouge"
        case .yellow: "Jaune"
        case .blue: "Bleu"
        }
    }

    var accent: Color {
        switch self {
        case .red: Color(hex: "E3000B")
        case .yellow: Color(hex: "F7B500")
        case .blue: Color(hex: "006DB7")
        }
    }

}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "Système"
        case .light: "Clair"
        case .dark: "Sombre"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// App-wide color theme: brand color (red/yellow/blue) and light/dark/system appearance,
/// both persisted to `UserDefaults` and applied from the app root via `.tint` and
/// `.preferredColorScheme`.
@MainActor
@Observable
final class AppTheme {
    static let shared = AppTheme()

    private enum Keys {
        static let brandColor = "appTheme.brandColor"
        static let appearanceMode = "appTheme.appearanceMode"
        static let preferredPricePerPart = "appTheme.preferredPricePerPart"
    }

    static let defaultPreferredPricePerPart: Double = 0.12

    var brandColor: BrandColor {
        didSet { UserDefaults.standard.set(brandColor.rawValue, forKey: Keys.brandColor) }
    }

    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }

    /// Target €/pièce the user considers a good deal. Used in SetDetailView to colour-code
    /// the price-per-part row. Defaults to 0.12 €/pièce (industry rule of thumb).
    var preferredPricePerPart: Double {
        didSet { UserDefaults.standard.set(preferredPricePerPart, forKey: Keys.preferredPricePerPart) }
    }

    private init() {
        let defaults = UserDefaults.standard
        brandColor = BrandColor(rawValue: defaults.string(forKey: Keys.brandColor) ?? "") ?? .red
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system
        let stored = defaults.double(forKey: Keys.preferredPricePerPart)
        preferredPricePerPart = stored > 0 ? stored : Self.defaultPreferredPricePerPart
    }

    var accent: Color { brandColor.accent }
    var colorScheme: ColorScheme? { appearanceMode.colorScheme }
}

extension Color {
    /// LEGO stud yellow — fixed regardless of the selected brand color, used for scanning/
    /// processing highlights.
    static let brickStud = Color(hex: "FFCF00")
    /// Fixed destructive/error red, independent of the selected brand color so error states
    /// stay recognizable even when the brand color is itself red.
    static let brickDanger = Color(hex: "D11A2A")
}
