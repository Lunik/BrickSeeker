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

        guard response is HTTPURLResponse else {
            throw APIError.unknown
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
            throw APIError.rateLimited
        case 500...599:
            throw APIError.serverError(envelope.meta.code)
        default:
            throw APIError.bricklinkError(envelope.meta.description ?? envelope.meta.message)
        }

        guard let value = envelope.data else { throw APIError.notFound }
        return value
    }
}
