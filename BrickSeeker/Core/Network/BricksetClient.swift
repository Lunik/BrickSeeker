import Foundation

/// Dedicated client for the Brickset v3 API — separate from `NetworkClient` since Brickset is a
/// different host with a different auth shape (apiKey + userHash as request params, not a header)
/// and a different error protocol (always HTTP 200; the outcome is the JSON envelope's own
/// `status`/`message` — see `BricksetResponse`).
final class BricksetClient: @unchecked Sendable {
    static let shared = BricksetClient()

    private let baseURL = BricksetEndpoint.baseURL
    private let session: URLSession
    // Its own throttler instance (not `RequestThrottler.shared`, which Rebrickable calls use) —
    // Brickset and Rebrickable are unrelated hosts with independent rate limits, so bursts of
    // traffic to one shouldn't needlessly slow down the other. 1s minimum: the wishlist mass
    // import fires a getSets+setCollection pair per set, and 0.2s between them reliably drew an
    // HTTP 429 from Brickset (confirmed live during a CSV import test).
    private let throttler = RequestThrottler(minimumInterval: 1.0)

    /// A 429 this far out already went through `maxRetries` waits — bailing out here instead of
    /// retrying forever protects a long-running mass import from turning one throttled host into
    /// an infinite loop.
    private let maxRetries = 2

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Calls a Brickset method and returns its decoded envelope, or throws. `params` are method-
    /// specific form fields (e.g. `username`/`password` for login, `SetID`/`params` for
    /// setCollection) — `apiKey`/`userHash` are added automatically.
    func call(
        _ path: String,
        apiKey: String,
        userHash: String? = nil,
        params: [String: String] = [:]
    ) async throws -> BricksetResponse {
        try await call(path, apiKey: apiKey, userHash: userHash, params: params, retriesLeft: maxRetries)
    }

    private func call(
        _ path: String,
        apiKey: String,
        userHash: String?,
        params: [String: String],
        retriesLeft: Int
    ) async throws -> BricksetResponse {
        await throttler.waitIfNeeded()

        var body = params
        body["apiKey"] = apiKey
        if let userHash {
            body["userHash"] = userHash
        }

        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodeFormBody(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError {
                throw CancellationError()
            }
            throw APIError.networkUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkUnavailable
        }
        if httpResponse.statusCode == 429 {
            // The 429 itself comes from Cloudflare sitting in front of brickset.com, not Brickset's
            // own app (confirmed live: `Server: cloudflare`) — and Cloudflare sends a `Retry-After`
            // header (plain integer seconds, e.g. "15") telling us exactly when it'll let requests
            // through again. Honor it instead of guessing, but only up to `maxRetries` times so a
            // misbehaving/very large value can't stall an import indefinitely.
            if retriesLeft > 0, let retryAfter = Self.retryDelay(from: httpResponse) {
                // A touch of jitter so independent in-flight calls that all got rate-limited at
                // the same moment don't wake up and retry in lockstep, tripping the same limit
                // again (seen live with a burst of concurrent requests).
                let jitter = TimeInterval.random(in: 0...1.5)
                try await Task.sleep(nanoseconds: UInt64((retryAfter + jitter) * 1_000_000_000))
                return try await call(path, apiKey: apiKey, userHash: userHash, params: params, retriesLeft: retriesLeft - 1)
            }
            throw APIError.bricksetError(String(localized: "Trop de requêtes, réessaie dans un instant."))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.networkUnavailable
        }

        let envelope: BricksetResponse
        do {
            envelope = try JSONDecoder().decode(BricksetResponse.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }

        guard envelope.status == "success" else {
            throw APIError.bricksetError(envelope.message ?? String(localized: "Erreur inconnue"))
        }
        return envelope
    }

    /// Parses `Retry-After` as either the plain integer-seconds form Cloudflare actually sends, or
    /// the HTTP-date form the spec also allows (RFC 9110 §10.2.3) — capped at 60s so a header value
    /// we don't expect can't stall a caller for an unreasonable amount of time.
    private static func retryDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) {
            return min(seconds, 60)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return min(max(0, date.timeIntervalSinceNow), 60)
    }

    private static func encodeFormBody(_ params: [String: String]) -> Data {
        let pairs = params.map { key, value -> String in
            let allowed = CharacterSet.alphanumerics
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
