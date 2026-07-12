import SwiftUI

/// Small rounded thumbnail for a set's catalog image, used in History/Collection rows.
/// Rebrickable's set images are plain product photos on a white background (not transparent
/// cutouts) — wrapping them in a white rounded card makes that read as intentional instead of a
/// stray white square against the app's dark rows.
struct SetThumbnailView: View {
    let imageUrl: String?
    /// `@ScaledMetric` (#144), but only for the default 52 pt row usage (History/Collection/
    /// Wishlist/batch-summary/disambiguator rows) — those rows' text (date/place/price) grows a
    /// lot more than a frozen 52 pt thumbnail at accessibility Dynamic Type sizes, leaving it
    /// looking lopsided. An explicit `size` (`SetDetailView`'s horizontal minifig/related-set
    /// gallery cards, a fixed-width scroller) keeps its literal value instead — scaling those the
    /// same way would overflow the card layout at large accessibility sizes.
    @ScaledMetric private var scaledDefaultSize: CGFloat = 52
    private let explicitSize: CGFloat?

    private var size: CGFloat { explicitSize ?? scaledDefaultSize }

    init(imageUrl: String?, size: CGFloat? = nil) {
        self.imageUrl = imageUrl
        self.explicitSize = size
    }

    var body: some View {
        CachedRemoteImage(url: URL(string: imageUrl ?? ""), targetSize: size) {
            Image(systemName: "shippingbox")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(size * 0.18)
        }
        .padding(4)
        .frame(width: size, height: size)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}
