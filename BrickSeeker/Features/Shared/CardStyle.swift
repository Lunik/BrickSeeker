import SwiftUI

extension View {
    /// The app's standard card chrome: `padding` points of inner padding, secondary-system
    /// background, 12 pt rounded corners. Pass `padding: 0` when the caller already applied its
    /// own (e.g. axis-specific) padding.
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The icon / big value / caption tile used by the Home "Activité" cards and the Statistics
/// "Totaux" row — one implementation instead of a copy per screen.
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    /// Shows a small trailing chevron (#150) — some `StatCard`s are wrapped in a `Button` that
    /// navigates (Home's "Sets scannés"/"Sets possédés"/"Mes minifigs"/"Dans la liste cadeaux"),
    /// others are inert display-only tiles (Home's "Scans effectués", every tile in Statistics'
    /// "Totaux" row); with identical chrome otherwise, nothing on screen told them apart. Defaults
    /// to `false` so existing non-tappable call sites are unaffected.
    var isLink: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                if isLink {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            // `.lineLimit(2)` + a reserved 2-line-tall frame: a long `value` (or, on
            // `statCardLink`'s sibling `Text`, a long title) wrapping to 2 lines must not make
            // that one card taller than its neighbours in the same row — see `HomeView`'s
            // "Statistiques"/"Sets possédés"/"Mes minifigs" row.
            Text(value)
                .font(.title2.bold())
                .lineLimit(2)
                .frame(minHeight: 56, alignment: .top)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .foregroundStyle(.primary)
        // One VoiceOver phrase ("Sets scannés, 12") instead of three separate stops per card.
        .accessibilityElement(children: .combine)
    }
}
