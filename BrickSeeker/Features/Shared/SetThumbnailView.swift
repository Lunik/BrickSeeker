import SwiftUI

/// Small rounded thumbnail for a set's catalog image, used in History/Collection rows.
/// Rebrickable's set images are plain product photos on a white background (not transparent
/// cutouts) — wrapping them in a white rounded card makes that read as intentional instead of a
/// stray white square against the app's dark rows.
struct SetThumbnailView: View {
    let imageUrl: String?
    var size: CGFloat = 52

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
