import Foundation
import Observation

/// Caches Rebrickable's theme table — id → name, plus the `parent_id` hierarchy those names hang
/// off (`isDescendant(_:of:)`, used to hide the whole "Gear" merchandise sub-tree, #224) —
/// downloaded from the same unauthenticated
/// static-downloads source as `OfflineCatalogStore`'s sets dump (`cdn.rebrickable.com/media/
/// downloads/`). Unlike that dump this file is tiny (~5 KB compressed, ~700 rows) and the data
/// barely changes (LEGO adds a handful of themes a year), so — unlike the deliberately-explicit,
/// user-triggered catalogue/price syncs elsewhere in this app — it's fetched silently on first
/// need and just re-checked for staleness afterwards; there's no per-set scraping cost to be
/// polite about here, just one small GET.
///
/// `@Observable` with `namesByThemeId` as a stored property: views/view models read
/// `displayName(forThemeId:)` directly in their bodies and re-render when the CSV lands —
/// no per-consumer mirror copies (there used to be three, see #73).
@Observable
@MainActor
final class ThemeNameStore {
    static let shared = ThemeNameStore()

    nonisolated static let downloadURL = URL(string: "https://cdn.rebrickable.com/media/downloads/themes.csv.gz")!
    private static let staleAfter: TimeInterval = 30 * 24 * 60 * 60

    private let snapshotURL: URL
    private(set) var namesByThemeId: [Int: String]
    /// `theme id → parent theme id` for every theme that has a parent — the dump's third column.
    /// Roots (Technic, City, Gear…) are simply absent. Needed to hide a whole sub-tree by its root
    /// rather than by a hardcoded list of ids that Rebrickable can invalidate at any time (#224).
    private(set) var parentsByThemeId: [Int: Int]
    /// Bumped every time the table is replaced. Consumers that derive something expensive from it
    /// (`WearableFilter`'s "Gear" root lookup, which scans the whole table) use this as a cache
    /// key — an exact one, unlike comparing the table's size, and observable like the table itself
    /// so a refresh still invalidates the cache and re-renders whatever depends on it.
    private(set) var generation = 0
    private var downloadedAt: Date?

    private struct Snapshot: Codable {
        let namesByThemeId: [Int: String]
        /// Optional so a pre-#224 snapshot still decodes — it's treated as "hierarchy unknown"
        /// and forces a re-download (see `init`), rather than silently leaving every theme
        /// parentless and every sub-tree query answering "not a descendant".
        let parentsByThemeId: [Int: Int]?
        let downloadedAt: Date
    }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.snapshotURL = directory.appendingPathComponent("ThemeNamesSnapshot.json")

        if let data = try? Data(contentsOf: snapshotURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
                self.namesByThemeId = snapshot.namesByThemeId
                self.parentsByThemeId = snapshot.parentsByThemeId ?? [:]
                // Names stay usable meanwhile; only the staleness clock is reset, so the next
                // `refreshIfNeeded()` refetches instead of waiting out the 30-day window.
                self.downloadedAt = snapshot.parentsByThemeId == nil ? nil : snapshot.downloadedAt
                return
            }
        }
        self.namesByThemeId = [:]
        self.parentsByThemeId = [:]
        self.downloadedAt = nil
    }

    /// The display name for a theme, falling back to "Thème #id" until the table has been
    /// downloaded — the single definition of that fallback (it used to exist at 4 call sites).
    func displayName(forThemeId themeId: Int) -> String {
        namesByThemeId[themeId] ?? "Thème #\(themeId)"
    }

    /// Whether `themeId` is `ancestorId` itself or sits anywhere below it in the theme tree.
    /// False while the hierarchy isn't loaded — a filter built on this then hides nothing, which
    /// is the safe direction to fail in.
    ///
    /// Rebrickable's dump is a well-formed tree, but a truncated/corrupt one would loop forever
    /// here, so the walk is bounded by the number of known parent links — no chain can be longer.
    func isDescendant(_ themeId: Int, of ancestorId: Int) -> Bool {
        guard namesByThemeId[themeId] != nil else { return false }
        if themeId == ancestorId { return true }
        var current = themeId
        for _ in 0..<parentsByThemeId.count {
            guard let parent = parentsByThemeId[current] else { return false }
            if parent == ancestorId { return true }
            current = parent
        }
        return false
    }

    /// The id of a *top-level* theme by exact name (e.g. "Gear"), or `nil` if the table isn't
    /// loaded or has no such root. Roots only, deliberately: a nested theme can share a name with
    /// an unrelated branch — "Gears" (a Universal Building Set sub-theme, about actual cogs) must
    /// never resolve to the "Gear" merchandise root — and restricting the match to roots keeps
    /// that distinction structural instead of a hardcoded exception.
    func rootThemeId(named name: String) -> Int? {
        namesByThemeId
            .filter { parentsByThemeId[$0.key] == nil && $0.value == name }
            .keys
            .min()
    }

    /// Downloads/refreshes the table if it's never been fetched or is stale; no-ops otherwise, so
    /// callers can invoke this unconditionally whenever the Statistics screen appears. Best-effort:
    /// on failure, whatever's already cached (possibly nothing) is left in place and callers fall
    /// back to showing the raw theme id. The decompress/parse/persist work runs off the main
    /// actor; only the finished table is published back here.
    func refreshIfNeeded() async {
        if let downloadedAt, Date().timeIntervalSince(downloadedAt) < Self.staleAfter, !namesByThemeId.isEmpty {
            return
        }
        let snapshotURL = self.snapshotURL
        guard let result = await Task.detached(priority: .utility) { () -> ([Int: String], [Int: Int], Date)? in
            do {
                let (data, _) = try await URLSession.shared.data(from: Self.downloadURL)
                let csv = try OfflineCatalogStore.gunzip(data)
                let parsed = try Self.parseCSV(csv)
                guard !parsed.names.isEmpty else { return nil }

                let now = Date()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let encoded = try encoder.encode(
                    Snapshot(namesByThemeId: parsed.names, parentsByThemeId: parsed.parents, downloadedAt: now)
                )
                try encoded.write(to: snapshotURL, options: .atomic)
                return (parsed.names, parsed.parents, now)
            } catch {
                // Offline or CDN hiccup — keep whatever's cached and try again next time.
                return nil
            }
        }.value else { return }

        namesByThemeId = result.0
        parentsByThemeId = result.1
        downloadedAt = result.2
        generation += 1
    }

    /// Parses the `id,name,parent_id` columns of Rebrickable's `themes.csv.gz` dump. `parent_id`
    /// is empty for the ~150 top-level themes and is simply left out of `parents` for those, so
    /// "no entry" means "this is a root". Line splitting and RFC 4180 quote handling live in the
    /// shared `CSV` helper (also used by `OfflineCatalogStore`).
    nonisolated private static func parseCSV(_ data: Data) throws -> (names: [Int: String], parents: [Int: Int]) {
        var names: [Int: String] = [:]
        var parents: [Int: Int] = [:]
        for fields in try CSV.records(in: data) {
            guard fields.count >= 2, let id = Int(fields[0]) else { continue }
            names[id] = fields[1]
            if fields.count >= 3, let parentId = Int(fields[2]) {
                parents[id] = parentId
            }
        }
        return (names, parents)
    }
}
