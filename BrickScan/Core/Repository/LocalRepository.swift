import Foundation
import SwiftData

@MainActor
final class LocalRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func cacheSet(
        _ legoSet: LegoSet,
        isInCollection: Bool,
        listId: Int?,
        listName: String?,
        isMinifig: Bool = false,
        boxCode: String? = nil
    ) {
        let existing = try? modelContext.fetch(
            FetchDescriptor<CachedSet>(predicate: #Predicate { $0.setNum == legoSet.setNum })
        ).first

        if let existing {
            existing.name = legoSet.name
            existing.year = legoSet.year
            existing.numParts = legoSet.numParts
            existing.setImgUrl = legoSet.setImgUrl
            existing.lastScannedAt = Date()
            existing.isInCollection = isInCollection
            existing.currentListId = listId
            existing.currentListName = listName
            existing.isMinifig = isMinifig
            existing.boxCode = boxCode ?? existing.boxCode
        } else {
            let cached = CachedSet(
                from: legoSet,
                isInCollection: isInCollection,
                currentListId: listId,
                currentListName: listName,
                isMinifig: isMinifig,
                boxCode: boxCode
            )
            modelContext.insert(cached)
        }
        try? modelContext.save()
    }

    func cachePendingBoxCode(_ boxCode: String) {
        let existing = try? modelContext.fetch(
            FetchDescriptor<CachedUnresolvedBoxCode>(predicate: #Predicate { $0.boxCode == boxCode })
        ).first

        if let existing {
            existing.lastScannedAt = Date()
        } else {
            modelContext.insert(CachedUnresolvedBoxCode(boxCode: boxCode))
        }
        try? modelContext.save()
    }

    func pendingBoxCodes() -> [CachedUnresolvedBoxCode] {
        (try? modelContext.fetch(FetchDescriptor<CachedUnresolvedBoxCode>())) ?? []
    }

    /// Re-checks every previously unresolved box code against the current
    /// bundled catalog and promotes any that now match into `CachedSet`
    /// entries. Call when the user opens history, so codes that became
    /// resolvable in an app update surface without a re-scan.
    func resolvePendingMinifigBoxCodes(
        catalog: MinifigBoxCodeCatalog = .shared,
        repository: RebrickableRepositoryProtocol
    ) async {
        for pending in pendingBoxCodes() {
            guard let match = catalog.match(decodedValue: pending.boxCode),
                  let legoSet = try? await repository.fetchSet(setNum: match.setNum) else {
                continue
            }
            cacheSet(legoSet, isInCollection: false, listId: nil, listName: nil, isMinifig: true, boxCode: pending.boxCode)
            modelContext.delete(pending)
        }
        try? modelContext.save()
    }

    func recentlyScannedSets(limit: Int = 50) -> [CachedSet] {
        let descriptor = FetchDescriptor<CachedSet>(
            sortBy: [SortDescriptor(\.lastScannedAt, order: .reverse)]
        )
        let results = try? modelContext.fetch(descriptor)
        return Array((results ?? []).prefix(limit))
    }

    func cachedSet(setNum: String) -> CachedSet? {
        try? modelContext.fetch(
            FetchDescriptor<CachedSet>(predicate: #Predicate { $0.setNum == setNum })
        ).first
    }

    func cacheSetLists(_ setLists: [SetList]) {
        for setList in setLists {
            let existing = try? modelContext.fetch(
                FetchDescriptor<CachedSetList>(predicate: #Predicate { $0.listId == setList.id })
            ).first
            if let existing {
                existing.name = setList.name
                existing.numSets = setList.numSets
                existing.lastFetchedAt = Date()
            } else {
                modelContext.insert(CachedSetList(from: setList))
            }
        }
        try? modelContext.save()
    }

    func cachedSetLists() -> [CachedSetList] {
        (try? modelContext.fetch(FetchDescriptor<CachedSetList>())) ?? []
    }

    func clearAll() {
        if let sets = try? modelContext.fetch(FetchDescriptor<CachedSet>()) {
            sets.forEach { modelContext.delete($0) }
        }
        if let lists = try? modelContext.fetch(FetchDescriptor<CachedSetList>()) {
            lists.forEach { modelContext.delete($0) }
        }
        if let pending = try? modelContext.fetch(FetchDescriptor<CachedUnresolvedBoxCode>()) {
            pending.forEach { modelContext.delete($0) }
        }
        try? modelContext.save()
    }
}
