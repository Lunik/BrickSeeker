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
    var ownedMinifigsCount = 0

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

    /// Counts distinct owned minifigs (issue #170's Home tile) — a minifig is "owned" if any set
    /// it appears in (per the offline minifig catalogue's join, see `OfflineMinifigCatalogStore`)
    /// is itself in the local collection. Entirely offline/local: 0 if the minifig catalogue
    /// hasn't been downloaded yet (mirrors `ownedSetsCount` being 0 before the first sync), no
    /// network call either way. Separate from `loadFromCache()` (which stays synchronous) since
    /// decoding the minifig catalogue snapshot is async.
    func loadOwnedMinifigsCount() async {
        guard isAccountLinked else {
            ownedMinifigsCount = 0
            return
        }
        let ownedSetNums = Set(localRepository.ownedSets().map(\.setNum))
        guard !ownedSetNums.isEmpty else {
            ownedMinifigsCount = 0
            return
        }
        let entries = await OfflineMinifigCatalogStore.shared.allEntries()
        ownedMinifigsCount = entries.reduce(into: 0) { count, entry in
            if entry.containingSets.contains(where: { ownedSetNums.contains($0.setNum) }) {
                count += 1
            }
        }
    }

    func syncCollection() async {
        loadFromCache()
        guard isAccountLinked, NetworkMonitor.shared.isConnected else {
            // Not linked / offline is a resolved attempt too (#148) — without this, screens
            // gating their loading spinner on `didAttemptInitialSync` would spin forever when
            // there's nothing to sync.
            SyncStatusStore.shared.didAttemptInitialSync = true
            return
        }

        isSyncing = true
        SyncStatusStore.shared.isSyncing = true
        syncErrorMessage = nil
        defer {
            isSyncing = false
            SyncStatusStore.shared.isSyncing = false
            SyncStatusStore.shared.didAttemptInitialSync = true
        }
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
