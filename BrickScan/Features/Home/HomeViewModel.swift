import Foundation
import Observation

@Observable
@MainActor
final class HomeViewModel {
    var scannedSetsCount = 0
    var totalScans = 0
    var ownedSetsCount = 0
    var lastSyncedAt: Date?

    var isAccountLinked = false
    var isSyncing = false
    var syncErrorMessage: String?

    private let repository: RebrickableRepositoryProtocol
    private let localRepository: LocalRepository

    init(repository: RebrickableRepositoryProtocol = RebrickableRepository(), localRepository: LocalRepository) {
        self.repository = repository
        self.localRepository = localRepository
    }

    func loadFromCache() {
        scannedSetsCount = localRepository.scannedSetsCount()
        totalScans = ScanStatsStore.shared.totalScans
        ownedSetsCount = localRepository.ownedSetsCount()
        lastSyncedAt = localRepository.lastFullSyncAt()
        isAccountLinked = KeychainService.shared.hasUserToken
    }

    func syncCollection() async {
        loadFromCache()
        guard isAccountLinked, NetworkMonitor.shared.isConnected else { return }

        isSyncing = true
        syncErrorMessage = nil
        defer { isSyncing = false }
        do {
            async let sets = repository.fetchAllUserSets()
            async let lists = repository.fetchUserSetLists()
            localRepository.syncCollection(try await sets, lists: try await lists)
            loadFromCache()
        } catch is CancellationError {
            // .refreshable cancelled the in-flight request (e.g. content reflowed under the
            // pull gesture) — not a real failure, the cache still shows the last good sync.
        } catch let error as APIError {
            syncErrorMessage = error.errorDescription
        } catch {
            syncErrorMessage = "Une erreur est survenue"
        }
    }
}
