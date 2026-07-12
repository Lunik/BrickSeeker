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

    /// Shown when a lookup can't be resolved because there's no Rebrickable API key configured
    /// and the offline catalogue doesn't have this set either (ScannerViewModel.resolveSet
    /// treats "no API key" like "no network" — see its own doc comment).
    static var missingAPIKey: String {
        String(localized: "Clé API Rebrickable manquante. Ajoutez-la dans les réglages pour identifier ce set.")
    }
}

/// Builds a French-correct singular/plural sentence for a bulk set count (#155) — several bulk
/// actions (History/Collection/Wishlist/batch scan) used to interpolate a literal "set(s)" and a
/// plural verb even when `count == 1`, e.g. "1 set(s) n'ont pas pu être ajoutés". `singular`/
/// `plural` are the rest of the sentence after "1 set …" / "N sets …".
func setsCountSentence(_ count: Int, singular: String, plural: String) -> String {
    count == 1 ? String(localized: "1 set \(singular)") : String(localized: "\(count) sets \(plural)")
}
