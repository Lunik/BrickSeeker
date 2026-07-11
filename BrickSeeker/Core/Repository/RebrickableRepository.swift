import Foundation

protocol RebrickableRepositoryProtocol: Sendable {
    func authenticate(apiKey: String, username: String, password: String) async throws -> String
    func fetchSet(setNum: String) async throws -> LegoSet
    func searchSets(query: String, pageSize: Int) async throws -> [LegoSet]
    func resolveSet(setNum: String) async throws -> SetResolution
    func fetchUserSet(setNum: String) async throws -> UserSet?
    func fetchAllUserSets() async throws -> [UserSet]
    func addSetToList(setNum: String, listId: Int) async throws
    func moveSetToList(setNum: String, fromListId: Int, toListId: Int) async throws
    func removeSetFromCollection(setNum: String) async throws
    func updateSetQuantity(setNum: String, listId: Int, quantity: Int) async throws
    func fetchUserSetLists() async throws -> [SetList]
    func createSetList(name: String) async throws -> SetList
    func fetchSetsContainingMinifig(figNum: String, pageSize: Int) async throws -> PaginatedResponse<MinifigSetEntry>
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

    // Endpoint 4b
    // Same nested "set" shape as fetchUserSet, paginated. A set owned in multiple Set Lists is
    // listed multiple times (one row per list) per Rebrickable's own endpoint description, so
    // callers that assume one list per set (LocalRepository.syncCollection) must dedupe by set_num.
    func fetchAllUserSets() async throws -> [UserSet] {
        try await withUserTokenRetry { userToken in
            var allSets: [UserSet] = []
            var nextURL: URL?
            repeat {
                let response: PaginatedResponse<UserSet>
                if let nextURL {
                    response = try await self.client.get(absoluteURL: nextURL)
                } else {
                    response = try await self.client.get(
                        path: RebrickableEndpoint.userSetsPath(userToken: userToken),
                        queryItems: [URLQueryItem(name: "page_size", value: "100")]
                    )
                }
                allSets.append(contentsOf: response.results)
                nextURL = response.next.flatMap(URL.init(string:))
            } while nextURL != nil
            return allSets
        }
    }

    // Endpoint 5
    // The response shape for this endpoint isn't reliably the same nested
    // Set object as /users/{token}/sets/{set_num}/ across Rebrickable's own
    // implementation, so the body is intentionally not decoded here — only
    // the HTTP status matters. Real collection status is read back separately
    // via fetchUserSet.
    func addSetToList(setNum: String, listId: Int) async throws {
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
    func moveSetToList(setNum: String, fromListId: Int, toListId: Int) async throws {
        try await withUserTokenRetry { userToken in
            try await self.client.delete(
                path: RebrickableEndpoint.setListSetPath(userToken: userToken, listId: fromListId, setNum: setNum)
            )
        }
        try await addSetToList(setNum: setNum, listId: toListId)
    }

    // Endpoint 7
    func removeSetFromCollection(setNum: String) async throws {
        try await withUserTokenRetry { userToken in
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

    // Endpoint 10
    // List-scoped PATCH, not the global `PUT /users/{token}/sets/{set_num}/` — that endpoint sets
    // quantity across *all* of the user's Set Lists, and per its own description, an increase adds
    // the extra copy to the user's default Set List rather than the one the set is already in
    // (confirmed by manual testing: a set in "sealed" jumped to "displayed" on increment). Both
    // endpoints verified against the community-maintained OpenAPI spec, since Rebrickable's own
    // swagger omits parameter/response details. Same undocumented-response-shape situation as
    // addSetToList, so only the HTTP status is trusted; callers re-read authoritative state via
    // fetchUserSet.
    func updateSetQuantity(setNum: String, listId: Int, quantity: Int) async throws {
        try await withUserTokenRetry { userToken in
            try await self.client.patch(
                path: RebrickableEndpoint.setListSetPath(userToken: userToken, listId: listId, setNum: setNum),
                formBody: ["quantity": String(quantity)]
            )
        }
    }

    // Endpoint 11
    // One page only (`pageSize`), not a full `fetchAllUserSets`-style pagination loop — a
    // popular minifig can appear in hundreds of sets, and #178 only ever shows a capped gallery,
    // so looping to fetch every page would be pure waste. `count` in the response tells the
    // caller how many more exist beyond this page for an "et N sets supplémentaires" note.
    func fetchSetsContainingMinifig(figNum: String, pageSize: Int = 30) async throws -> PaginatedResponse<MinifigSetEntry> {
        try await client.get(
            path: RebrickableEndpoint.minifigSetsPath(figNum: figNum),
            queryItems: [URLQueryItem(name: "page_size", value: String(pageSize))]
        )
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

    private func reauthenticateAndRefreshToken() async throws -> String {
        // Username/password are not retained after login, so an expired token
        // cannot be silently refreshed; the caller must re-run the auth flow.
        throw APIError.forbidden
    }
}
