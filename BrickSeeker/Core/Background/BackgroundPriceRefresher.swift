import BackgroundTasks
import Foundation
import Observation
import SwiftData

/// How the sets under watch are spread over time (#230). The user's ask was "about one set per
/// hour, in rotation, with each set's refresh date drawn at random across a week" — iOS grants no
/// such cadence, so the *spread* is kept and the *rate* is dropped: each watched set carries a due
/// date drawn uniformly over the coming 7 days, and every wake-up the system happens to grant
/// processes whatever is due by then.
enum PriceWatchSchedule {
    static let window: TimeInterval = 7 * 24 * 60 * 60

    /// Drawn uniformly over `[now, now + 7 days]`. Callers store it on `CachedSet
    /// .nextPriceRefreshDue` / `PriceAlert.nextRefreshDue`.
    static func nextDueDate(from now: Date = Date()) -> Date {
        now.addingTimeInterval(TimeInterval.random(in: 0...window))
    }
}

/// One set the background refresher is allowed to fetch, with the date it comes due.
struct PriceWatchTarget {
    let legoSet: LegoSet
    let dueAt: Date
}

/// Refreshes prices for the watched sets without the app being opened (#230), and evaluates the
/// price alerts of #229 against the result.
///
/// This reverses #5's "no `BGAppRefreshTask`, no periodic background work" on the specific ground
/// that #5 gave for it — "ça ne passe pas à l'échelle avec beaucoup de sets". The scope here is
/// **not** the collection: only the gift list and the sets carrying an enabled `PriceAlert` are
/// ever touched (`LocalRepository.priceWatchTargets()`), which is a handful of sets, not hundreds.
///
/// Two iOS constraints shape the whole design and are not negotiable:
///
/// 1. **There is no guaranteed cadence.** `BGAppRefreshTask` is opportunistic — the system decides,
///    from app usage, battery and network. So nothing here counts wake-ups: each watched set holds
///    a due date (`PriceWatchSchedule`), a wake-up processes a small bounded batch of whatever is
///    overdue, and `catchUpInForeground()` drains the backlog when the app is next opened. That
///    foreground catch-up is what makes the feature work at all on a device that never grants a
///    single background wake-up, so don't remove it as redundant.
/// 2. **Only BrickLink can run here.** lego.com, Amazon and Cdiscount prices come from a hidden
///    `WKWebView`, which per `AGENTS.md` must be inserted into a real `keyWindow` to load and run
///    JS — there is no window in the background. Running a web engine to clear a Cloudflare
///    challenge from a system task would also be squarely against the `app-store-compliance`
///    skill's hard rule #1. So the background pass fetches the **official BrickLink API only**
///    (`BrickLinkOnlyPriceRepository`), and the lego.com retail price keeps being refreshed in the
///    foreground exclusively. Consequence for #229, surfaced in the alert UI: an *occasion* alert
///    is fully served by the background; a *neuf* alert is served only as far as BrickLink neuf.
@Observable
@MainActor
final class BackgroundPriceRefresher {
    static let shared = BackgroundPriceRefresher()

    /// Declared in `project.yml` under `BGTaskSchedulerPermittedIdentifiers` — never in the
    /// generated `Info.plist`, which XcodeGen rewrites.
    /// `nonisolated` because `registerTask()` has to read it from outside the main actor.
    nonisolated static let taskIdentifier = "com.lunik.brickseeker.priceRefresh"

    /// A granted `BGAppRefreshTask` gets roughly 30 seconds. A set costs two signed BrickLink calls,
    /// spaced ≥1 s each by `BrickLinkClient`'s own throttler — so ≈2.5-3 s per set once latency is
    /// counted, and 8 sets sits at ≈20-24 s, inside the budget with margin. Going higher isn't free:
    /// overrunning means the expiration handler cuts the pass (already safe — every *completed* set
    /// is persisted and rescheduled as it goes) but iOS also scores the app worse for missing its
    /// deadline, which buys fewer wake-ups later. 8 is the point where the budget is used, not
    /// exceeded.
    private static let backgroundBatchSize = 8
    /// The foreground catch-up has no system deadline, so it can be far larger — this is what
    /// actually drains a backlog after the app has been closed for a while. Still bounded: at ≈2.5 s
    /// per set, 40 is roughly a 100 s silent run, which is the most that's reasonable to keep going
    /// while the user is actually using the app.
    private static let foregroundBatchSize = 40

    private static let lastRunAtKey = "BackgroundPriceRefreshLastRunAt"
    private static let lastRunCountKey = "BackgroundPriceRefreshLastRunCount"
    /// Read via `@AppStorage` in `BackgroundRefreshSection`; mirrored here because this type has no
    /// SwiftUI environment of its own.
    static let wifiOnlyKey = "BackgroundPriceRefreshWiFiOnly"

    /// When a pass last actually processed something, and how many sets it covered. Surfaced in
    /// Réglages: without it there is no way to tell whether iOS is granting wake-ups at all.
    private(set) var lastRunAt: Date?
    private(set) var lastRunProcessedCount = 0
    private(set) var isRunning = false

    private init() {
        lastRunAt = UserDefaults.standard.object(forKey: Self.lastRunAtKey) as? Date
        lastRunProcessedCount = UserDefaults.standard.integer(forKey: Self.lastRunCountKey)
    }

    // MARK: - Scheduling

