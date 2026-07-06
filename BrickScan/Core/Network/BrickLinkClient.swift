import Foundation

/// Dedicated client for the official BrickLink Store API (`api.bricklink.com/api/store/v1`) —
/// separate from `NetworkClient` since BrickLink uses OAuth 1.0a (a fresh HMAC-SHA1 signature per
/// request, not a static header) and its own throttling budget, same reasoning as `BricksetClient`.
///
/// Response envelope confirmed against BrickLink's official client libraries' source (the
/// interactive API docs at bricklink.com/v3/api.page are a JS app with no static reference, so
/// third-party clients' typed models are the closest thing to a spec — cross-checked against
/// multiple independent implementations, not a single source): `{ "meta": { code, message,
/// description }, "data": {...} }`. **`meta.code` is the real outcome, not necessarily the HTTP
/// status** — confirmed live: an invalid-token request came back as HTTP 200 with
/// `meta.code: 401` (`TOKEN_IP_MISMATCHED` — BrickLink's console lets you lock a token's OAuth
/// credentials to a specific IP/subnet; set both "Allowed IP" and "Mask IP" to `0.0.0.0` there to
/// disable that, since a mobile app's IP isn't stable). Same shape as `BricksetClient`'s
/// always-200 envelope, for the same reason: check `meta.code`, not just the HTTP status.
final class BrickLinkClient: @unchecked Sendable {
    static let shared = BrickLinkClient()

    private let baseURL = "https://api.bricklink.com/api/store/v1"
    private let session: URLSession
    // Own instance, not `RequestThrottler.shared` — BrickLink is an unrelated host from
    // Rebrickable, so bursts of traffic to one shouldn't throttle the other (see `BricksetClient`
    // for the same reasoning). 1s is conservative; BrickLink's documented default quota is much
    // more permissive, but this app has no need to hammer it.
    private let throttler = RequestThrottler(minimumInterval: 1.0)

    /// Same reasoning as `BricksetClient.maxRetries`: bail out after this many 429 retries
    /// instead of retrying forever, so one throttled host can't turn a collection-wide price
    /// refresh (`CollectionPriceUpdater`, one set at a time, ~490 sets on a real collection)
    /// into an infinite loop.
    private let maxRetries = 2

    private struct Envelope<T: Decodable>: Decodable {
        let meta: Meta
        let data: T?
    }

    private struct Meta: Decodable {
        let code: Int
        let message: String
        let description: String?
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get<T: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> T {
        try await get(path: path, queryItems: queryItems, retriesLeft: maxRetries)
    }

    private func get<T: Decodable>(path: String, queryItems: [URLQueryItem], retriesLeft: Int) async throws -> T {
        guard let credentials = KeychainService.shared.brickLinkOAuth1Credentials else {
            throw APIError.missingCredentials
        }

        await throttler.waitIfNeeded()

        var components = URLComponents(string: baseURL + path)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw APIError.unknown }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            BrickLinkOAuth1.authorizationHeader(method: "GET", url: url, queryItems: queryItems, credentials: credentials),
            forHTTPHeaderField: "Authorization"
        )

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
            throw APIError.unknown
        }

        // A genuine HTTP-429 (e.g. from a gateway in front of the API, rather than BrickLink's
        // own envelope) may not carry a JSON body shaped like `Envelope` at all — check the
        // transport status before a decode failure is treated as fatal, same reasoning as
        // checking `meta.code` below for BrickLink's *own* 429 (their envelope replies HTTP 200
        // even on failure, see this type's doc comment, so either can happen independently).
        guard httpResponse.statusCode != 429 else {
            return try await retryOrGiveUp(retriesLeft: retriesLeft, response: httpResponse, path: path, queryItems: queryItems)
        }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }

        switch envelope.meta.code {
        case 200...299:
            break
        case 401, 403:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 429:
            return try await retryOrGiveUp(retriesLeft: retriesLeft, response: httpResponse, path: path, queryItems: queryItems)
        case 500...599:
            throw APIError.serverError(envelope.meta.code)
        default:
            throw APIError.bricklinkError(envelope.meta.description ?? envelope.meta.message)
        }

        guard let value = envelope.data else { throw APIError.notFound }
        return value
    }

    /// Same shape as `BricksetClient`'s 429 handling: honor a `Retry-After` header if the host
    /// sent one, otherwise fall back to a fixed delay — BrickLink's own rate-limit signal is an
    /// application-level `meta.code: 429` inside an HTTP-200 envelope (confirmed live), which has
    /// no reason to carry a `Retry-After` header the way a gateway-level HTTP 429 might. A touch
    /// of jitter so several concurrent calls rate-limited at the same moment (e.g.
    /// `PriceRepository`'s parallel new/used fetch) don't retry in lockstep.
    private func retryOrGiveUp<T: Decodable>(
        retriesLeft: Int,
        response: HTTPURLResponse,
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> T {
        guard retriesLeft > 0 else { throw APIError.rateLimited }
        let delay = Self.retryDelay(from: response) ?? 2.0
        let jitter = TimeInterval.random(in: 0...1.0)
        try await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
        return try await get(path: path, queryItems: queryItems, retriesLeft: retriesLeft - 1)
    }

    /// Parses `Retry-After` as either the plain integer-seconds form or the HTTP-date form (RFC
    /// 9110 §10.2.3) — capped at 30s so a header value this app doesn't expect can't stall a
    /// caller for an unreasonable amount of time.
    private static func retryDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) {
            return min(seconds, 30)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return min(max(0, date.timeIntervalSinceNow), 30)
    }
}
