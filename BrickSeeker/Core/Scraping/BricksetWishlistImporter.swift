import Foundation

/// Drives a one-set-at-a-time import of a Rebrickable sets CSV (see `RebrickableSetsCSVParser`)
/// into the Brickset wishlist — the mass-import path for issue #6. Mirrors
/// `CollectionPriceUpdater`'s persisted-queue pause/resume (so backgrounding mid-import doesn't
/// lose progress) and its sequential, throttled pacing (so a big list doesn't hammer Brickset).
@MainActor
@Observable
final class BricksetWishlistImporter {
    static let shared = BricksetWishlistImporter()

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0

    struct Summary: Equatable, Codable {
        var added = 0
        var alreadyWanted = 0
        var notFoundOnBrickset: [String] = []
    }

    private let queueURL: URL
    private var cancelRequested = false

    private struct Queue: Codable {
        var remaining: [String]
        var total: Int
        var summary: Summary
    }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.queueURL = directory.appendingPathComponent("BricksetWishlistImportQueue.json")
        if let queue = Self.loadQueue(at: queueURL) {
            self.total = queue.total
            self.done = queue.total - queue.remaining.count
        }
    }

    var hasResumableImport: Bool {
        FileManager.default.fileExists(atPath: queueURL.path)
    }

    /// Imports `setNums` (already parsed from a user-picked CSV — see
    /// `RebrickableSetsCSVParser`) one at a time. Ignored (the on-disk queue wins) if a resumable
    /// import already exists — same convention as `CollectionPriceUpdater.start`. A real failure
    /// (offline, missing/expired Brickset credentials, Brickset outage) saves progress and
    /// rethrows rather than being folded into the per-set summary, since it isn't a per-set
    /// condition like "not on Brickset" is.
    func start(
        setNums: [String],
        repository: BricksetRepositoryProtocol
    ) async throws -> Summary {
        guard !isRunning else { return Summary() }

        var queue = Self.loadQueue(at: queueURL) ?? Queue(remaining: setNums, total: setNums.count, summary: Summary())

        total = queue.total
        done = queue.total - queue.remaining.count
        isRunning = true
        cancelRequested = false
        defer { isRunning = false }

        while !queue.remaining.isEmpty {
            if cancelRequested {
                saveQueue(queue)
                return queue.summary
            }

            let setNum = queue.remaining[0]
            do {
                let outcome = try await repository.addToWishlistIfNeeded(setNum: setNum)
                switch outcome {
                case .added: queue.summary.added += 1
                case .alreadyWanted: queue.summary.alreadyWanted += 1
                case .notFoundOnBrickset: queue.summary.notFoundOnBrickset.append(setNum)
                }
                queue.remaining.removeFirst()
            } catch {
                saveQueue(queue)
                throw error
            }

            saveQueue(queue)
            done = queue.total - queue.remaining.count

            if !queue.remaining.isEmpty {
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let finishedSummary = queue.summary
        clearQueue()
        return finishedSummary
    }

    /// Stops the run after the set currently in flight finishes — the queue file is already up
    /// to date after every set, so there's nothing extra to persist here.
    func cancelPreservingProgress() {
        guard isRunning else { return }
        cancelRequested = true
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
