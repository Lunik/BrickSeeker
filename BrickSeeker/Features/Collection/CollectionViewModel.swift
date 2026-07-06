import Foundation
import Observation

@Observable
@MainActor
final class CollectionViewModel {
    var cachedSets: [CachedSet] = []

    private let localRepository: LocalRepository
    private let themeNameStore: ThemeNameStore

    init(localRepository: LocalRepository, themeNameStore: ThemeNameStore = .shared) {
        self.localRepository = localRepository
        self.themeNameStore = themeNameStore
    }

    func load() {
        cachedSets = localRepository.ownedSets()
        // Theme names are read straight off the (observable) ThemeNameStore by the views —
        // this just makes sure the table exists/refreshes.
        Task { await themeNameStore.refreshIfNeeded() }
    }

    var availableThemeIds: [Int] {
        Set(cachedSets.map(\.themeId)).sorted()
    }

    var availableYears: [Int] {
        Set(cachedSets.map(\.year)).sorted(by: >)
    }

    var availableListNames: [String] {
        Set(cachedSets.compactMap(\.currentListName)).sorted()
    }
}
