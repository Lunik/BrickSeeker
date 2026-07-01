import Foundation

/// Caches the Rebrickable `fig-…` → BrickLink `M=` catalog ID mapping (e.g. `fig-004396` →
/// `oct033`), resolved by scraping the minifig's Rebrickable page (see `BrickLinkPriceScraper`) —
/// the Rebrickable API doesn't expose it. The mapping is permanent (BrickLink never reassigns a
/// minifig's catalog ID), so entries never expire; this only avoids re-scraping Rebrickable on
/// every price refresh for the same minifig.
///
/// An `actor` (not a `@MainActor` class like `LocalRepository`) since `BrickLinkPriceScraper`
/// itself is a plain `Sendable` struct with no main-actor affinity, and multiple minifigs' prices
/// can be resolved concurrently (see `PriceRepository`'s task group).
actor BrickLinkMinifigIdStore {
    static let shared = BrickLinkMinifigIdStore()

    private let fileURL: URL
    private var idsBySetNum: [String: String]

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("BrickLinkMinifigIds.json")
        if let data = try? Data(contentsOf: fileURL),
           let ids = try? JSONDecoder().decode([String: String].self, from: data) {
            self.idsBySetNum = ids
        } else {
            self.idsBySetNum = [:]
        }
    }

    func lookup(setNum: String) -> String? {
        idsBySetNum[setNum]
    }

    func save(setNum: String, bricklinkId: String) {
        idsBySetNum[setNum] = bricklinkId
        try? JSONEncoder().encode(idsBySetNum).write(to: fileURL, options: .atomic)
    }

    func clearAll() {
        idsBySetNum = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }
}
