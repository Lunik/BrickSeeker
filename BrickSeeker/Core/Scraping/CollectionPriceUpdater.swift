import Foundation
import SwiftData

/// Result of `CollectionPriceUpdater.refreshPrices(for:...)` — the selection-scoped "actions
/// menu" entry point used by Collection/History/Wishlist (#141).
enum SelectionPriceRefreshOutcome {
    /// The queue fully drained (or there was nothing to refresh).
    case completed
    /// Another run (global or a different selection) was already in flight, or a paused
    /// full-collection queue is waiting to be resumed — starting now would have silently
    /// hijacked or resumed that other job instead of refreshing this selection.
    case busy
    /// The run was paused mid-way (e.g. the app backgrounded) before finishing this selection.
    case cancelled
}

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
/// Mirrors `OfflineCatalogStore`'s pause/resume pattern: this **manual** batch has no background
/// execution — `SettingsViewModel.handleScenePhaseChange` calls `cancelPreservingProgress()` when
/// the app backgrounds, and the next `start()` call (after the user reopens the app and taps
/// the button again) resumes from the persisted queue instead of restarting from zero.
///
/// `runWatchPass` (#230) is the one thing here that *does* run in the background, and it is
/// deliberately kept on a separate track: its own `isRunningWatchPass`/`cancelWatchPassRequested`
/// flags, no persisted queue, no `done`/`total`. Reusing this class buys its sequential,
/// politely-spaced loop and its `persistClosure`; sharing `isRunning` would have made the manual
/// batch's pause-on-backgrounding kill the background pass, and made the background pass show up in
/// Réglages as a run the user started. Each guards against the other so the two never overlap.
@MainActor
@Observable
final class CollectionPriceUpdater {
    static let shared = CollectionPriceUpdater()

    private(set) var isRunning = false
    private(set) var isRunningWatchPass = false
    private(set) var done = 0
    private(set) var total = 0
    /// When the last full pass over the collection finished — `nil` until the first one ever
    /// completes. Only set on a natural completion (empty queue), never on a pause, so it
    /// always reflects "the last time every set actually got refreshed", not the last attempt.
    private(set) var lastCompletedAt: Date?

    private let queueURL: URL
    private var cancelRequested = false
    private var cancelWatchPassRequested = false

    /// Delay between two sets, shared by both loops. It exists for the scraped sources; the signed
    /// BrickLink API used by `runWatchPass` doesn't need it, but a few extra seconds spread over a
    /// handful of sets costs nothing and keeps one rule instead of two.
    private static let delayBetweenSets: Duration = .seconds(1.5)

    private static let lastCompletedAtDefaultsKey = "CollectionPriceUpdateLastCompletedAt"

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
        self.lastCompletedAt = UserDefaults.standard.object(forKey: Self.lastCompletedAtDefaultsKey) as? Date
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
        guard !isRunning, !isRunningWatchPass else { return (false, total) }

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
            // lego.com never lists a minifig on its own — only BrickLink prices it (issue #175).
            let storePrice = legoSet.setNum.isMinifig
                ? nil
                : try? await legoStoreRepository.fetchStorePrice(setNum: legoSet.setNum)
            await persist(legoSet, quotes, storePrice)

            saveQueue(queue)
            done = queue.total - queue.remaining.count

