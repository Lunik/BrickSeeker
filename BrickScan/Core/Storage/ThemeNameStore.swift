import Foundation

/// Caches Rebrickable's theme id → name table, downloaded from the same unauthenticated
/// static-downloads source as `OfflineCatalogStore`'s sets dump (`cdn.rebrickable.com/media/
/// downloads/`). Unlike that dump this file is tiny (~5 KB compressed, ~700 rows) and the data
/// barely changes (LEGO adds a handful of themes a year), so — unlike the deliberately-explicit,
/// user-triggered catalogue/price syncs elsewhere in this app — it's fetched silently on first
/// need and just re-checked for staleness afterwards; there's no per-set scraping cost to be
/// polite about here, just one small GET.
final class ThemeNameStore: @unchecked Sendable {
    static let shared = ThemeNameStore()

    static let downloadURL = URL(string: "https://cdn.rebrickable.com/media/downloads/themes.csv.gz")!
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

    /// Downloads/refreshes the table if it's never been fetched or is stale; no-ops otherwise, so
    /// callers can invoke this unconditionally whenever the Statistics screen appears. Best-effort:
    /// on failure, whatever's already cached (possibly nothing) is left in place and callers fall
    /// back to showing the raw theme id.
    func refreshIfNeeded() async {
        if let downloadedAt, Date().timeIntervalSince(downloadedAt) < Self.staleAfter, !namesByThemeId.isEmpty {
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.downloadURL)
            let csv = try OfflineCatalogStore.gunzip(data)
            let names = try Self.parseCSV(csv)
            guard !names.isEmpty else { return }

            namesByThemeId = names
            let now = Date()
            downloadedAt = now

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try encoder.encode(Snapshot(namesByThemeId: names, downloadedAt: now))
            try encoded.write(to: snapshotURL, options: .atomic)
        } catch {
            // Offline or CDN hiccup — keep whatever's cached and try again next time.
        }
    }

    /// Parses the `id,name,parent_id` columns of Rebrickable's `themes.csv.gz` dump. Only `id`
    /// and `name` are needed here — theme hierarchy (`parent_id`) isn't used by this app's flat
    /// "group owned sets by theme id" breakdown. Line splitting and RFC 4180 quote handling live
    /// in the shared `CSV` helper (also used by `OfflineCatalogStore`).
    private static func parseCSV(_ data: Data) throws -> [Int: String] {
        var names: [Int: String] = [:]
        for fields in try CSV.records(in: data) {
            guard fields.count >= 2, let id = Int(fields[0]) else { continue }
            names[id] = fields[1]
        }
        return names
    }
}
