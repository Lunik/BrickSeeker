import Foundation

struct UserTokenResponse: Codable {
    let userToken: String

    enum CodingKeys: String, CodingKey {
        case userToken = "user_token"
    }
}

struct LegoSet: Codable, Identifiable, Hashable, Sendable {
    var id: String { setNum }

    let setNum: String
    let name: String
    let year: Int
    let themeId: Int
    let numParts: Int
    let setImgUrl: String?
    let setUrl: String?

    enum CodingKeys: String, CodingKey {
        case setNum = "set_num"
        case name
        case year
        case themeId = "theme_id"
        case numParts = "num_parts"
        case setImgUrl = "set_img_url"
        case setUrl = "set_url"
    }
}

extension String {
    /// Strips Rebrickable's variant suffix (`"71045-3"` → `"71045"`). For the vast majority of
    /// sets the suffix is always `-1` and shown nowhere; only `AmbiguousSetPickerView` needs the
    /// full `setNum` to disambiguate variants sharing the same base number (see #97).
    /// Minifig identifiers (`"fig-000123"`) have no variant suffix, so they're returned as-is
    /// to avoid stripping down to just `"fig"` (see #123).
    var baseSetNum: String {
        guard !hasPrefix("fig-") else { return self }
        return split(separator: "-").first.map(String.init) ?? self
    }

    /// Whether this is a minifig identifier (`"fig-…"`) rather than a set number — the same
    /// convention used by `BrickLinkPriceRepository` (see #173/#176).
    var isMinifig: Bool { hasPrefix("fig-") }
}

/// One entry from `/lego/minifigs/{fig_num}/sets/` (issue #178) — the sets a given minifig has
/// appeared in. `quantity` is decoded defensively as optional: neither of the two independent
/// third-party sources consulted while verifying this endpoint (check-rebrickable-endpoint
/// skill) documented a per-set quantity field for this specific list, unlike sibling endpoints
/// that nest a nearly-identical `LegoSet` shape alongside a `quantity` — so the UI only shows
/// the "×N" badge when the field happens to be present rather than assuming it always is.
struct MinifigSetEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String { setNum }

    let setNum: String
    let name: String
    let numParts: Int
    let setImgUrl: String?
    let setUrl: String?
    let quantity: Int?

    enum CodingKeys: String, CodingKey {
        case setNum = "set_num"
        case name
        case numParts = "num_parts"
        case setImgUrl = "set_img_url"
        case setUrl = "set_url"
        case quantity
    }
}

/// One entry from `/lego/sets/{set_num}/minifigs/` (issue #184) — the minifigs a given set
/// contains. **Not** the same shape as `MinifigSetEntry` despite being the pivot's reverse side
/// — confirmed live (a session's earlier assumption that Rebrickable serializes both directions
/// identically was wrong and shipped a silent decode failure on every response, caught by
/// manual simulator verification): this side nests only `id`/`set_num`/`set_name`/`quantity`/
/// `set_img_url`, no `num_parts` or `set_url`, and the minifig's own name comes back as
/// `set_name` rather than `name`.
struct SetMinifigEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String { setNum }

    let setNum: String
    let name: String
    let quantity: Int?
    let setImgUrl: String?

    enum CodingKeys: String, CodingKey {
        case setNum = "set_num"
        case name = "set_name"
        case quantity
        case setImgUrl = "set_img_url"
    }
}

struct PaginatedResponse<T: Codable>: Codable {
    let count: Int
    let next: String?
    let previous: String?
    let results: [T]
}

struct UserSet: Codable, Hashable {
    let legoSet: LegoSet
    let quantity: Int
    let includeSpares: Bool
    let listId: Int?

    var setNum: String { legoSet.setNum }

    enum CodingKeys: String, CodingKey {
        case legoSet = "set"
        case quantity
        case includeSpares = "include_spares"
        case listId = "list_id"
    }
}

enum CollectionStatus: Equatable {
    case inCollection(UserSet)
    case notInCollection
    case unknown(String)
}

struct SetList: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let numSets: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case numSets = "num_sets"
    }
}
