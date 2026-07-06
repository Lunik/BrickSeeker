import Foundation

/// Dedicated client for the official BrickLink Store API (`api.bricklink.com/api/store/v1`) —
/// separate from `NetworkClient` since BrickLink uses OAuth 1.0a (a fresh HMAC-SHA1 signature per
/// request, not a static header) and its own throttling budget, same reasoning as `BricksetClient`.
///
/// Response envelope confirmed against BrickLink's official client libraries' source (the
/// interactive API docs at bricklink.com/v3/api.page are a JS app with no static reference, so
/// third-party clients' typed models are the closest thing to a spec — cross-checked against
/// multiple independent implementations, not a single source): `{ "meta": { code, message,
/// description }, "data": {...} }`. `meta.code` is BrickLink's own status code and normally
/// matches the HTTP status, but only the HTTP status is checked here — same trust boundary as
/// every other host this app calls.
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
        let data: T?
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

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 429:
            throw APIError.rateLimited
        case 500...599:
            throw APIError.serverError(httpResponse.statusCode)
        default:
            throw APIError.unknown
        }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
        guard let value = envelope.data else { throw APIError.notFound }
        return value
    }
}
