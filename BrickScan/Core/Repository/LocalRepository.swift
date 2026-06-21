import Foundation
import SwiftData

@MainActor
final class LocalRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func cacheSet(_ legoSet: LegoSet, isInCollection: Bool, listId: Int?, listName: String?) {
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
        } else {
            let cached = CachedSet(from: legoSet, isInCollection: isInCollection, currentListId: listId, currentListName: listName)
            modelContext.insert(cached)
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
        try? modelContext.save()
    }
}
