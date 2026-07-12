import SwiftUI

/// Bottom-anchored transient toast. Shows while `message` is non-nil, announces it to VoiceOver,
/// and clears the binding itself after a few seconds — callers just set the message.
struct ToastModifier: ViewModifier {
    @Binding var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = message {
                Text(toast)
                    .padding(12)
                    .background(.black.opacity(0.8))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 24)
                    .contentShape(Rectangle())
                    .onTapGesture { message = nil }
                    .accessibilityAddTraits(.isButton)
                    // `.task(id:)`, not a bare `.task` — restarts the timer whenever `toast`
                    // itself changes (#154). A bare `.task` on this `Text` kept the *same* view
                    // identity across two back-to-back messages (same position in the tree), so a
                    // second toast arriving before the first's 2 s elapsed inherited the leftover
                    // time instead of getting its own window, and could flash off almost
                    // immediately.
                    .task(id: toast) {
                        UIAccessibility.post(notification: .announcement, argument: toast)
                        // VoiceOver users need longer than the announcement + reading time a
                        // sighted user gets from glancing at the text — give the toast more time
                        // on screen while VoiceOver is running, rather than a fixed 2 s for
                        // everyone (#143/#154).
                        let seconds: UInt64 = UIAccessibility.isVoiceOverRunning ? 5 : 2
                        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                        message = nil
                    }
            }
        }
        .animation(reduceMotion ? nil : .default, value: message)
    }
}

extension View {
    /// Presents `message` as a transient bottom toast whenever it becomes non-nil.
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
