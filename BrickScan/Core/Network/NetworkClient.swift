import Foundation

final class NetworkClient: @unchecked Sendable {
    static let shared = NetworkClient()

    private let baseURL = RebrickableEndpoint.baseURL
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get<T: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(string: baseURL + path)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await send(request)
    }

    func post<T: Decodable>(path: String, formBody: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodeFormBody(formBody)
        return try await send(request)
    }

    func post(path: String, formBody: [String: String]) async throws {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodeFormBody(formBody)
        _ = try await sendRaw(request)
    }

    func patch<T: Decodable>(path: String, jsonBody: [String: Any]) async throws -> T {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return try await send(request)
    }

    func delete(path: String) async throws {
        let request = URLRequest(url: URL(string: baseURL + path)!)
        var mutableRequest = request
        mutableRequest.httpMethod = "DELETE"
        _ = try await sendRaw(mutableRequest)
    }

    // MARK: - Private

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await sendRaw(request)
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        await RequestThrottler.shared.waitIfNeeded()

        var authenticatedRequest = request
        if let apiKey = KeychainService.shared.load(key: .apiKey) {
            authenticatedRequest.setValue("key \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: authenticatedRequest)
        } catch {
            throw APIError.networkUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 429:
            throw APIError.rateLimited
        case 500...599:
            throw APIError.serverError(httpResponse.statusCode)
        default:
            throw APIError.unknown
        }
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
