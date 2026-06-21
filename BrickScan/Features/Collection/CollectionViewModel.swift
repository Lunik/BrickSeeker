import Foundation
import Observation

@Observable
@MainActor
final class CollectionViewModel {
    var cachedSets: [CachedSet] = []

    private let localRepository: LocalRepository

    init(localRepository: LocalRepository) {
        self.localRepository = localRepository
    }

    func load() {
        cachedSets = localRepository.recentlyScannedSets()
    }
}