            if !queue.remaining.isEmpty {
                try? await Task.sleep(for: Self.delayBetweenSets)
            }
        }

        let finishedTotal = queue.total
        clearQueue()
        return (true, finishedTotal)
    }

    /// The background/catch-up pass of #230: a **bounded** list of already-selected sets, fetched
    /// from `priceRepository` only — the caller passes `BrickLinkOnlyPriceRepository`, since the
    /// lego.com/Amazon/Cdiscount sources need a `WKWebView` in a real window and cannot run in a
    /// system task (see `BackgroundPriceRefresher`). No `StorePrice` is ever fetched here, hence the
    /// `nil` handed to `persist`.
    ///
    /// Nothing is persisted to the resumable queue file: this pass is re-derivable from the watched
    /// sets' due dates, so an interrupted run simply leaves them due. `onProcessed` fires after each
    /// set's prices are written — that's where the caller re-draws the due date and evaluates the
    /// set's price alerts, so a pass cut short still leaves every *completed* set fully handled.
    ///
    /// Returns how many sets were processed. Refuses to start (returning 0) while the manual batch
    /// is running, rather than interleaving two price loops over the same store.
    @discardableResult
    func runWatchPass(
        sets: [LegoSet],
        priceRepository: PriceRepositoryProtocol,
        persist: @escaping @MainActor (LegoSet, [PriceQuote], StorePrice?) async -> Void,
        onProcessed: @MainActor (LegoSet) -> Void
    ) async -> Int {
        guard !isRunning, !isRunningWatchPass, !sets.isEmpty else { return 0 }

        isRunningWatchPass = true
        cancelWatchPassRequested = false
        defer { isRunningWatchPass = false }

        var processed = 0
        for (index, legoSet) in sets.enumerated() {
            if cancelWatchPassRequested || Task.isCancelled { break }

            let quotes = await priceRepository.fetchPrices(for: legoSet)
            await persist(legoSet, quotes, nil)
            onProcessed(legoSet)
            processed += 1

            if index < sets.count - 1 {
                try? await Task.sleep(for: Self.delayBetweenSets)
            }
        }
        return processed
    }

    /// Stops the watch pass after the set in flight — the counterpart of
    /// `cancelPreservingProgress()` for the background track, called from the `BGTask` expiration
    /// handler. Deliberately does **not** touch the manual batch, and vice versa.
    func cancelWatchPass() {
        guard isRunningWatchPass else { return }
        cancelWatchPassRequested = true
    }

    /// Resumes a previously paused run with no user interaction — called when the app
    /// becomes active again (see `BrickSeekerApp`'s `scenePhase` observer) so the user doesn't
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
            // Stamp "every source tried" even on an empty result, so a set that stays unpriced
            // drops out of "Compléter les prix manquants" instead of looping forever (#194).
            repo.markPricesFetched(setNum: legoSet.setNum)
            // Every refreshed price is an evaluation point for that set's price alerts (#229) —
            // hooked here rather than at each of the four call sites that drive a batch, so a new
            // one can't forget it. No-ops for a set with no alert. The background pass evaluates
            // through its own `onProcessed` instead, after re-drawing the due date.
            PriceAlertEvaluator.evaluate(setNum: legoSet.setNum, in: modelContext)
        }
    }

    /// `persist` hook for `runWatchPass` (#230). Same price caching and alert evaluation as
    /// `persistClosure`, minus `markPricesFetched` — and that omission is the point: the background
    /// pass only ever queries BrickLink, so stamping "every source tried" would make a set with no
    /// lego.com/Amazon/Cdiscount price yet drop out of "Compléter les prix manquants" (#194)
    /// without those sources ever having been asked.
    static func watchPassPersistClosure(modelContext: ModelContext) -> @MainActor (LegoSet, [PriceQuote], StorePrice?) async -> Void {
        { legoSet, quotes, _ in
            let repo = LocalRepository(modelContext: modelContext)
            repo.cachePrices(quotes, setNum: legoSet.setNum)
            PriceAlertEvaluator.evaluate(setNum: legoSet.setNum, in: modelContext)
        }
    }

    /// Shared "refresh prices" bulk action for a user-picked selection — Collection, History
    /// and Wishlist (#141) all funnel their "actions" menu refresh through here instead of each
    /// hand-rolling the same authorize/start/notify sequence. Still routes through this single
    /// global updater (not a parallel pipeline), so `.busy` is returned rather than silently
    /// resuming/racing an unrelated in-flight or paused full-collection run.
    @discardableResult
    func refreshPrices(
        for sets: [LegoSet],
        priceRepository: PriceRepositoryProtocol = PriceRepository(),
        legoStoreRepository: LegoStoreRepositoryProtocol = LegoStoreRepository(),
        persist: @escaping @MainActor (LegoSet, [PriceQuote], StorePrice?) async -> Void
    ) async -> SelectionPriceRefreshOutcome {
        guard !sets.isEmpty else { return .completed }
        guard !isRunning, !isRunningWatchPass, !hasResumableUpdate else { return .busy }

        await PriceUpdateNotifier.requestAuthorizationIfNeeded()

        let result = await start(
            allSets: sets,
            priceRepository: priceRepository,
            legoStoreRepository: legoStoreRepository,
            persist: persist
        )

        if result.completed {
            PriceUpdateNotifier.notifyCompleted(total: result.total)
            return .completed
        }
        return .cancelled
    }

    private func saveQueue(_ queue: Queue) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private func clearQueue() {
        try? FileManager.default.removeItem(at: queueURL)
        total = 0
        done = 0
        lastCompletedAt = Date()
        UserDefaults.standard.set(lastCompletedAt, forKey: Self.lastCompletedAtDefaultsKey)
    }

    private static func loadQueue(at url: URL) -> Queue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Queue.self, from: data)
    }
}
