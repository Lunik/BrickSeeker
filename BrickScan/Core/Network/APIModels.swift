import Foundation

struct UserTokenResponse: Codable {
    let userToken: String

    enum CodingKeys: String, CodingKey {
        case userToken = "user_token"
    }
}

struct LegoSet: Codable, Identifiable, Hashable {
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
