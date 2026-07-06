import Foundation

enum RebrickableEndpoint {
    static let baseURL = "https://rebrickable.com/api/v3"

    static let userTokenPath = "/users/_token/"

    static func setPath(setNum: String) -> String {
        "/lego/sets/\(setNum)/"
    }

    static let searchSetsPath = "/lego/sets/"

    static func userSetPath(userToken: String, setNum: String) -> String {
        "/users/\(userToken)/sets/\(setNum)/"
    }

    static func userSetsPath(userToken: String) -> String {
        "/users/\(userToken)/sets/"
    }

    static func userSetListsPath(userToken: String) -> String {
        "/users/\(userToken)/setlists/"
    }

    static func setListSetsPath(userToken: String, listId: Int) -> String {
        "/users/\(userToken)/setlists/\(listId)/sets/"
    }

    static func setListSetPath(userToken: String, listId: Int, setNum: String) -> String {
        "/users/\(userToken)/setlists/\(listId)/sets/\(setNum)/"
    }
}
