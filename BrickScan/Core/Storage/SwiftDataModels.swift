import Foundation
import SwiftData

@Model
final class CachedSet {
    @Attribute(.unique) var setNum: String
    var name: String
    var year: Int
    var numParts: Int
    var setImgUrl: String?
    var lastScannedAt: Date
    var isInCollection: Bool
    var currentListId: Int?
    var currentListName: String?

    init(from legoSet: LegoSet, isInCollection: Bool = false, currentListId: Int? = nil, currentListName: String? = nil) {
        self.setNum = legoSet.setNum
        self.name = legoSet.name
        self.year = legoSet.year
        self.numParts = legoSet.numParts
        self.setImgUrl = legoSet.setImgUrl
        self.lastScannedAt = Date()
        self.isInCollection = isInCollection
        self.currentListId = currentListId
        self.currentListName = currentListName
    }

    var isExpired: Bool {
        Date().timeIntervalSince(lastScannedAt) > 24 * 60 * 60
    }
}

@Model
final class CachedSetList {
    @Attribute(.unique) var listId: Int
    var name: String
    var numSets: Int
    var lastFetchedAt: Date

    init(from setList: SetList) {
        self.listId = setList.id
        self.name = setList.name
        self.numSets = setList.numSets
        self.lastFetchedAt = Date()
    }

    var isExpired: Bool {
        Date().timeIntervalSince(lastFetchedAt) > 5 * 60
    }
}
