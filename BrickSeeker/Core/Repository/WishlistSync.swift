import Foundation

/// Reconciles the local cache against Brickset's full wanted-set list — updates `isInWishlist` on
/// already-cached sets (`LocalRepository.syncWishlist`) and enriches+inserts a row for any wanted
/// set with no local cache entry yet (never scanned or owned), via Rebrickable's catalog. Without
/// the second half, a set only ever on the wishlist (the common case — most wishlisted sets
/// aren't already owned) would silently vanish from the count and the Liste cadeaux screen despite
/// Brickset correctly reporting it. Shared by `HomeViewModel.syncCollection` (launch/pull-to-
/// refresh/Settings-dismiss) and `BricksetWishlistImportSection` (right after a mass import).
@MainActor
enum WishlistSync {
    static func apply(
        wantedSetNums: [String],
        localRepository: LocalRepository,
        rebrickableRepository: RebrickableRepositoryProtocol
    ) async {
        localRepository.syncWishlist(wantedSetNums: Set(wantedSetNums))

        let cachedNums = localRepository.cachedSetNums()
        let missing = wantedSetNums.filter { !cachedNums.contains($0) }
        for setNum in missing {
            if let legoSet = try? await rebrickableRepository.fetchSet(setNum: setNum) {
                localRepository.cacheWishlistSet(legoSet)
            }
        }
    }
}
