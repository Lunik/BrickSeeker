import Foundation

/// Manages an offline snapshot of the whole LEGO minifig catalogue (issue #170's "Mes minifigs"
/// gallery needs every minifig, owned or not — over 15k of them — which would be far too slow
/// and throttling-prone to page through live via the Rebrickable API). Same philosophy as
/// `OfflineCatalogStore`: a deliberate, user-triggered download (from Settings or the gallery's
/// own empty-state CTA), stored as JSON in Application Support, never fetched silently in the
/// background.
///
/// Rebrickable doesn't expose a minifig's year/theme directly (a minifig has neither — those are
/// properties of the sets it appears in). This store derives them by joining four of
/// Rebrickable's public CSV dumps entirely offline:
/// `minifigs.csv` (fig_num,name,num_parts,img_url) + `inventories.csv` (id,version,set_num) +
/// `inventory_minifigs.csv` (inventory_id,fig_num,quantity) + `inventory_sets.csv`
/// (inventory_id,set_num,quantity) → for each fig_num, the list of set_nums it appears in, then
/// `OfflineCatalogStore`'s already-downloaded `set_num → year/theme_id` table gives the actual
/// values. Per the issue owner's ruling, the *first* containing set found wins — no attempt to
/// pick "the most representative" one.
///
/// `inventory_sets.csv` (issue #177) covers *nested* inventories: a CMF (collectible minifigures)
/// box like `71051-13` doesn't list its minifigs directly in `inventory_minifigs.csv` — its
/// inventory instead references 12 sub-sets `71051-1`…`71051-12` (one per random bag) via
/// `inventory_sets.csv`, and each of *those* sub-sets directly contains one minifig. Without
/// walking that nested level, owning the box never counted as owning the minifigs inside it.
/// The join walks `inventory_sets.csv` recursively (a case-of-boxes can itself nest a box which
/// nests bags) so any ancestor set — at any depth — counts as a containing set.
///
/// `@unchecked Sendable` for the same reason as `OfflineCatalogStore`: `snapshotLoad`/`metadata`
/// are only ever mutated from `@MainActor` members, no concurrent mutation.
final class OfflineMinifigCatalogStore: @unchecked Sendable {
    static let shared = OfflineMinifigCatalogStore()

    private static let minifigsURL = URL(string: "https://cdn.rebrickable.com/media/downloads/minifigs.csv.gz")!
    private static let inventoriesURL = URL(string: "https://cdn.rebrickable.com/media/downloads/inventories.csv.gz")!
    private static let inventoryMinifigsURL = URL(string: "https://cdn.rebrickable.com/media/downloads/inventory_minifigs.csv.gz")!
    private static let inventorySetsURL = URL(string: "https://cdn.rebrickable.com/media/downloads/inventory_sets.csv.gz")!

    /// One set this minifig appears in, plus how many copies of the minifig one instance of that
    /// set contains (`inventory_minifigs.csv`'s `quantity` column) — used to compute how many
    /// copies of the minifig the user owns (`quantityPerSet × ` the owned set's own quantity),
    /// not just whether they own it at all.
    struct ContainingSet: Codable, Hashable, Sendable {
        let setNum: String
        let quantityPerSet: Int
    }

    struct MinifigCatalogEntry: Codable, Identifiable, Hashable, Sendable {
        var id: String { figNum }
        let figNum: String
        let name: String
        let numParts: Int
        let imgUrl: String?
        /// Every set this minifig appears in, first-occurrence order — used both to derive
        /// `year`/`themeId` (first entry) and to test/quantify ownership (any entry owned ⇒
        /// minifig owned).
        let containingSets: [ContainingSet]
        let themeId: Int?
        let year: Int?
    }

    struct Metadata: Codable, Sendable {
        let minifigCount: Int
        let downloadedAt: Date
    }

    private let snapshotURL: URL
    private let metadataURL: URL

    /// Decodes the on-disk snapshot into memory. Created lazily by `snapshotLoadTask()` as a
    /// `Task.detached`, mirroring `OfflineCatalogStore.snapshotLoad` — decoding ~15k entries of
    /// JSON off the main actor so it never blocks the first gallery open.
    private var snapshotLoad: Task<[MinifigCatalogEntry], Never>?
    private(set) var metadata: Metadata?

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.snapshotURL = directory.appendingPathComponent("OfflineMinifigCatalogSnapshot.json")
        self.metadataURL = directory.appendingPathComponent("OfflineMinifigCatalogMetadata.json")