    /// Registers the task handler. Must run inside `application(_:didFinishLaunchingWithOptions:)`
    /// — `BGTaskScheduler` rejects a registration made after launch finishes.
    nonisolated static func registerTask() {
        // `using: .main` (not `nil`, which means an unspecified private queue) is what makes the
        // `assumeIsolated` below true rather than merely convenient: the handler is guaranteed to
        // run on the main queue, so the `BGTask` — a non-`Sendable` UIKit-era object — never
        // actually crosses a thread, only a compile-time isolation boundary the checker can't see
        // through. That's the whole reason for the `nonisolated(unsafe)` hand-off.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            nonisolated(unsafe) let mainQueueTask = refreshTask
            MainActor.assumeIsolated {
                shared.handle(mainQueueTask)
            }
        }
    }

    /// Asks the system for the next wake-up. A `BGTask` never re-arms itself, so this is called
    /// both when the app backgrounds and at the end of every run.
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        // A floor, not a promise: iOS decides when — and typically much later than this — from app
        // usage, battery and network. Asking for 15 minutes rather than an hour doesn't make the
        // system generous, it just stops *us* from being the thing that blocks an earlier slot the
        // system was willing to give. There is no cost to asking early: a request that isn't
        // granted simply stays pending.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Drops any pending request — used when nothing is under watch, so the system isn't asked to
    /// wake an app that has no work to do.
    func cancelScheduling() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    /// Re-arms or cancels the wake-up depending on whether anything is actually being watched.
    /// Called when the app backgrounds and after every pass.
    func scheduleIfNeeded(modelContext: ModelContext) {
        if LocalRepository(modelContext: modelContext).priceWatchTargets().isEmpty {
            cancelScheduling()
        } else {
            schedule()
        }
    }

    // MARK: - Running

    private func handle(_ task: BGAppRefreshTask) {
        // Re-armed first thing: if the pass below throws, hangs or is expired by the system, the
        // chain must not die with it.
        schedule()

        let work = Task { @MainActor in
            let processed = await runPass(limit: Self.backgroundBatchSize)
            task.setTaskCompleted(success: processed >= 0)
        }

        task.expirationHandler = {
            MainActor.assumeIsolated {
                CollectionPriceUpdater.shared.cancelWatchPass()
            }
            work.cancel()
        }
    }

    /// Drains overdue sets when the app is opened — the safety net for a device that never grants a
    /// background wake-up. Silent by construction: it neither blocks nor touches the UI, and any
    /// alert it trips surfaces the same way a background one would.
    func catchUpInForeground() async {
        _ = await runPass(limit: Self.foregroundBatchSize)
    }

    /// Processes up to `limit` overdue watched sets, oldest due date first. Returns how many were
    /// actually processed.
    @discardableResult
    private func runPass(limit: Int) async -> Int {
        guard !isRunning else { return 0 }
        guard NetworkMonitor.shared.isConnected else { return 0 }
        // "Wi-Fi seulement" (#230's battery/data option). `isExpensive` covers cellular and personal
        // hotspot, which is what the option is actually about.
        if UserDefaults.standard.bool(forKey: Self.wifiOnlyKey), NetworkMonitor.shared.isExpensive {
            return 0
        }
        // BrickLink is the only source usable here (see the type doc), so with no credentials there
        // is nothing this pass can fetch — don't burn a wake-up re-discovering that per set.
        guard KeychainService.shared.brickLinkOAuth1Credentials != nil else { return 0 }

        let modelContext = AppModelContainer.shared.mainContext
        let repository = LocalRepository(modelContext: modelContext)
        let now = Date()
        let due = repository.priceWatchTargets()
            .filter { $0.dueAt <= now }
            .prefix(limit)
            .map(\.legoSet)
        guard !due.isEmpty else { return 0 }

        isRunning = true
        defer { isRunning = false }

        let processed = await CollectionPriceUpdater.shared.runWatchPass(
            sets: due,
            priceRepository: BrickLinkOnlyPriceRepository(),
            persist: CollectionPriceUpdater.watchPassPersistClosure(modelContext: modelContext),
            onProcessed: { legoSet in
                repository.rescheduleWatch(setNum: legoSet.setNum)
            }
        )

        if processed > 0 {
            lastRunAt = Date()
            lastRunProcessedCount = processed
            UserDefaults.standard.set(lastRunAt, forKey: Self.lastRunAtKey)
            UserDefaults.standard.set(processed, forKey: Self.lastRunCountKey)
        }
        scheduleIfNeeded(modelContext: modelContext)
        return processed
    }
}

/// `PriceRepositoryProtocol` restricted to the one source that works without a window: the official
/// BrickLink API over `URLSession` (#230). Deliberately a separate type rather than a flag on
/// `PriceRepository` — "which sources may run here" is a hard compliance/technical boundary, and a
/// boolean parameter is one wrong default away from spinning up a `WKWebView` in a system task.
struct BrickLinkOnlyPriceRepository: PriceRepositoryProtocol {
    private let brickLinkRepository: BrickLinkPriceRepository

    init(brickLinkRepository: BrickLinkPriceRepository = BrickLinkPriceRepository()) {
        self.brickLinkRepository = brickLinkRepository
    }

    func fetchPrices(for legoSet: LegoSet) async -> [PriceQuote] {
        guard await NetworkMonitor.shared.isConnected else { return [] }
        return (try? await brickLinkRepository.fetchPrices(for: legoSet)) ?? []
    }
}
