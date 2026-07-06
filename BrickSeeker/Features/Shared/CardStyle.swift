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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(value)
                .font(.title2.bold())
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
