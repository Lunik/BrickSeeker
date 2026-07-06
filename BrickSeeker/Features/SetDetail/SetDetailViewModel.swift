import Foundation
import Observation

@MainActor
@Observable
final class SetDetailViewModel {
    let legoSet: LegoSet
    var collectionStatus: CollectionStatus
    var collectionListName: String?
    var isLoading = false
    var errorMessage: String?
    var toastMessage: String?
    var priceQuotes: [PriceQuote] = []
    var pricesLoading = false

    var storePrice: StorePrice?
    var storePriceFetchedAt: Date?
    var isLoadingStorePrice = false
    var storePriceErrorMessage: String?

    var isInWishlist: Bool
    var isWishlistLoading = false

    private let repository: RebrickableRepositoryProtocol
    private let bricksetRepository: BricksetRepositoryProtocol
    private let legoStoreRepository: LegoStoreRepositoryProtocol
    private let priceRepository: PriceRepositoryProtocol

    init(
        legoSet: LegoSet,
        collectionStatus: CollectionStatus,
        initialListName: String? = nil,
        initialStorePrice: StorePrice? = nil,
        initialStorePriceFetchedAt: Date? = nil,
        initialIsInWishlist: Bool = false,
        repository: RebrickableRepositoryProtocol = RebrickableRepository(),
        bricksetRepository: BricksetRepositoryProtocol = BricksetRepository(),
        legoStoreRepository: LegoStoreRepositoryProtocol = LegoStoreRepository(),
        priceRepository: PriceRepositoryProtocol = PriceRepository()
    ) {
        self.legoSet = legoSet
        self.collectionStatus = collectionStatus
        self.collectionListName = initialListName
        self.storePrice = initialStorePrice
        self.storePriceFetchedAt = initialStorePriceFetchedAt
        self.isInWishlist = initialIsInWishlist
        self.repository = repository
        self.bricksetRepository = bricksetRepository
        self.legoStoreRepository = legoStoreRepository
        self.priceRepository = priceRepository
        // loadStorePriceIfNeeded() always fires a fetch in this case (no fetchedAt to compare
        // against staleAfter) — start the spinner here so the very first render already shows
        // it's checking, instead of flashing "Pas encore vérifié" for one frame first.
        if initialStorePrice == nil && initialStorePriceFetchedAt == nil {
            isLoadingStorePrice = true
        }
    }

    /// Auto-fetch only when there's no cached price yet, or it's older than `staleAfter` — the
    /// WKWebView fetch is slow (solves a real Cloudflare challenge, several seconds), so this
    /// isn't re-run on every SetDetail open the way collection-status reconciliation is.
    /// "Indisponible" (no amount) is never treated as a fresh cache hit — an unavailable price
    /// is always re-checked live, since it's exactly the state most likely to have changed.
    @MainActor
    func loadStorePriceIfNeeded(staleAfter: TimeInterval = 24 * 60 * 60) async {
        if let storePriceFetchedAt, storePrice?.amount != nil,
           Date().timeIntervalSince(storePriceFetchedAt) < staleAfter {
            return
        }
        await refreshStorePrice()
    }

    @MainActor
    func refreshStorePrice() async {
        guard NetworkMonitor.shared.isConnected else {
            // `isLoadingStorePrice` may already be `true` from `init` (it pre-sets the spinner
            // when there's no cached price yet, before this function ever runs) — must be reset
            // here too, or the price section spins forever instead of showing "Hors-ligne".
            isLoadingStorePrice = false
            storePriceErrorMessage = "Hors-ligne"
            return
        }
        isLoadingStorePrice = true
        storePriceErrorMessage = nil
        defer { isLoadingStorePrice = false }
        do {
            storePrice = try await legoStoreRepository.fetchStorePrice(setNum: legoSet.setNum)
            storePriceFetchedAt = Date()
        } catch is CancellationError {
            // The view was dismissed mid-fetch — this isn't a real failure, don't show one.
        } catch {
            storePriceErrorMessage = (error as? LocalizedError)?.errorDescription ?? "Prix indisponible"
        }
    }

    /// Seeds prices from the local cache without hitting the network. Call
    /// before `loadPrices()` so cached values show up instantly.
    func setCachedPrices(_ quotes: [PriceQuote]) {
        priceQuotes = quotes
    }

    @MainActor
    func loadPrices() async {
        guard NetworkMonitor.shared.isConnected else { return }
        pricesLoading = true
        defer { pricesLoading = false }
        // Connectivity is confirmed above, so an empty result here means every source was
        // genuinely re-checked and came back unavailable — replace unconditionally so stale
        // cached prices don't linger and mask a source going "Indisponible" (see issue on
        // Amazon/BrickLink not refreshing like the Lego.com store price does).
        priceQuotes = await priceRepository.fetchPrices(for: legoSet)
    }

    /// Auto-refresh scraped prices only when every source already has a cached quote and the
    /// oldest one is younger than `staleAfter` — mirrors `loadStorePriceIfNeeded`'s time-based
    /// check instead of only refreshing when the cache is completely empty, which let a source
    /// that went "Indisponible" show its last known price for up to 7 days (the hard cache TTL).
    /// A missing source is never treated as a fresh cache hit — "Indisponible" is always
    /// re-checked live rather than trusted from cache, since it's the state most likely to
    /// have changed.
    @discardableResult
    @MainActor
    func loadPricesIfNeeded(staleAfter: TimeInterval = 24 * 60 * 60) async -> Bool {
        let hasEverySource = PriceSource.allCases.allSatisfy { source in
            priceQuotes.contains { $0.source == source }
        }
        if hasEverySource, let oldestFetch = priceQuotes.map(\.fetchedAt).min(),
           Date().timeIntervalSince(oldestFetch) < staleAfter {
            return false
        }
        await loadPrices()
        return true
    }

