import SwiftUI

/// One gallery tile: the minifig's photo large, its own name underneath, and an owned-quantity/
/// price line at the bottom. Owned minifigs show in full colour; unowned ones are grayscaled and
/// darkened (issue #170, decision #5) so the "collection to complete" gap reads at a glance
/// without needing a caption.
struct MinifigThumbnailView: View {
    let entry: OfflineMinifigCatalogStore.MinifigCatalogEntry
    /// 0 means not owned. > 0 is shown as a muted "×N" pill next to the price (issue #170
    /// feedback #6, deliberately understated per follow-up feedback — colour alone already
    /// signals ownership, this is just the exact count).
    let ownedQuantity: Int
    /// Cache-only — never triggers a fetch (issue #170, decision #3). Nil renders nothing rather
    /// than an "unknown price" placeholder (feedback #4) — but the line's height is still
    /// reserved via invisible placeholders, so tiles with and without a resolved price/quantity
    /// stay the same size.
    let price: Double?

    private var owned: Bool { ownedQuantity > 0 }

    private var priceText: String {
        guard let price else { return "" }
        return Decimal(price).formatted(.currency(code: "EUR"))
    }

    var body: some View {
        VStack(spacing: 6) {
            CachedRemoteImage(url: URL(string: entry.imgUrl ?? "")) {
                // Custom "mystery minifig" illustration (Assets.xcassets), not an SF Symbol — a
                // minifig has a very recognisable silhouette, so a generic person icon read as a
                // broken-image placeholder rather than "no photo yet". Still picks up the same
                // grayscale/brightness treatment as a loaded photo below, so an unowned entry with
                // no image reads as unowned too, not as an error state.
                Image("MinifigPlaceholder")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            }
            .frame(height: 110)
            .grayscale(owned ? 0 : 1)
            .brightness(owned ? 0 : -0.3)

            VStack(spacing: 2) {
                Text(entry.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Quantity + price share one line now (issue #170 follow-up feedback) — the
                // quantity pill is deliberately low-contrast (secondary text on systemGray5, no
                // accent colour) so the price stays the visually dominant element. Both halves
                // reserve their space via invisible placeholders even when absent, so every tile
                // keeps the same height.
                HStack(spacing: 4) {
                    Text("×\(max(ownedQuantity, 1))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(.systemGray5), in: Capsule())
                        .opacity(owned ? 1 : 0)
                    Text(priceText.isEmpty ? " " : priceText)
                        .font(.caption.bold())
                        .opacity(priceText.isEmpty ? 0 : 1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [entry.name, owned ? "possédée, ×\(ownedQuantity)" : "non possédée"]
        if !priceText.isEmpty { parts.append(priceText) }
        return parts.joined(separator: ", ")
    }
}
