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
            return "API Key invalide"
        case .forbidden:
            return "Nom d'utilisateur ou mot de passe incorrect"
        case .notFound:
            return "Ressource introuvable"
        case .serverError(let code):
            return "Erreur serveur (\(code))"
        case .decodingError:
            return "Erreur lors du traitement de la réponse"
        case .networkUnavailable:
            return "Connexion impossible. Vérifiez votre réseau."
        case .rateLimited:
            return "Trop de requêtes, veuillez réessayer plus tard"
        case .missingCredentials:
            return "Identifiants manquants"
        case .unknown:
            return "Une erreur inconnue est survenue"
        }
    }
}
