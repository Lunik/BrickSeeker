import Foundation
import Security

enum KeychainKey: String {
    case apiKey = "rebrickable_api_key"
    case userToken = "rebrickable_user_token"
    case bricksetApiKey = "brickset_api_key"
    case bricksetUserHash = "brickset_user_hash"
    case bricklinkConsumerKey = "bricklink_consumer_key"
    case bricklinkConsumerSecret = "bricklink_consumer_secret"
    case bricklinkToken = "bricklink_token"
    case bricklinkTokenSecret = "bricklink_token_secret"
}

final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()

    private init() {}

    func save(key: KeychainKey, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func load(key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: KeychainKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    var hasAPIKey: Bool {
        load(key: .apiKey) != nil
    }

    var hasUserToken: Bool {
        load(key: .userToken) != nil
    }

    var hasBricksetUserHash: Bool {
        load(key: .bricksetUserHash) != nil
    }

    /// All four OAuth 1.0a values, or `nil` if any is missing/empty — BrickLink signing requires
    /// the full set, there's no partial-credentials mode.
    var brickLinkOAuth1Credentials: BrickLinkOAuth1Credentials? {
        guard let consumerKey = load(key: .bricklinkConsumerKey), !consumerKey.isEmpty,
              let consumerSecret = load(key: .bricklinkConsumerSecret), !consumerSecret.isEmpty,
              let token = load(key: .bricklinkToken), !token.isEmpty,
              let tokenSecret = load(key: .bricklinkTokenSecret), !tokenSecret.isEmpty else {
            return nil
        }
        return BrickLinkOAuth1Credentials(
            consumerKey: consumerKey, consumerSecret: consumerSecret, token: token, tokenSecret: tokenSecret
        )
    }

    func clearAll() {
        delete(key: .apiKey)
        delete(key: .userToken)
        delete(key: .bricksetApiKey)
        delete(key: .bricksetUserHash)
        delete(key: .bricklinkConsumerKey)
        delete(key: .bricklinkConsumerSecret)
        delete(key: .bricklinkToken)
        delete(key: .bricklinkTokenSecret)
    }
}
