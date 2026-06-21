import Foundation
import Observation

@Observable
final class SettingsViewModel {
    var apiKey: String

    init() {
        self.apiKey = KeychainService.shared.load(key: .apiKey) ?? ""
    }

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    func save() {
        KeychainService.shared.save(key: .apiKey, value: apiKey)
    }
}
