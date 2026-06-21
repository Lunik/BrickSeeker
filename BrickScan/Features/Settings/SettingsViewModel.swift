import Foundation
import Observation

@Observable
final class SettingsViewModel {
    var apiKey: String
    var username = ""
    var password = ""
    var isLinkingAccount = false
    var linkAccountErrorMessage: String?

    private let repository: RebrickableRepositoryProtocol

    init(repository: RebrickableRepositoryProtocol = RebrickableRepository()) {
        self.apiKey = KeychainService.shared.load(key: .apiKey) ?? ""
        self.repository = repository
    }

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    var isAccountLinked: Bool {
        KeychainService.shared.load(key: .userToken) != nil
    }

    func save() {
        KeychainService.shared.save(key: .apiKey, value: apiKey)
    }

    @MainActor
    func linkAccount() async -> Bool {
        guard !apiKey.isEmpty, !username.isEmpty, !password.isEmpty else { return false }

        isLinkingAccount = true
        linkAccountErrorMessage = nil
        defer { isLinkingAccount = false }

        do {
            let userToken = try await repository.authenticate(apiKey: apiKey, username: username, password: password)
            KeychainService.shared.save(key: .userToken, value: userToken)
            username = ""
            password = ""
            return true
        } catch let error as APIError {
            linkAccountErrorMessage = error.errorDescription
            password = ""
            return false
        } catch {
            linkAccountErrorMessage = "Connexion impossible. Vérifiez votre réseau."
            password = ""
            return false
        }
    }

    func unlinkAccount() {
        KeychainService.shared.delete(key: .userToken)
    }
}
