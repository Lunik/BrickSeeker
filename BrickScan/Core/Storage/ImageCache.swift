import Foundation
import ImageIO
import UIKit

/// Two-tier cache for set catalog images, keyed by URL. Plain FileManager/URLSession — no
/// third-party image-loading dependency, consistent with the rest of the app.
///
/// - **Memory**: `NSCache` of decoded `UIImage`s (keyed by URL + decode size), so scrolling a
///   long History/Collection list doesn't re-read and re-decode from disk on every row
///   appearance. Purged automatically under memory pressure.
/// - **Disk**: stored under Application Support, not Caches: the system can purge Caches under
///   storage pressure (and does so across some app updates), which would silently drop
///   already-downloaded set images. Application Support persists until we delete it. It's
///   excluded from iCloud/iTunes backups since every image is re-downloadable from Rebrickable —
///   no point bloating backups.
actor ImageCache {
    static let shared = ImageCache()

    private let directory: URL
    /// Decoded images keyed by `memoryKey(for:maxPixelSize:)` — the same URL decoded at
    /// different sizes (52 pt row thumbnail vs SetDetail hero) is two distinct entries, so a
    /// downsampled thumbnail can never be served where the full image is expected.
    private let memory = NSCache<NSString, UIImage>()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("SetImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
    }

    /// Memory-first, then disk. `maxPixelSize` bounds the decode (see `decodeImage`); nil decodes
    /// full resolution.
    func cachedImage(for url: URL, maxPixelSize: CGFloat? = nil) -> UIImage? {
        let key = memoryKey(for: url, maxPixelSize: maxPixelSize)
        if let hit = memory.object(forKey: key) {
            return hit
        }
        guard let data = try? Data(contentsOf: fileURL(for: url)),
              let image = Self.decodeImage(data, maxPixelSize: maxPixelSize) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    /// Downloads, validates and caches an image. The HTTP status must be 2xx and the payload must
    /// actually decode as an image before anything is written — otherwise a CDN error page (HTML
    /// with status 200-or-not) would be cached to disk, fail to decode on every later read, and
    /// get re-downloaded in a loop by the `refreshesLive` path.
    func fetchAndCacheImage(_ url: URL, maxPixelSize: CGFloat? = nil) async throws -> UIImage {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.serverError(http.statusCode)
        }
        guard let image = Self.decodeImage(data, maxPixelSize: maxPixelSize) else {
            throw APIError.decodingError(CocoaError(.fileReadCorruptFile))
        }
        try? data.write(to: fileURL(for: url))
        memory.setObject(image, forKey: memoryKey(for: url, maxPixelSize: maxPixelSize))
        return image
    }

    /// Deletes every cached image (both tiers). The directory is recreated so subsequent
    /// writes still land somewhere.
    func clearAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// With `maxPixelSize`, decodes via ImageIO's thumbnail API — the image is decoded at the
    /// displayed size instead of the file's full resolution, which is what makes 52 pt list
    /// thumbnails cheap even though Rebrickable serves full product photos. Without it, a plain
    /// full-size decode.
    private static func decodeImage(_ data: Data, maxPixelSize: CGFloat?) -> UIImage? {
        guard let maxPixelSize else { return UIImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func memoryKey(for url: URL, maxPixelSize: CGFloat?) -> NSString {
        "\(url.absoluteString)#\(maxPixelSize.map { String(Int($0)) } ?? "full")" as NSString
    }

    private func fileURL(for url: URL) -> URL {
        let safeName = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        return directory.appendingPathComponent(safeName)
    }
}
