import Foundation

/// Path builders for the Brickset v3 API (`/api/v3.asmx/{method}`), used as the storage backend
/// for the wishlist feature — see AGENTS.md on why Rebrickable's own `setlists` can't host a
/// wishlist (they represent *owned* sets only) and why Brickset's separate `wanted` flag was
/// chosen instead.
enum BricksetEndpoint {
    static let baseURL = "https://brickset.com/api/v3.asmx"

    static let loginPath = "/login"
    static let getSetsPath = "/getSets"
    static let setCollectionPath = "/setCollection"
}
