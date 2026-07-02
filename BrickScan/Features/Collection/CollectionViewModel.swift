import Foundation
import Observation

@Observable
@MainActor
final class CollectionViewModel {
    var cachedSets: [CachedSet] = []
    /// Mirrors `ThemeNameStore.shared.namesByThemeId` once `refreshIfNeeded()` resolves — copied
    /// into this `@Observable` property so the filter sheet re-renders when names arrive, same
    /// pattern as `StatisticsViewModel.themeNames`.
    var themeNames: [Int: String] = [:]

    private let localRepository: LocalRepository
    private let themeNameStore: ThemeNameStore

    init(localRepository: LocalRepository, themeNameStore: ThemeNameStore = .shared) {
        self.localRepository = localRepository
        self.themeNameStore = themeNameStore
    }

    func load() {
        cachedSets = localRepository.ownedSets()
        themeNames = themeNameStore.namesByThemeId
        Task {
            await themeNameStore.refreshIfNeeded()
            themeNames = themeNameStore.namesByThemeId
        }
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

    func themeName(forThemeId themeId: Int) -> String {
        themeNames[themeId] ?? "Thème #\(themeId)"
    }
}
