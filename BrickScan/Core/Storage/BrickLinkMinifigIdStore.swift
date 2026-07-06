import Foundation

/// A resolved BrickLink catalog reference — the single-letter catalog type BrickLink uses in its
/// URLs (`S` for set, `M` for minifig, `P` for part, `G` for gear, …) plus the item's ID within
/// that catalog (e.g. `S`+`71039-1`, or `M`+`oct033`).
struct BrickLinkCatalogRef: Codable, Equatable, Hashable {
    let type: String
    let id: String
}

/// Caches the Rebrickable set/minifig number → resolved BrickLink catalog reference (e.g.
/// `fig-004396` → `M`+`oct033`, or `71039-6` → `M`+`sh1027` when the CMF box's own set number
/// has no matching BrickLink set entry), resolved by cross-referencing official APIs (see
/// `BrickLinkPriceRepository.resolveViaCatalogCrossReference`) — neither the Rebrickable API nor
/// the BrickLink API exposes this mapping directly. The mapping is permanent (BrickLink never
/// reassigns a catalog ID), so entries never expire; this only avoids re-resolving on every price
/// refresh for the same item. Replacing the previous Rebrickable-page scrape here is the #117
/// remediation (App Store 5.2.2 / 2.3.1(a)), out of scope for #111 which replaced the BrickLink
/// price-guide scrape specifically.
///
/// An `actor` (not a `@MainActor` class like `LocalRepository`) since `BrickLinkPriceRepository`
/// itself is a plain `Sendable` struct with no main-actor affinity, and multiple items' prices
/// can be resolved concurrently (see `PriceRepository`'s task group).
actor BrickLinkMinifigIdStore {
    static let shared = BrickLinkMinifigIdStore()

    /// How long a *failed* resolution is remembered before we retry it. The cross-reference is
    /// several throttled API calls and ~half of minifigs legitimately don't resolve, so without a
    /// negative cache a collection-wide price refresh would re-run every unresolvable item each
    /// time. It's a TTL, not permanent: the mapping can become resolvable later (BrickLink adds
    /// inventory data, or the resolver improves / gains a manual-entry fallback), so we retry after
    /// this interval.
    static let missRetryInterval: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    private let fileURL: URL
    private let missesFileURL: URL
    private var refsBySetNum: [String: BrickLinkCatalogRef]
    /// setNum → when we last failed to resolve it (see `missRetryInterval`). Kept in a separate file
    /// so the resolved-id format (`BrickLinkMinifigIds.json`) stays untouched/backward-compatible.
    private var missAtBySetNum: [String: Date]

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("BrickLinkMinifigIds.json")
        self.missesFileURL = directory.appendingPathComponent("BrickLinkMinifigMisses.json")
        if let data = try? Data(contentsOf: fileURL),
           let refs = try? JSONDecoder().decode([String: BrickLinkCatalogRef].self, from: data) {
            self.refsBySetNum = refs
        } else {
            self.refsBySetNum = [:]
        }
        if let data = try? Data(contentsOf: missesFileURL),
           let misses = try? JSONDecoder().decode([String: Date].self, from: data) {
            self.missAtBySetNum = misses
        } else {
            self.missAtBySetNum = [:]
        }
    }

    func lookup(setNum: String) -> BrickLinkCatalogRef? {
        refsBySetNum[setNum]
    }

    /// Whether we failed to resolve this item within `missRetryInterval` — callers should skip the
    /// (expensive) re-resolution and treat it as unresolved for now.
    func hasRecentMiss(setNum: String) -> Bool {
        guard let missedAt = missAtBySetNum[setNum] else { return false }
        return Date().timeIntervalSince(missedAt) < Self.missRetryInterval
    }

    func save(setNum: String, ref: BrickLinkCatalogRef) {
        refsBySetNum[setNum] = ref
        try? JSONEncoder().encode(refsBySetNum).write(to: fileURL, options: .atomic)
        // A now-resolved item shouldn't keep a stale miss around.
        if missAtBySetNum.removeValue(forKey: setNum) != nil {
            persistMisses()
        }
    }

    /// Records that resolving `setNum` failed, so we skip retrying it until `missRetryInterval`
    /// passes. Only genuine "can't resolve" outcomes should call this — never transient
    /// network/throttle errors, or we'd suppress a resolvable item for 30 days over a blip.
    func recordMiss(setNum: String) {
        let now = Date()
        missAtBySetNum[setNum] = now
        // Drop expired entries so the file stays bounded.
        missAtBySetNum = missAtBySetNum.filter { now.timeIntervalSince($0.value) < Self.missRetryInterval }
        persistMisses()
    }

    func clearAll() {
        refsBySetNum = [:]
        missAtBySetNum = [:]
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: missesFileURL)
    }

    private func persistMisses() {
        try? JSONEncoder().encode(missAtBySetNum).write(to: missesFileURL, options: .atomic)
    }
}
