import Foundation

/// Disk-backed cache for set catalog images, keyed by URL. Plain FileManager/URLSession — no
/// third-party image-loading dependency, consistent with the rest of the app.
actor ImageCache {
    static let shared = ImageCache()

    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("SetImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
