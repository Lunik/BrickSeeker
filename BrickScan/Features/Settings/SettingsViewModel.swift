import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class SettingsViewModel {
    var apiKey: String
    var username = ""
    var password = ""
    var isLinkingAccount = false
    var linkAccountErrorMessage: String?
    var isAccountLinked: Bool

    var isUpdatingOfflineCatalog = false
    var offlineCatalogDownloadProgress: Double = 0
    var offlineCatalogErrorMessage: String?
    var offlineCatalogMetadata: OfflineCatalogStore.Metadata?

    private let offlineCatalogStore: OfflineCatalogStore
    /// Set right before `cancelActiveDownloadPreservingProgress()` so the resulting
    /// `.networkUnavailable` thrown back into `downloadOfflineCatalog()` is recognized as a
    /// deliberate pause (app backgrounding) rather than a real connectivity failure, and shown
    /// with reassuring copy instead of an error.
    private var pausedForBackgrounding = false

    private let repository: RebrickableRepositoryProtocol

    init(
        repository: RebrickableRepositoryProtocol = RebrickableRepository(),
        offlineCatalogStore: OfflineCatalogStore = .shared
    ) {
        self.apiKey = KeychainService.shared.load(key: .apiKey) ?? ""
        self.isAccountLinked = KeychainService.shared.load(key: .userToken) != nil
        self.repository = repository
        self.offlineCatalogStore = offlineCatalogStore
        self.offlineCatalogMetadata = offlineCatalogStore.metadata
    }

    var hasResumableOfflineCatalogDownload: Bool {
        offlineCatalogStore.hasResumableDownload
    }

    func downloadOfflineCatalog() async {
        isUpdatingOfflineCatalog = true
        offlineCatalogDownloadProgress = 0
        offlineCatalogErrorMessage = nil
        pausedForBackgrounding = false
        defer { isUpdatingOfflineCatalog = false }

        do {
            try await offlineCatalogStore.download { [weak self] value in
                self?.offlineCatalogDownloadProgress = value
            }
            offlineCatalogMetadata = offlineCatalogStore.metadata
        } catch let error as APIError {
            if pausedForBackgrounding {
                offlineCatalogErrorMessage = String(localized: "Téléchargement interrompu — il reprendra où il s'est arrêté à la prochaine ouverture.")
            } else {
                offlineCatalogErrorMessage = error.errorDescription
            }
        } catch {
            offlineCatalogErrorMessage = String(localized: "Téléchargement impossible. Vérifiez votre réseau.")
        }
    }

    /// Called from `SettingsView`'s `scenePhase` observer when the app stops being active. If a
    /// download is in flight, pauses it so its resume data is preserved instead of being lost to
    /// the app suspending/terminating mid-transfer (see `OfflineCatalogStore.
    /// cancelActiveDownloadPreservingProgress`).
    func handleScenePhaseChange(isActive: Bool) {
        guard !isActive else { return }
        if isUpdatingOfflineCatalog {
            pausedForBackgrounding = true
            offlineCatalogStore.cancelActiveDownloadPreservingProgress()
        }
        if CollectionPriceUpdater.shared.isRunning {
            CollectionPriceUpdater.shared.cancelPreservingProgress()
        }
    }

    func purgeOfflineCatalog() {
        offlineCatalogStore.purge()
        offlineCatalogMetadata = nil
    }

    func save() {
        KeychainService.shared.save(key: .apiKey, value: apiKey)
    }

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
            isAccountLinked = true
            return true
        } catch let error as APIError {
            linkAccountErrorMessage = error.errorDescription
            password = ""
            return false
        } catch {
            linkAccountErrorMessage = String(localized: "Connexion impossible. Vérifiez votre réseau.")
            password = ""
            return false
        }
    }

    func unlinkAccount() {
        KeychainService.shared.delete(key: .userToken)
        isAccountLinked = false
    }
}
