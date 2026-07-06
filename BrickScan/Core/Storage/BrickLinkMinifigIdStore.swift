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
/// has no matching BrickLink set entry). Read-only since #111: entries were originally written
/// by scraping the item's Rebrickable page (the Rebrickable API doesn't expose this mapping),
/// but that scrape was itself a compliance violation (5.2.2, hidden `WKWebView`) no smaller in
/// kind than the BrickLink price-guide scrape #111 removed, so it wasn't replicated — see
/// `BrickLinkPriceRepository`'s doc comment. Existing entries (from before #111, on devices that
/// already resolved a given minifig) keep working; a `fig-…` id never seen before this change has
/// no BrickLink price, like any other source with no data for that item.
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

    func clearAll() {
        refsBySetNum = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }
}
