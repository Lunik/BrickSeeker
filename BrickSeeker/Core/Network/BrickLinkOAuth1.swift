import Foundation
import CryptoKit

/// The four values BrickLink issues together from a developer's own "API Keys" page
/// (bricklink.com/v3/api.page → Register/Manage a Consumer) — these are the *user's own*
/// BrickLink account credentials, not an app-embedded secret, so storing them in the
/// device Keychain (see `KeychainService`) is the compliant provisional home while #110
/// (a backend to host true app-level secrets) doesn't exist yet.
struct BrickLinkOAuth1Credentials: Equatable {
    let consumerKey: String
    let consumerSecret: String
    let token: String
    let tokenSecret: String
}

/// Signs BrickLink Store API requests per OAuth 1.0a (RFC 5849) with HMAC-SHA1 — BrickLink's
/// only supported signature method, and no OAuth 2 / static-header option exists (unlike
/// Rebrickable's `Authorization: key {API_KEY}` or Brickset's apiKey/userHash params). Built on
/// CryptoKit rather than a third-party OAuth library, per this app's no-dependencies rule.
enum BrickLinkOAuth1 {
    /// Builds the `Authorization` header value for a request. `queryItems` must list every
    /// query-string parameter that will actually be sent — they're part of the OAuth signature
    /// base string (RFC 5849 §3.4.1), so signing then appending *different* query items than
    /// what's signed produces an invalid signature BrickLink will reject with 401.
    static func authorizationHeader(
        method: String,
        url: URL,
        queryItems: [URLQueryItem],
        credentials: BrickLinkOAuth1Credentials,
        nonce: String = UUID().uuidString,
        timestamp: String = String(Int(Date().timeIntervalSince1970))
    ) -> String {
        var oauthParams = [
            "oauth_consumer_key": credentials.consumerKey,
            "oauth_nonce": nonce,
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": timestamp,
            "oauth_token": credentials.token,
            "oauth_version": "1.0"
        ]

        let requestParams = Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let signatureBaseString = Self.signatureBaseString(
            method: method,
            url: url,
            allParams: oauthParams.merging(requestParams, uniquingKeysWith: { a, _ in a })
        )
        let signingKey = "\(percentEncode(credentials.consumerSecret))&\(percentEncode(credentials.tokenSecret))"
        oauthParams["oauth_signature"] = hmacSHA1(message: signatureBaseString, key: signingKey)

        let headerParams = oauthParams
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\"\(percentEncode($0.value))\"" }
            .joined(separator: ", ")
        return "OAuth \(headerParams)"
    }

    /// RFC 5849 §3.4.1.1: method, base URL (no query), and every param (OAuth + request) sorted
    /// and percent-encoded, each joined with `&`, concatenated with `&` between the three parts.
    private static func signatureBaseString(method: String, url: URL, allParams: [String: String]) -> String {
        let encodedPairs: [(String, String)] = allParams.map { (percentEncode($0.key), percentEncode($0.value)) }
        let sortedPairs = encodedPairs.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let normalizedParams = sortedPairs.map { pair -> String in
            let (key, value) = pair
            return "\(key)=\(value)"
        }.joined(separator: "&")

        let baseURLString = url.absoluteString.components(separatedBy: "?").first ?? url.absoluteString
        return [method.uppercased(), percentEncode(baseURLString), percentEncode(normalizedParams)].joined(separator: "&")
    }

    private static func hmacSHA1(message: String, key: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(code).base64EncodedString()
    }

    /// RFC 3986 unreserved characters only (RFC 5849 §3.6) — stricter than
    /// `addingPercentEncoding`'s built-in character sets, which leave `+`/`*`/`!` unescaped.
    private static func percentEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