        if let data = try? Data(contentsOf: metadataURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.metadata = try? decoder.decode(Metadata.self, from: data)
        } else {
            self.metadata = nil
        }
    }

    @MainActor
    private func snapshotLoadTask() -> Task<[MinifigCatalogEntry], Never> {
        if let snapshotLoad { return snapshotLoad }
        let snapshotURL = self.snapshotURL
        let task = Task.detached(priority: .userInitiated) { () -> [MinifigCatalogEntry] in
            guard let data = try? Data(contentsOf: snapshotURL),
                  let entries = try? JSONDecoder().decode([MinifigCatalogEntry].self, from: data) else { return [] }
            return entries
        }
        snapshotLoad = task
        return task
    }

    /// Starts decoding the snapshot in the background if it hasn't started yet — call at app
    /// launch alongside `OfflineCatalogStore.warmUp()` so the typical first gallery open finds it
    /// already finished.
    @MainActor
    func warmUp() {
        _ = snapshotLoadTask()
    }

    @MainActor
    func allEntries() async -> [MinifigCatalogEntry] {
        await snapshotLoadTask().value
    }

    @MainActor
    func lookup(figNum: String) async -> MinifigCatalogEntry? {
        await snapshotLoadTask().value.first { $0.figNum == figNum }
    }

    var isEmpty: Bool { metadata == nil }

    /// Downloads the 4 minifig CSV dumps and joins them against `OfflineCatalogStore`'s sets
    /// snapshot (downloading that too, first, if it isn't already present — reused as-is if it
    /// is, no duplicate `sets.csv.gz` fetch in the common case).
    ///
    /// Unlike `OfflineCatalogStore.download()`, this isn't resumable byte-for-byte: the combined
    /// payload here (~750KB compressed across 4 small files) is a fraction of the ~500KB single
    /// `sets.csv.gz` that motivated that store's resumable-download machinery, so replicating that
    /// delicate, previously-buggy code three times over wasn't judged worth it — an interruption
    /// just means retrying the whole (small, fast) download. `progress` still reports `0...1`
    /// across the whole operation (coarse per-file steps, not byte-level) so Settings/the gallery
    /// CTA can show a real progress bar.
    @MainActor
    func download(progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async throws {
        guard NetworkMonitor.shared.isConnected else { throw APIError.networkUnavailable }

        if OfflineCatalogStore.shared.metadata == nil {
            // Sets snapshot 0...0.4 of the overall bar; minifig join is the remaining 0.4...1.0.
            try await OfflineCatalogStore.shared.download { value in progress(value * 0.4) }
        } else {
            progress(0.4)
        }
        let setsByNum = await OfflineCatalogStore.shared.currentSnapshot()

        let minifigsData = try await Self.fetch(Self.minifigsURL)
        progress(0.55)
        let inventoriesData = try await Self.fetch(Self.inventoriesURL)
        progress(0.7)
        let inventoryMinifigsData = try await Self.fetch(Self.inventoryMinifigsURL)
        progress(0.85)
        let inventorySetsData = try await Self.fetch(Self.inventorySetsURL)
        progress(0.9)

        let snapshotURL = self.snapshotURL
        let metadataURL = self.metadataURL
        let (entries, newMetadata) = try await Task.detached(priority: .userInitiated) {
            let entries = try Self.join(
                minifigsCSV: OfflineCatalogStore.gunzip(minifigsData),
                inventoriesCSV: OfflineCatalogStore.gunzip(inventoriesData),
                inventoryMinifigsCSV: OfflineCatalogStore.gunzip(inventoryMinifigsData),
                inventorySetsCSV: OfflineCatalogStore.gunzip(inventorySetsData),
                setsByNum: setsByNum
            )

            let snapshotData = try JSONEncoder().encode(entries)
            try snapshotData.write(to: snapshotURL, options: .atomic)

            let newMetadata = Metadata(minifigCount: entries.count, downloadedAt: Date())
            let metadataEncoder = JSONEncoder()
            metadataEncoder.dateEncodingStrategy = .iso8601
            let metadataData = try metadataEncoder.encode(newMetadata)
            try metadataData.write(to: metadataURL, options: .atomic)

            return (entries, newMetadata)
        }.value

        snapshotLoad = Task { entries }
        metadata = newMetadata
        progress(1.0)
    }

    @MainActor
    func purge() {
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: metadataURL)
        snapshotLoad = Task { [] }
        metadata = nil
    }

    private static func fetch(_ url: URL) async throws -> Data {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        } catch {
            throw APIError.networkUnavailable
        }
    }

    /// Joins the four raw (already-gunzipped) CSVs into `[MinifigCatalogEntry]`. `setsByNum` is
    /// `OfflineCatalogStore`'s snapshot — used only for `year`/`themeId` lookups by set_num.
    static func join(
        minifigsCSV: Data,
        inventoriesCSV: Data,
        inventoryMinifigsCSV: Data,
        inventorySetsCSV: Data,
        setsByNum: [String: LegoSet]
    ) throws -> [MinifigCatalogEntry] {
        // inventories.csv: id,version,set_num — id → set_num (any version; a minifig's presence
        // in a set doesn't depend on which parts-list revision is referenced).
        var setNumByInventoryId: [String: String] = [:]
        for fields in try CSV.records(in: inventoriesCSV) where fields.count >= 3 {
            setNumByInventoryId[fields[0]] = fields[2]
        }

        // inventory_sets.csv: inventory_id,set_num,quantity — a set's inventory can itself contain
        // other *sets* rather than parts/minifigs directly (issue #177): a CMF box like 71051-13
        // contains 12 sub-sets 71051-1…71051-12 (one per random bag), each of which then directly
        // contains one minifig. childSetNum → its immediate parent set_num(s) + how many copies of
        // the child one parent contains, so owning the parent can be walked down to the minifigs
        // nested arbitrarily deep inside it.
        var parentsByChildSetNum: [String: [(setNum: String, quantity: Int)]] = [:]
        for fields in try CSV.records(in: inventorySetsCSV) where fields.count >= 3 {
            guard let parentSetNum = setNumByInventoryId[fields[0]] else { continue }
            let childSetNum = fields[1]
            let quantity = Int(fields[2]) ?? 1
            parentsByChildSetNum[childSetNum, default: []].append((setNum: parentSetNum, quantity: quantity))
        }

        // All ancestors of `setNum` (parent, grandparent, …) with the multiplied quantity one
        // instance of `setNum` requires of each ancestor. Memoized since many sibling sub-sets
        // (e.g. every bag in a CMF box) share the same ancestor chain. `depth` is a cycle guard
        // only — real Rebrickable data is a strict containment DAG, never circular.
        var ancestorsCache: [String: [(setNum: String, quantity: Int)]] = [:]
        func ancestors(of setNum: String, depth: Int = 0) -> [(setNum: String, quantity: Int)] {
            if let cached = ancestorsCache[setNum] { return cached }
            guard depth < 10, let parents = parentsByChildSetNum[setNum] else { return [] }
            var result: [(setNum: String, quantity: Int)] = []
            for parent in parents {
                result.append(parent)
                for grandparent in ancestors(of: parent.setNum, depth: depth + 1) {
                    result.append((setNum: grandparent.setNum, quantity: parent.quantity * grandparent.quantity))
                }
            }
            ancestorsCache[setNum] = result
            return result
        }

        // inventory_minifigs.csv: inventory_id,fig_num,quantity — fig_num → containing sets (with
        // per-set quantity), first-occurrence order preserved (file row order: the direct set
        // first, then its ancestors), deduped by (fig_num, set_num) pair.
        var containingSetsByFigNum: [String: [ContainingSet]] = [:]
        var seenPairs = Set<String>()
        for fields in try CSV.records(in: inventoryMinifigsCSV) where fields.count >= 3 {
            guard let setNum = setNumByInventoryId[fields[0]] else { continue }
            let figNum = fields[1]
            let quantityPerSet = Int(fields[2]) ?? 1

            var candidates = [(setNum: setNum, quantity: quantityPerSet)]
            for ancestor in ancestors(of: setNum) {
                candidates.append((setNum: ancestor.setNum, quantity: quantityPerSet * ancestor.quantity))
            }

            for candidate in candidates {
                let pairKey = "\(figNum)|\(candidate.setNum)"
                guard seenPairs.insert(pairKey).inserted else { continue }
                containingSetsByFigNum[figNum, default: []].append(
                    ContainingSet(setNum: candidate.setNum, quantityPerSet: candidate.quantity)
                )
            }
        }

        // minifigs.csv: fig_num,name,num_parts,img_url
        var entries: [MinifigCatalogEntry] = []
        for fields in try CSV.records(in: minifigsCSV) where fields.count >= 4 {
            let figNum = fields[0]
            let numParts = Int(fields[2]) ?? 0
            let imgUrl = fields[3].isEmpty ? nil : fields[3]
            let containingSets = containingSetsByFigNum[figNum] ?? []
            let firstSet = containingSets.first.flatMap { setsByNum[$0.setNum] }

            entries.append(
                MinifigCatalogEntry(
                    figNum: figNum,
                    name: fields[1],
                    numParts: numParts,
                    imgUrl: imgUrl,
                    containingSets: containingSets,
                    themeId: firstSet?.themeId,
                    year: firstSet?.year
                )
            )
        }
        return entries
    }
}
