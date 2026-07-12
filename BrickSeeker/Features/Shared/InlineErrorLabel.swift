import SwiftUI

/// Consistent inline error styling (#149) — `brickDanger` + a warning icon, so a failure never
/// reads as identical to neutral/secondary text (the review found several error strings styled
/// exactly like normal `.caption`/`.secondary` content, e.g. HomeView's sync error next to
/// "Dernière synchronisation").
struct InlineErrorLabel: View {
    let message: String
    var font: Font = .footnote

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(font)
        .foregroundStyle(Color.brickDanger)
    }
}

/// Same as `InlineErrorLabel`, plus a close button — for errors that would otherwise persist on
/// screen with no way to dismiss them (#149/#154).
struct DismissibleErrorLabel: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            InlineErrorLabel(message: message)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fermer le message d'erreur")
        }
    }
}

/// Small trailing "leaves the app" affordance (#150) — appended to any control that opens a web
/// page, so it reads as a link before it's tapped rather than an ambiguous piece of text/an
/// in-app action.
struct ExternalLinkIcon: View {
    var body: some View {
        Image(systemName: "arrow.up.right")
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
