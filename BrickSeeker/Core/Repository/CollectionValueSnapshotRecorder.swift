import Foundation
import SwiftData

/// Tallies the whole collection's current value and hands it to
/// `LocalRepository.recordCollectionValueSnapshot` (#216).
///
/// Exists for the callers that finish a **complete** price batch — `CollectionPriceUpdateSection`
/// and `CollectionPriceUpdater.resumeIfNeeded` — which have a `ModelContext` but no computed stats.
/// Statistiques doesn't come through here: it already holds a `CollectionStats` computed the same
/// way and calls the repository directly, so the number recorded is provably the number displayed.
/// Both paths land on the same idempotent, coverage-guarded repository method.
///
/// Deliberately **not** called from `refreshPrices(for:)` (the selection refresh): three sets
/// re-priced says nothing about the collection, and going through here would file it as this
/// month's reading of the whole thing.
@MainActor
enum CollectionValueSnapshotRecorder {
    static func record(in modelContext: ModelContext) {
        record(using: LocalRepository(modelContext: modelContext))
    }

    /// Same resolution chain as `StatisticsViewModel.recomputeStats` — `resolveCollectionPrice` over
    /// one grouped `allCachedPrices()` fetch, never a `cachedPrices(setNum:)` per set (#194's "one
    /// chain only" rule, and phase 4's O(N²) lesson).
    static func record(using repository: LocalRepository) {
        let sets = repository.ownedSets()
        guard !sets.isEmpty else { return }

        let conditionByListId = repository.conditionByListId()
        let quotesBySetNum = SetPriceIndex.pricesBySetNum(repository.allCachedPrices())

        var totalValueEUR = 0.0
        var unitsCount = 0
        var pricedSetsCount = 0
        for set in sets {
            unitsCount += set.quantity
            let condition = set.currentListId.flatMap { conditionByListId[$0] }
            guard let price = resolveCollectionPrice(
                storePriceEUR: set.storePriceEUR,
                condition: condition,
                quotes: quotesBySetNum[set.setNum] ?? []
            ) else { continue }
            pricedSetsCount += 1
            totalValueEUR += price * Double(set.quantity)
        }

        repository.recordCollectionValueSnapshot(
            totalValueEUR: totalValueEUR,
            setsCount: sets.count,
            unitsCount: unitsCount,
            pricedSetsCount: pricedSetsCount
        )
    }
}
