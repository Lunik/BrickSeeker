import SwiftUI

/// Cache-first image loading via `ImageCache`. Shows the cached copy instantly if present.
/// `refreshesLive: true` (used for SetDetail's hero image, matching how collection status/price
/// reconcile on open) always re-fetches afterward and swaps in the result if it changed —
/// `refreshesLive: false` (used for list-row thumbnails) only fetches when nothing is cached yet,
/// since re-fetching on every row appearance during scrolling would be wasteful.
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    var refreshesLive: Bool = false
    /// Longest displayed dimension in points. When set, the image is decoded (downsampled) at
    /// that size instead of the file's full resolution — set by `SetThumbnailView` for 52 pt
    /// list rows, left nil for SetDetail's hero image.
    var targetSize: CGFloat? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private var maxPixelSize: CGFloat? {
        targetSize.map { $0 * displayScale }
    }

    private func load() async {
        guard let url else { return }
        let hadCachedImage: Bool
        if let cachedImage = await ImageCache.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            uiImage = cachedImage
            hadCachedImage = true
        } else {
            hadCachedImage = false
        }

        guard !hadCachedImage || refreshesLive else { return }
        guard let freshImage = try? await ImageCache.shared.fetchAndCacheImage(url, maxPixelSize: maxPixelSize) else { return }
        uiImage = freshImage
    }
}
