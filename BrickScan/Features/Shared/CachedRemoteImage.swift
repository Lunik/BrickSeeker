import SwiftUI

/// Cache-first image loading via `ImageCache`. Shows the cached copy instantly if present.
/// `refreshesLive: true` (used for SetDetail's hero image, matching how collection status/price
/// reconcile on open) always re-fetches afterward and swaps in the result if it changed —
/// `refreshesLive: false` (used for list-row thumbnails) only fetches when nothing is cached yet,
/// since re-fetching on every row appearance during scrolling would be wasteful.
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    var refreshesLive: Bool = false
    @ViewBuilder var placeholder: () -> Placeholder

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

    private func load() async {
        guard let url else { return }
        let hadCachedImage: Bool
        if let cachedData = await ImageCache.shared.cachedImageData(for: url), let cachedImage = UIImage(data: cachedData) {
            uiImage = cachedImage
            hadCachedImage = true
        } else {
            hadCachedImage = false
        }

        guard !hadCachedImage || refreshesLive else { return }
        guard let freshData = try? await ImageCache.shared.fetchAndCache(url), let freshImage = UIImage(data: freshData) else { return }
        uiImage = freshImage
    }
}
