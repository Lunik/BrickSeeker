import Foundation
import Observation

/// Caches Rebrickable's theme id → name table, downloaded from the same unauthenticated
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
    private var downloadedAt: Date?

    private struct Snapshot: Codable {
        let namesByThemeId: [Int: String]
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
                self.downloadedAt = snapshot.downloadedAt
                return
            }
        }
        self.namesByThemeId = [:]
        self.downloadedAt = nil
    }

    /// The display name for a theme, falling back to "Thème #id" until the table has been
    /// downloaded — the single definition of that fallback (it used to exist at 4 call sites).
    func displayName(forThemeId themeId: Int) -> String {
        namesByThemeId[themeId] ?? "Thème #\(themeId)"
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
        guard let result = await Task.detached(priority: .utility) { () -> ([Int: String], Date)? in
            do {
                let (data, _) = try await URLSession.shared.data(from: Self.downloadURL)
                let csv = try OfflineCatalogStore.gunzip(data)
                let names = try Self.parseCSV(csv)
                guard !names.isEmpty else { return nil }

                let now = Date()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let encoded = try encoder.encode(Snapshot(namesByThemeId: names, downloadedAt: now))
                try encoded.write(to: snapshotURL, options: .atomic)
                return (names, now)
            } catch {
                // Offline or CDN hiccup — keep whatever's cached and try again next time.
                return nil
            }
        }.value else { return }

        namesByThemeId = result.0
        downloadedAt = result.1
    }

    /// Parses the `id,name,parent_id` columns of Rebrickable's `themes.csv.gz` dump. Only `id`
    /// and `name` are needed here — theme hierarchy (`parent_id`) isn't used by this app's flat
    /// "group owned sets by theme id" breakdown. Line splitting and RFC 4180 quote handling live
    /// in the shared `CSV` helper (also used by `OfflineCatalogStore`).
    nonisolated private static func parseCSV(_ data: Data) throws -> [Int: String] {
        var names: [Int: String] = [:]
        for fields in try CSV.records(in: data) {
            guard fields.count >= 2, let id = Int(fields[0]) else { continue }
            names[id] = fields[1]
        }
        return names
    }
}
