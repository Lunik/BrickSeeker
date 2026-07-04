import Foundation
import Observation

@Observable
@MainActor
final class HomeViewModel {
    var scannedSetsCount = 0
    var totalScans = 0
    var ownedSetsCount = 0
    var wishlistSetsCount = 0
    var lastSyncedAt: Date?

    var isAccountLinked = false
    var isBricksetAccountLinked = false
    var isSyncing = false
    var syncErrorMessage: String?

    private let repository: RebrickableRepositoryProtocol
    private let bricksetRepository: BricksetRepositoryProtocol
    private let localRepository: LocalRepository

    init(
        repository: RebrickableRepositoryProtocol = RebrickableRepository(),
        bricksetRepository: BricksetRepositoryProtocol = BricksetRepository(),
        localRepository: LocalRepository
    ) {
        self.repository = repository
        self.bricksetRepository = bricksetRepository
        self.localRepository = localRepository
    }

    func loadFromCache() {
        scannedSetsCount = localRepository.scannedSetsCount()
        totalScans = ScanStatsStore.shared.totalScans
        ownedSetsCount = localRepository.ownedSetsCount()
        wishlistSetsCount = localRepository.wishlistSetsCount()
        lastSyncedAt = localRepository.lastFullSyncAt()
        isAccountLinked = KeychainService.shared.hasUserToken
        isBricksetAccountLinked = KeychainService.shared.hasBricksetUserHash
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

        // Piggybacks on the same triggers as the collection sync above (launch, pull-to-refresh,
        // return from Settings) instead of its own wiring. Best-effort and silent on failure —
        // wishlist badges just keep showing their last-known state, same as a failed collection
        // sync leaving the cache as-is.
        if KeychainService.shared.hasBricksetUserHash {
            if let wanted = try? await bricksetRepository.fetchWishlistSetNumbers() {
                await WishlistSync.apply(wantedSetNums: wanted, localRepository: localRepository, rebrickableRepository: repository)
            }
        }
        // Re-reads the cache so `wishlistSetsCount` reflects what the sync above just wrote —
        // the `loadFromCache()` earlier in this function ran before the Brickset sync existed.
        loadFromCache()
    }
}
