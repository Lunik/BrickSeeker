import Foundation

/// A resolved BrickLink catalog reference — the single-letter catalog type BrickLink uses in its
/// URLs (`S` for set, `M` for minifig, `P` for part, `G` for gear, …) plus the item's ID within
/// that catalog (e.g. `S`+`71039-1`, or `M`+`oct033`).
struct BrickLinkCatalogRef: Codable, Equatable {
    let type: String
    let id: String
}

/// Caches the Rebrickable set/minifig number → resolved BrickLink catalog reference (e.g.
/// `fig-004396` → `M`+`oct033`, or `71039-6` → `M`+`sh1027` when the CMF box's own set number
/// has no matching BrickLink set entry), resolved by scraping the item's Rebrickable page (see
/// `BrickLinkPriceScraper`) — the Rebrickable API doesn't expose this mapping. The mapping is
/// permanent (BrickLink never reassigns a catalog ID), so entries never expire; this only avoids
/// re-scraping Rebrickable on every price refresh for the same item.
///
/// An `actor` (not a `@MainActor` class like `LocalRepository`) since `BrickLinkPriceScraper`
/// itself is a plain `Sendable` struct with no main-actor affinity, and multiple items' prices
/// can be resolved concurrently (see `PriceRepository`'s task group).
actor BrickLinkMinifigIdStore {
    static let shared = BrickLinkMinifigIdStore()

    private let fileURL: URL
    private var refsBySetNum: [String: BrickLinkCatalogRef]

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("BrickLinkMinifigIds.json")
        if let data = try? Data(contentsOf: fileURL),
           let refs = try? JSONDecoder().decode([String: BrickLinkCatalogRef].self, from: data) {
            self.refsBySetNum = refs
        } else {
            self.refsBySetNum = [:]
        }
    }

    func lookup(setNum: String) -> BrickLinkCatalogRef? {
        refsBySetNum[setNum]
    }

    func save(setNum: String, ref: BrickLinkCatalogRef) {
        refsBySetNum[setNum] = ref
        try? JSONEncoder().encode(refsBySetNum).write(to: fileURL, options: .atomic)
    }

    func clearAll() {
        refsBySetNum = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }
}
