import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case forbidden
    case notFound
    case serverError(Int)
    case decodingError(Error)
    case networkUnavailable
    case rateLimited
    case missingCredentials
    case unknown
    /// Brickset's API replies HTTP 200 on both success and failure — the outcome lives in the
    /// JSON envelope's `status`/`message` fields, not the HTTP status code like Rebrickable, so
    /// its failures can't be mapped onto the HTTP-code-driven cases above. Carries Brickset's
    /// own (English) message since its error vocabulary isn't documented/stable enough to map
    /// onto fixed French strings without risking silently mislabeling a different failure.
    case bricksetError(String)
    /// BrickLink's API replies HTTP 200 even on failure (confirmed live: a `TOKEN_IP_MISMATCHED`
    /// auth error came back as HTTP 200) — like Brickset, the real outcome is `meta.code` in the
    /// JSON envelope, not the HTTP status. Carries BrickLink's own `meta.description`/`message`
    /// since, same reasoning as `bricksetError`, its error vocabulary isn't stable enough to map
    /// onto fixed French strings without risking mislabeling a different failure.
    case bricklinkError(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "API Key invalide")
        case .forbidden:
            return String(localized: "Nom d'utilisateur ou mot de passe incorrect")
        case .notFound:
            return String(localized: "Ressource introuvable")
        case .serverError(let code):
            return String(localized: "Erreur serveur (\(code))")
        case .decodingError:
            return String(localized: "Erreur lors du traitement de la réponse")
        case .networkUnavailable:
            return String(localized: "Connexion impossible. Vérifiez votre réseau.")
        case .rateLimited:
            return String(localized: "Trop de requêtes, veuillez réessayer plus tard")
        case .missingCredentials:
            return String(localized: "Identifiants manquants")
        case .unknown:
            return String(localized: "Une erreur inconnue est survenue")
        case .bricksetError(let message):
            return String(localized: "Erreur Brickset : \(message)")
        case .bricklinkError(let message):
            return String(localized: "Erreur BrickLink : \(message)")
        }
    }
}
