import SwiftUI

/// Bottom-anchored transient toast. Shows while `message` is non-nil, announces it to VoiceOver,
/// and clears the binding itself after 2 s — callers just set the message.
struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = message {
                Text(toast)
                    .padding(12)
                    .background(.black.opacity(0.8))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 24)
                    .task {
                        UIAccessibility.post(notification: .announcement, argument: toast)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        message = nil
                    }
            }
        }
    }
}

extension View {
    /// Presents `message` as a transient bottom toast whenever it becomes non-nil.
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
