import SwiftUI

/// Single source of truth for how a `StoreAvailabilityStatus` is *shown* — the SetDetail badge
/// next to the lego.com price (`SetDetailView.availabilityBadge`) and the "Disponibilité" filter
/// picker (`SetFilterSheet`, #226) must use the same icon/colour/wording, or the filter and the
/// set sheet end up describing the same lego.com state in two different vocabularies.
extension StoreAvailabilityStatus {
    /// `nil` for `.unknown`: "no information yet" has no meaningful icon next to a price (the
    /// badge deliberately shows nothing there), while the *filter* row does need one — see
    /// `pickerSystemImage`.
    var systemImage: String? {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .outOfStock: return "exclamationmark.triangle.fill"
        case .retired: return "archivebox.fill"
        case .unknown: return nil
        }
    }

    var tint: Color {
        switch self {
        case .available: return .green
        case .outOfStock: return .orange
        case .retired, .unknown: return .secondary
        }
    }

    /// Wording shared by the badge's VoiceOver label and the filter picker row.
    var label: LocalizedStringKey {
        switch self {
        case .available: return "Disponible à l'achat"
        case .outOfStock: return "Rupture de stock"
        case .retired: return "Retiré de la vente"
        case .unknown: return "Inconnue"
        }
    }

    /// Same icons as `systemImage`, with an explicit one for `.unknown` — in a picker every row
    /// needs a symbol, and "not checked yet" is a real, selectable choice there (#226).
    var pickerSystemImage: String {
        systemImage ?? "questionmark.circle"
    }
}
