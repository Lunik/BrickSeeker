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
        }
    }
}
