import Foundation
import SwiftData

/// Drives a one-set-at-a-time price refresh across the user's whole collection, started
/// explicitly from Settings — never automatically. A singleton (like
/// `OfflineCatalogStore.shared`/`HeadlessWebScraper.shared`) so the run's state survives
/// `SettingsView` being dismissed and reopened, and so a second `start()` call while one
/// is already running just observes the same job instead of racing it.
///
/// Sets are processed strictly sequentially with a delay between each — `PriceRepository`
/// and `LegoStoreRepository` already drive hidden `WKWebView`s that solve Cloudflare
/// challenges; running dozens of those concurrently across a whole collection risks getting
/// flagged as abusive traffic, so this deliberately trades speed for being polite to the
/// scraped sites.
///
/// Mirrors `OfflineCatalogStore`'s pause/resume pattern: there is no background execution
/// here (see AGENTS.md / issue #5 on why this app avoids `BGAppRefreshTask`-style background
/// work) — `SettingsViewModel.handleScenePhaseChange` calls `cancelPreservingProgress()` when
/// the app backgrounds, and the next `start()` call (after the user reopens the app and taps
/// the button again) resumes from the persisted queue instead of restarting from zero.
@MainActor
@Observable
final class CollectionPriceUpdater {
    static let shared = CollectionPriceUpdater()

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0

    private let queueURL: URL
    private var cancelRequested = false

    private struct Queue: Codable {
        var remaining: [LegoSet]
        var total: Int
    }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.queueURL = directory.appendingPathComponent("CollectionPriceUpdateQueue.json")
        if let queue = Self.loadQueue(at: queueURL) {
            self.total = queue.total
            self.done = queue.total - queue.remaining.count
        }
    }

    var hasResumableUpdate: Bool {
        FileManager.default.fileExists(atPath: queueURL.path)
    }

    /// Runs (or resumes) the batch. `allSets` seeds a fresh run — ignored if a resumable
    /// queue already exists on disk, in which case that queue's own sets/total are used
    /// instead. `persist` is the caller's hook to actually write each set's fetched prices
    /// into SwiftData (this class has no `ModelContext` of its own).
    ///
    /// Returns `completed: true` and the collection's total if the whole queue drained
    /// (caller should fire the completion notification), `completed: false` if the run was
    /// cancelled (paused) mid-way. `total` is captured before `clearQueue()` resets it, so
    /// it's still meaningful even when `completed` is true.
    func start(
        allSets: [LegoSet],
        priceRepository: PriceRepositoryProtocol,
        legoStoreRepository: LegoStoreRepositoryProtocol,
        persist: @escaping @MainActor (LegoSet, [PriceQuote], StorePrice?) async -> Void
    ) async -> (completed: Bool, total: Int) {
        guard !isRunning else { return (false, total) }

        var queue = Self.loadQueue(at: queueURL) ?? Queue(remaining: allSets, total: allSets.count)
        total = queue.total
        done = queue.total - queue.remaining.count
        isRunning = true
        cancelRequested = false
        defer { isRunning = false }

        while !queue.remaining.isEmpty {
            if cancelRequested {
                saveQueue(queue)
                return (false, queue.total)
            }

            let legoSet = queue.remaining.removeFirst()
            let quotes = await priceRepository.fetchPrices(for: legoSet)
            let storePrice = try? await legoStoreRepository.fetchStorePrice(setNum: legoSet.setNum)
            await persist(legoSet, quotes, storePrice)

            saveQueue(queue)
            done = queue.total - queue.remaining.count

            if !queue.remaining.isEmpty {
                try? await Task.sleep(for: .seconds(1.5))
            }
        }

        let finishedTotal = queue.total
        clearQueue()
        return (true, finishedTotal)
    }

    /// Resumes a previously paused run with no user interaction — called when the app
    /// becomes active again (see `BrickScanApp`'s `scenePhase` observer) so the user doesn't
    /// have to reopen Settings and tap "Reprendre" themselves. No-ops if there's nothing to
    /// resume or a run is already in flight.
    @discardableResult
    func resumeIfNeeded(
        modelContext: ModelContext,
        priceRepository: PriceRepositoryProtocol = PriceRepository(),
        legoStoreRepository: LegoStoreRepositoryProtocol = LegoStoreRepository()
    ) async -> Bool {
        guard hasResumableUpdate, !isRunning else { return false }
        let result = await start(
            allSets: [],
            priceRepository: priceRepository,
            legoStoreRepository: legoStoreRepository,
            persist: Self.persistClosure(modelContext: modelContext)
        )
        if result.completed {
            PriceUpdateNotifier.notifyCompleted(total: result.total)
        }
        return result.completed
    }

    /// Stops the run after the set currently in flight finishes — the queue file is
    /// already up to date after every set, so there's nothing extra to persist here, just
    /// the cooperative flag the loop checks between sets.
    func cancelPreservingProgress() {
        guard isRunning else { return }
        cancelRequested = true
    }

    /// Shared `persist` hook for `start()`/`resumeIfNeeded()` — writes a set's fetched
    /// prices into SwiftData via the existing `LocalRepository.cachePrices`/`cacheStorePrice`
    /// (which already records price history, see #24).
    static func persistClosure(modelContext: ModelContext) -> @MainActor (LegoSet, [PriceQuote], StorePrice?) async -> Void {
        { legoSet, quotes, storePrice in
            let repo = LocalRepository(modelContext: modelContext)
            repo.cachePrices(quotes, setNum: legoSet.setNum)
            if let storePrice {
                repo.cacheStorePrice(setNum: legoSet.setNum, price: storePrice)
            }
        }
    }

    private func saveQueue(_ queue: Queue) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private func clearQueue() {
        try? FileManager.default.removeItem(at: queueURL)
        total = 0
        done = 0
    }

    private static func loadQueue(at url: URL) -> Queue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Queue.self, from: data)
    }
}
