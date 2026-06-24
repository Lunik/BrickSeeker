import Foundation
import Observation

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

    private let repository: RebrickableRepositoryProtocol
    private let legoStoreRepository: LegoStoreRepositoryProtocol
    private let priceRepository: PriceRepositoryProtocol

    init(
        legoSet: LegoSet,
        collectionStatus: CollectionStatus,
        initialListName: String? = nil,
        initialStorePrice: StorePrice? = nil,
        initialStorePriceFetchedAt: Date? = nil,
        repository: RebrickableRepositoryProtocol = RebrickableRepository(),
        legoStoreRepository: LegoStoreRepositoryProtocol = LegoStoreRepository(),
        priceRepository: PriceRepositoryProtocol = PriceRepository()
    ) {
        self.legoSet = legoSet
        self.collectionStatus = collectionStatus
        self.collectionListName = initialListName
        self.storePrice = initialStorePrice
        self.storePriceFetchedAt = initialStorePriceFetchedAt
        self.repository = repository
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
    @MainActor
    func loadStorePriceIfNeeded(staleAfter: TimeInterval = 24 * 60 * 60) async {
        if let storePriceFetchedAt, Date().timeIntervalSince(storePriceFetchedAt) < staleAfter {
            return
        }
        await refreshStorePrice()
    }

    @MainActor
    func refreshStorePrice() async {
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
        pricesLoading = true
        defer { pricesLoading = false }
        let quotes = await priceRepository.fetchPrices(for: legoSet)
        if !quotes.isEmpty {
            priceQuotes = quotes
        }
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
    func removeFromCollection() async {
        await perform {
            try await self.repository.removeSetFromCollection(setNum: self.legoSet.setNum)
            self.collectionStatus = .notInCollection
            self.collectionListName = nil
            self.toastMessage = "Set retiré de la collection"
        }
    }

    /// Reconciles a cache-displayed status with the live one, without flashing a spinner or
    /// error UI — if the fetch fails (e.g. offline), keep showing whatever the cache had.
    @MainActor
    func silentlyReconcileCollectionStatus() async {
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
        do {
            let userSet = try await repository.fetchUserSet(setNum: legoSet.setNum)
            collectionStatus = userSet.map(CollectionStatus.inCollection) ?? .notInCollection
            await refreshCollectionListName()
        } catch let error as APIError {
            collectionStatus = .unknown(error.errorDescription ?? "Statut de collection inconnu")
            collectionListName = nil
        } catch {
            collectionStatus = .unknown("Statut de collection inconnu")
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
