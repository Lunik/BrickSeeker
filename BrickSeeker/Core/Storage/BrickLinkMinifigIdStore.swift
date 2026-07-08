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
    /// Which step of `BrickLinkPriceRepository.resolveViaCatalogCrossReference` aborted for a given
    /// item. Conforms to `Error` so the repository can throw a specific case directly at the point
    /// it gives up, and `recordMiss(setNum:reason:)` persists exactly what was thrown alongside the
    /// miss timestamp — #134's ask to "cache *why* a given fig-… didn't resolve … so failures can
    /// be diagnosed from real user data instead of guessing", inspectable from
    /// `BrickLinkMinifigMisses.json` without re-deriving it.
    enum MissReason: String, Codable, Error {
        /// Rebrickable's inventory for the item returned no parts carrying a BrickLink part id at all.
        case noParts
        /// Every part had a BrickLink id, but none was classified as printed/discriminant.
        case noDiscriminant
        /// Intersecting BrickLink's supersets of the discriminant parts left zero surviving candidates.
        case noCandidates
        /// Intersecting the discriminant parts' supersets left more candidates than
        /// `maxCandidatesToVerify` — the "printed" part matched wasn't actually discriminant (e.g.
        /// a near-universal print shared by hundreds of minifigs), so composition-verifying every
        /// survivor wasn't attempted.
        case tooManyCandidates
        /// No longer thrown (as of #134: ties are now broken by highest composition overlap,
        /// falling back to lowest catalog id) — kept so misses recorded by older app versions still
        /// decode instead of falling back to `unknown`.
        case ambiguousCandidates
        /// No surviving candidate's own BrickLink inventory covered enough of the item's parts to
        /// pass `verifyThreshold`.
        case compositionMismatch
        /// Miss recorded before this diagnostic reason existed, or migrated from the legacy
        /// `[String: Date]` on-disk format — no specific step is known.
        case unknown
    }

    /// A recorded miss: when, and (best-effort) which step aborted.
    private struct MissRecord: Codable {
        let at: Date
        let reason: MissReason
    }

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
    /// setNum → when (and why) we last failed to resolve it (see `missRetryInterval`). Kept in a
    /// separate file so the resolved-id format (`BrickLinkMinifigIds.json`) stays
    /// untouched/backward-compatible.
    private var missBySetNum: [String: MissRecord]

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
           let misses = try? JSONDecoder().decode([String: MissRecord].self, from: data) {
            self.missBySetNum = misses
        } else if let data = try? Data(contentsOf: missesFileURL),
                  let legacyMisses = try? JSONDecoder().decode([String: Date].self, from: data) {
            // Pre-#134 format: bare timestamps, no reason. Migrate in place so existing misses
            // keep their retry TTL instead of every one of them re-resolving on the next refresh.
            self.missBySetNum = legacyMisses.mapValues { MissRecord(at: $0, reason: .unknown) }
        } else {
            self.missBySetNum = [:]
        }
    }

    func lookup(setNum: String) -> BrickLinkCatalogRef? {
        refsBySetNum[setNum]
    }

    /// Whether we failed to resolve this item within `missRetryInterval` — callers should skip the
    /// (expensive) re-resolution and treat it as unresolved for now.
    func hasRecentMiss(setNum: String) -> Bool {
        guard let missedAt = missBySetNum[setNum]?.at else { return false }
        return Date().timeIntervalSince(missedAt) < Self.missRetryInterval
    }

    func save(setNum: String, ref: BrickLinkCatalogRef) {
        refsBySetNum[setNum] = ref
        try? JSONEncoder().encode(refsBySetNum).write(to: fileURL, options: .atomic)
        // A now-resolved item shouldn't keep a stale miss around.
        if missBySetNum.removeValue(forKey: setNum) != nil {
            persistMisses()
        }
    }

    /// Records that resolving `setNum` failed (and, per `reason`, at which step), so we skip
    /// retrying it until `missRetryInterval` passes. Only genuine "can't resolve" outcomes should
    /// call this — never transient network/throttle errors, or we'd suppress a resolvable item for
    /// 30 days over a blip.
    func recordMiss(setNum: String, reason: MissReason) {
        let now = Date()
        missBySetNum[setNum] = MissRecord(at: now, reason: reason)
        // Drop expired entries so the file stays bounded.
        missBySetNum = missBySetNum.filter { now.timeIntervalSince($0.value.at) < Self.missRetryInterval }
        persistMisses()
    }

    func clearAll() {
        refsBySetNum = [:]
        missBySetNum = [:]
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: missesFileURL)
    }

    private func persistMisses() {
        try? JSONEncoder().encode(missBySetNum).write(to: missesFileURL, options: .atomic)
    }
}
