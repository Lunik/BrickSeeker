import Foundation

/// Brickset's v3 API wraps every method's result (success or failure) in the same flat envelope
/// — unlike Rebrickable, the HTTP status is always 200 and the outcome lives in `status`/
/// `message` here. Fields are all optional since only a handful are populated per method (e.g.
/// `hash` only on `login`, `sets` only on `getSets`) — mirrors `Response.java` in the reference
/// Java client (`e-amzallag/bricksetapi`), the source used to confirm this shape.
struct BricksetResponse: Codable {
    let status: String
    let message: String?
    let hash: String?
    let matches: Int?
    let sets: [BricksetSet]?
}

/// Only the fields this app's wishlist feature actually reads — Brickset's real `Set` shape
/// has dozens more (name, year, image, pricing…), irrelevant here since the app already has its
/// own richer set data from Rebrickable.
struct BricksetSet: Codable {
    let setId: Int
    /// Brickset splits the Rebrickable-style "10307-1" into `number` ("10307") and
    /// `numberVariant` (1) — only populated/needed when listing the whole wishlist
    /// (`BricksetRepository.fetchWishlistSetNumbers`), where they're rejoined to match
    /// `CachedSet.setNum`'s format. A single-set lookup by `setNumber` only needs `setId`.
    let number: String?
    let numberVariant: Int?
    let collection: BricksetCollection?

    enum CodingKeys: String, CodingKey {
        case setId = "setID"
        case number
        case numberVariant
        case collection
    }

    /// Rebrickable-format set number ("10307-1"), or `nil` if `number`/`numberVariant` weren't
    /// requested in this response.
    var rebrickableSetNum: String? {
        guard let number, let numberVariant else { return nil }
        return "\(number)-\(numberVariant)"
    }
}

struct BricksetCollection: Codable {
    let owned: Bool?
    let wanted: Bool?
}
