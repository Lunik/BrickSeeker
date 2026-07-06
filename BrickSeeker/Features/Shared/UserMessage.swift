import Foundation

/// User-facing messages built in view models (not SwiftUI view literals, which localize
/// themselves through `LocalizedStringKey`). One definition — and one String Catalog key — per
/// message, instead of the copy-per-call-site the review found: the offline-status message
/// alone existed in 3 identical copies (#79).
enum UserMessage {
    /// Shown as the collection status of a set identified via the offline catalogue.
    static var offlineStatusAndPrices: String {
        String(localized: "Hors-ligne — statut collection et prix à rafraîchir une fois reconnecté")
    }

    /// Shown when only the collection-status check (not the whole lookup) happened offline.
    static var offlineStatus: String {
        String(localized: "Hors-ligne — statut collection à rafraîchir une fois reconnecté")
    }

    static var unknownCollectionStatus: String {
        String(localized: "Statut de collection inconnu")
    }

    static var unknownError: String {
        String(localized: "Erreur inconnue")
    }
}
