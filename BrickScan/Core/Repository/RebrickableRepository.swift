import Foundation

protocol RebrickableRepositoryProtocol: Sendable {
    func authenticate(apiKey: String, username: String, password: String) async throws -> String
    func fetchSet(setNum: String) async throws -> LegoSet
    func searchSets(query: String, pageSize: Int) async throws -> [LegoSet]
    func resolveSet(setNum: String) async throws -> SetResolution
    func fetchUserSet(setNum: String) async throws -> UserSet?
    func addSetToList(setNum: String, listId: Int) async throws -> UserSet
    func moveSetToList(setNum: String, fromListId: Int, toListId: Int) async throws -> UserSet
    func removeSetFromCollection(setNum: String) async throws
    func fetchUserSetLists() async throws -> [SetList]
    func createSetList(name: String) async throws -> SetList
}

enum SetResolution {
    case found(LegoSet)
    case ambiguous([LegoSet])
    case notFound
}

final class RebrickableRepository: RebrickableRepositoryProtocol, @unchecked Sendable {
    private let client: NetworkClient

    init(client: NetworkClient = .shared) {
        self.client = client
    }

    // Endpoint 1
    func authenticate(apiKey: String, username: String, password: String) async throws -> String {
        KeychainService.shared.save(key: .apiKey, value: apiKey)
        let response: UserTokenResponse = try await client.post(
            path: RebrickableEndpoint.userTokenPath,
            formBody: ["username": username, "password": password]
        )
        return response.userToken
    }

    // Endpoint 2
    func fetchSet(setNum: String) async throws -> LegoSet {
        try await client.get(path: RebrickableEndpoint.setPath(setNum: setNum))
    }

    // Endpoint 3
    func searchSets(query: String, pageSize: Int = 5) async throws -> [LegoSet] {
        let response: PaginatedResponse<LegoSet> = try await client.get(
            path: RebrickableEndpoint.searchSetsPath,
            queryItems: [
                URLQueryItem(name: "search", value: query),
                URLQueryItem(name: "page_size", value: String(pageSize))
            ]
        )
        return response.results
    }

    func resolveSet(setNum: String) async throws -> SetResolution {
        if let set = try? await fetchSet(setNum: "\(setNum)-1") {
            return .found(set)
        }
        if let set = try? await fetchSet(setNum: setNum) {
            return .found(set)
        }
        let results = try await searchSets(query: setNum, pageSize: 5)
        if results.isEmpty {
            return .notFound
        }
        if results.count == 1 {
            return .found(results[0])
        }
        return .ambiguous(results)
    }

    // Endpoint 4
    func fetchUserSet(setNum: String) async throws -> UserSet? {
        try await withUserTokenRetry { userToken in
            do {
                return try await self.client.get(
                    path: RebrickableEndpoint.userSetPath(userToken: userToken, setNum: setNum)
                )
            } catch APIError.notFound {
                return nil
            }
        }
    }

    // Endpoint 5
    func addSetToList(setNum: String, listId: Int) async throws -> UserSet {
        try await withUserTokenRetry { userToken in
            try await self.client.post(
                path: RebrickableEndpoint.setListSetsPath(userToken: userToken, listId: listId),
                formBody: ["set_num": setNum, "quantity": "1"]
            )
        }
    }

    // Endpoint 6
    // Rebrickable has no endpoint to change a set's list_id directly, so a
    // move is a delete from the old list followed by an add to the new one.
    func moveSetToList(setNum: String, fromListId: Int, toListId: Int) async throws -> UserSet {
        try await withUserTokenRetryVoid { userToken in
            try await self.client.delete(
                path: RebrickableEndpoint.setListSetPath(userToken: userToken, listId: fromListId, setNum: setNum)
            )
        }
        return try await addSetToList(setNum: setNum, listId: toListId)
    }

    // Endpoint 7
    func removeSetFromCollection(setNum: String) async throws {
        try await withUserTokenRetryVoid { userToken in
            try await self.client.delete(
                path: RebrickableEndpoint.userSetPath(userToken: userToken, setNum: setNum)
            )
        }
    }

    // Endpoint 8
    func fetchUserSetLists() async throws -> [SetList] {
        try await withUserTokenRetry { userToken in
            let response: PaginatedResponse<SetList> = try await self.client.get(
                path: RebrickableEndpoint.userSetListsPath(userToken: userToken)
            )
            return response.results
        }
    }

    // Endpoint 9
    func createSetList(name: String) async throws -> SetList {
        try await withUserTokenRetry { userToken in
            try await self.client.post(
                path: RebrickableEndpoint.userSetListsPath(userToken: userToken),
                formBody: ["name": name]
            )
        }
    }

    // MARK: - User token retry on 403

    private func withUserTokenRetry<T>(_ operation: @escaping (String) async throws -> T) async throws -> T {
        guard let userToken = KeychainService.shared.load(key: .userToken) else {
            throw APIError.missingCredentials
        }
        do {
            return try await operation(userToken)
        } catch APIError.forbidden {
            let newToken = try await reauthenticateAndRefreshToken()
            return try await operation(newToken)
        }
    }

    private func withUserTokenRetryVoid(_ operation: @escaping (String) async throws -> Void) async throws {
        guard let userToken = KeychainService.shared.load(key: .userToken) else {
            throw APIError.missingCredentials
        }
        do {
            try await operation(userToken)
        } catch APIError.forbidden {
            let newToken = try await reauthenticateAndRefreshToken()
            try await operation(newToken)
        }
    }

    private func reauthenticateAndRefreshToken() async throws -> String {
        // Username/password are not retained after login, so an expired token
        // cannot be silently refreshed; the caller must re-run the auth flow.
        throw APIError.forbidden
    }
}