    var isInCollection: Bool {
        if case .inCollection = collectionStatus { return true }
        return false
    }

    var statusIsUnknown: Bool {
        if case .unknown = collectionStatus { return true }
        return false
    }

    @MainActor
    func addToList(listId: Int, listName: String) async {
        await perform {
            try await self.repository.addSetToList(setNum: self.legoSet.setNum, listId: listId)
            self.toastMessage = "Set ajouté à \(listName)"
            await self.refreshCollectionStatus()
        }
    }

    @MainActor
    func moveToList(toListId: Int, toListName: String) async {
        guard case .inCollection(let userSet) = collectionStatus, let fromListId = userSet.listId else { return }
        await perform {
            try await self.repository.moveSetToList(setNum: self.legoSet.setNum, fromListId: fromListId, toListId: toListId)
            self.toastMessage = "Set déplacé vers \(toListName)"
            await self.refreshCollectionStatus()
        }
    }

    /// Absolute quantity update, scoped to the set's current list (issue #115) — no-ops if the set
    /// isn't in the collection, its list is unknown (same precondition `moveToList` already needs),
    /// the value didn't change, or it drops below 1 (removing a set already has its own explicit,
    /// confirmed action; the stepper isn't the place to trigger that side effect).
    @MainActor
    func updateQuantity(to newQuantity: Int) async {
        guard case .inCollection(let userSet) = collectionStatus, let listId = userSet.listId,
              newQuantity != userSet.quantity, newQuantity >= 1 else { return }
        await perform {
            try await self.repository.updateSetQuantity(setNum: self.legoSet.setNum, listId: listId, quantity: newQuantity)
            await self.refreshCollectionStatus()
        }
    }

    @MainActor
    func removeFromCollection() async {
        await perform {
            try await self.repository.removeSetFromCollection(setNum: self.legoSet.setNum)
            self.collectionStatus = .notInCollection
            self.collectionListName = nil
            self.toastMessage = "Set retiré de la collection"
        }
    }

    /// Toggles this set's Brickset `wanted` flag — see `AGENTS.md`/issue #6 on why the wishlist
    /// lives on Brickset rather than as a Rebrickable setlist (which would count it as *owned*).
    /// Distinguishes `.missingCredentials` from other failures so the UI can point at Settings
    /// specifically, rather than a generic error, when no Brickset account is linked yet.
    @MainActor
    func toggleWishlist() async {
        guard NetworkMonitor.shared.isConnected else {
            errorMessage = UserMessage.offlineStatus
            return
        }
        isWishlistLoading = true
        errorMessage = nil
        defer { isWishlistLoading = false }
        do {
            if isInWishlist {
                try await bricksetRepository.removeFromWishlist(setNum: legoSet.setNum)
                isInWishlist = false
                toastMessage = "Set retiré de ta liste cadeaux"
            } else {
                try await bricksetRepository.addToWishlist(setNum: legoSet.setNum)
                isInWishlist = true
                toastMessage = "Set ajouté à ta liste cadeaux"
            }
        } catch APIError.missingCredentials {
            errorMessage = String(localized: "Lie ton compte Brickset dans Réglages pour utiliser la liste cadeaux.")
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = String(localized: "Une erreur est survenue")
        }
    }

    /// Reconciles a cache-displayed status with the live one, without flashing a spinner or
    /// error UI — if the fetch fails (e.g. offline), keep showing whatever the cache had.
    @MainActor
    func silentlyReconcileCollectionStatus() async {
        guard NetworkMonitor.shared.isConnected else { return }
        do {
            let userSet = try await repository.fetchUserSet(setNum: legoSet.setNum)
            collectionStatus = userSet.map(CollectionStatus.inCollection) ?? .notInCollection
            await refreshCollectionListName()
        } catch {
            // Offline or transient failure — the cached status stays on screen.
        }
    }

    @MainActor
    func retryCollectionStatus() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await refreshCollectionStatus()
    }

    @MainActor
    private func refreshCollectionStatus() async {
        guard NetworkMonitor.shared.isConnected else {
            collectionStatus = .unknown(UserMessage.offlineStatus)
            collectionListName = nil
            return
        }
        do {
            let userSet = try await repository.fetchUserSet(setNum: legoSet.setNum)
            collectionStatus = userSet.map(CollectionStatus.inCollection) ?? .notInCollection
            await refreshCollectionListName()
        } catch let error as APIError {
            collectionStatus = .unknown(error.errorDescription ?? UserMessage.unknownCollectionStatus)
            collectionListName = nil
        } catch {
            collectionStatus = .unknown(UserMessage.unknownCollectionStatus)
            collectionListName = nil
        }
    }

    @MainActor
    private func refreshCollectionListName() async {
        guard case .inCollection(let userSet) = collectionStatus, let listId = userSet.listId else {
            collectionListName = nil
            return
        }
        let lists = (try? await repository.fetchUserSetLists()) ?? []
        collectionListName = lists.first(where: { $0.id == listId })?.name
    }

    @MainActor
    private func perform(_ operation: @escaping () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Une erreur est survenue"
        }
    }
}
