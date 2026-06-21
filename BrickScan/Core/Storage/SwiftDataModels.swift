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
    /// True when this entry is an individual CMF minifigure (identified via
    /// its box's Data Matrix code) rather than a directly-scanned set.
    var isMinifig: Bool = false
    /// The raw decoded box code, kept for minifig entries only.
    var boxCode: String?

    init(
        from legoSet: LegoSet,
        isInCollection: Bool = false,
        currentListId: Int? = nil,
        currentListName: String? = nil,
        isMinifig: Bool = false,
        boxCode: String? = nil
    ) {
        self.setNum = legoSet.setNum
        self.name = legoSet.name
        self.year = legoSet.year
        self.numParts = legoSet.numParts
        self.setImgUrl = legoSet.setImgUrl
        self.lastScannedAt = Date()
        self.isInCollection = isInCollection
        self.currentListId = currentListId
        self.currentListName = currentListName
        self.isMinifig = isMinifig
        self.boxCode = boxCode
    }

    var isExpired: Bool {
        Date().timeIntervalSince(lastScannedAt) > 24 * 60 * 60
    }
}

/// A CMF box Data Matrix code that was scanned but didn't match any known
/// entry in the bundled `MinifigBoxCodes.json` table. Kept so the scan isn't
/// lost: if a future app update ships an updated table that covers this
/// code, it gets promoted into a `CachedSet` automatically (see
/// `LocalRepository.resolvePendingMinifigBoxCodes`).
@Model
final class CachedUnresolvedBoxCode {
    @Attribute(.unique) var boxCode: String
    var firstScannedAt: Date
    var lastScannedAt: Date

    init(boxCode: String) {
        self.boxCode = boxCode
        self.firstScannedAt = Date()
        self.lastScannedAt = Date()
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
