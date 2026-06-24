import Foundation

/// Disk-backed cache for set catalog images, keyed by URL. Plain FileManager/URLSession — no
/// third-party image-loading dependency, consistent with the rest of the app.
///
/// Stored under Application Support, not Caches: the system can purge Caches under storage
/// pressure (and does so across some app updates), which would silently drop already-downloaded
/// set images. Application Support persists until we delete it. It's excluded from iCloud/iTunes
/// backups since every image is re-downloadable from Rebrickable — no point bloating backups.
actor ImageCache {
    static let shared = ImageCache()

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("SetImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
    }

    func cachedImageData(for url: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: url))
    }

    func fetchAndCache(_ url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        try? data.write(to: fileURL(for: url))
        return data
    }

    private func fileURL(for url: URL) -> URL {
        let safeName = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        return directory.appendingPathComponent(safeName)
    }
}
