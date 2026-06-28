import SwiftUI

/// One of LEGO's three primary brand colors, selectable in Settings. Each comes with a
/// stronger variant (links/CTAs) and a soft tint (badges/highlights), matching the
/// "BrickScan — Identité LEGO" design tokens.
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

    var accentStrong: Color {
        switch self {
        case .red: Color(hex: "C20812")
        case .yellow: Color(hex: "8F5E00")
        case .blue: Color(hex: "00568F")
        }
    }

    var accentSoft: Color {
        switch self {
        case .red: Color(hex: "FBE3E3")
        case .yellow: Color(hex: "FCEFC9")
        case .blue: Color(hex: "DBEAF6")
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
    }

    var brandColor: BrandColor {
        didSet { UserDefaults.standard.set(brandColor.rawValue, forKey: Keys.brandColor) }
    }

    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }

    private init() {
        let defaults = UserDefaults.standard
        brandColor = BrandColor(rawValue: defaults.string(forKey: Keys.brandColor) ?? "") ?? .red
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system
    }

    var accent: Color { brandColor.accent }
    var accentStrong: Color { brandColor.accentStrong }
    var accentSoft: Color { brandColor.accentSoft }
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
