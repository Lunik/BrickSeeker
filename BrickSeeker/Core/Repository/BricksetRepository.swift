import Foundation

/// Outcome of resolving+adding one set during the mass wishlist import (issue #6) — distinct
/// from a thrown error, since "this Rebrickable set doesn't exist on Brickset" (some polybags/
/// GWPs aren't catalogued there) is an expected, per-set result the importer reports in its
/// summary, not a failure that should abort the batch.
enum WishlistImportOutcome {
    case added
    case alreadyWanted
    case notFoundOnBrickset
}

protocol BricksetRepositoryProtocol: Sendable {
    func authenticate(apiKey: String, username: String, password: String) async throws -> String
    func wishlistStatus(setNum: String) async throws -> Bool
    func addToWishlist(setNum: String) async throws
    func removeFromWishlist(setNum: String) async throws
    /// Every set number currently marked `wanted` on Brickset, in Rebrickable "10307-1" format —
    /// feeds `LocalRepository.syncWishlist`.
    func fetchWishlistSetNumbers() async throws -> [String]
    /// Resolves and adds in a single Brickset lookup — used by the mass importer so a batch of
    /// N sets costs N `getSets` calls, not 2N (`wishlistStatus` then `addToWishlist` would each
    /// resolve the same `setID` separately).
    func addToWishlistIfNeeded(setNum: String) async throws -> WishlistImportOutcome
}

/// Talks to Brickset's v3 API, used purely as the storage backend for the wishlist feature — see
/// `AGENTS.md`/issue #6 on why Rebrickable itself can't host a set wishlist (its `setlists` are
/// owned-sets-only) and why Brickset's separate `wanted` flag was chosen instead. Deliberately
/// never touches Brickset's `owned` flag — this app's "owned" source of truth stays Rebrickable.
final class BricksetRepository: BricksetRepositoryProtocol, @unchecked Sendable {
    private let client: BricksetClient

    init(client: BricksetClient = .shared) {
        self.client = client
    }

    func authenticate(apiKey: String, username: String, password: String) async throws -> String {
        KeychainService.shared.save(key: .bricksetApiKey, value: apiKey)
        let response = try await client.call(
            BricksetEndpoint.loginPath,
            apiKey: apiKey,
            params: ["username": username, "password": password]
        )
        guard let hash = response.hash else { throw APIError.unknown }
        return hash
    }

    func wishlistStatus(setNum: String) async throws -> Bool {
        try await withCredentials { apiKey, userHash in
            let set = try await self.fetchSet(setNum: setNum, apiKey: apiKey, userHash: userHash)
            return set?.collection?.wanted ?? false
        }
    }

    func addToWishlist(setNum: String) async throws {
        try await setWanted(true, setNum: setNum)
    }

    func removeFromWishlist(setNum: String) async throws {
        try await setWanted(false, setNum: setNum)
    }

    func fetchWishlistSetNumbers() async throws -> [String] {
        try await withCredentials { apiKey, userHash in
            var page = 1
            let pageSize = 100
            var setNums: [String] = []
            // Stops only on a genuinely empty page rather than comparing `sets.count` against
            // the requested pageSize, so this doesn't undercount if Brickset ever caps the
            // effective page size below what's asked for.
            while true {
                // `wanted` must be a bare 0/1 integer, not a JSON boolean — confirmed live: `true`
                // reliably throws `bricksetError("No valid parameters")` even with zero other
                // params, while `1` succeeds. Same undocumented quirk as `setCollectionWant`'s
                // `want` field.
                let paramsJSON = "{\"wanted\":1,\"pageSize\":\(pageSize),\"pageNumber\":\(page)}"
                let response = try await self.client.call(
                    BricksetEndpoint.getSetsPath,
                    apiKey: apiKey,
                    userHash: userHash,
                    params: ["params": paramsJSON]
                )
                let sets = response.sets ?? []
                if sets.isEmpty { break }
                setNums.append(contentsOf: sets.compactMap(\.rebrickableSetNum))
                page += 1
            }
            return setNums
        }
    }

    func addToWishlistIfNeeded(setNum: String) async throws -> WishlistImportOutcome {
        try await withCredentials { apiKey, userHash in
            guard let set = try await self.fetchSet(setNum: setNum, apiKey: apiKey, userHash: userHash) else {
                return .notFoundOnBrickset
            }
            if set.collection?.wanted == true {
                return .alreadyWanted
            }
            try await self.setCollectionWant(true, setId: set.setId, apiKey: apiKey, userHash: userHash)
            return .added
        }
    }

    private func setWanted(_ wanted: Bool, setNum: String) async throws {
        try await withCredentials { apiKey, userHash in
            guard let set = try await self.fetchSet(setNum: setNum, apiKey: apiKey, userHash: userHash) else {
                throw APIError.notFound
            }
            try await self.setCollectionWant(wanted, setId: set.setId, apiKey: apiKey, userHash: userHash)
        }
    }

    private func setCollectionWant(_ wanted: Bool, setId: Int, apiKey: String, userHash: String) async throws {
        // Brickset expects this boolean pre-serialized as 0/1 (confirmed against the reference
        // Java client's `SetCollectionParameters`, which uses `JsonFormat.Shape.NUMBER` — its
        // wire format isn't in Brickset's own docs) — built by hand rather than via `Encodable`
        // to match that exactly instead of trusting `JSONEncoder`'s `true`/`false` literals.
        let params = "{\"want\":\(wanted ? 1 : 0)}"
        _ = try await client.call(
            BricksetEndpoint.setCollectionPath,
            apiKey: apiKey,
            userHash: userHash,
            params: ["SetID": String(setId), "params": params]
        )
    }

    /// Resolves a Rebrickable-format set number ("10307-1") to its Brickset entry via `getSets`,
    /// or `nil` if Brickset has no matching set — not every Rebrickable set is catalogued there.
    ///
    /// `setNumber` must be a bare JSON *string*, not the `["10307-1"]` array the reference Java
    /// client's `SetParameters.setNumber: List<String>` implies — confirmed live: the array form
    /// reliably returns `matches: 0` even for sets that exist (e.g. 10307-1, LEGO's Eiffel Tower),
    /// while the bare-string form returns the correct single match. Undocumented on Brickset's
    /// side (their OpenAPI-less `.asmx` docs don't cover per-parameter JSON shapes), so don't
    /// "fix" this back to an array without re-confirming against a live response first.
    private func fetchSet(setNum: String, apiKey: String, userHash: String) async throws -> BricksetSet? {
        let paramsJSON = "{\"setNumber\":\"\(setNum)\"}"
        let response = try await client.call(
            BricksetEndpoint.getSetsPath,
            apiKey: apiKey,
            userHash: userHash,
            params: ["params": paramsJSON]
        )
        return response.sets?.first
    }

    private func withCredentials<T>(_ operation: (String, String) async throws -> T) async throws -> T {
        guard let apiKey = KeychainService.shared.load(key: .bricksetApiKey),
              let userHash = KeychainService.shared.load(key: .bricksetUserHash) else {
            throw APIError.missingCredentials
        }
        return try await operation(apiKey, userHash)
    }
}
