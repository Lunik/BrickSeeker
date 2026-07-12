import SwiftUI

/// Small persistent badge shown over the rest of the UI while `NetworkMonitor.shared.isConnected`
/// is `false` — a passive "you're offline" signal, not a blocking error. Deliberately tiny and
/// non-interactive (`allowsHitTesting(false)`) so it never gets in the way of the camera/scan flow
/// it's most likely to be visible during.
struct OfflineIndicatorView: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wifi.slash")
            Text("Hors-ligne")
        }
        .font(.caption2.bold())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.75), in: Capsule())
        .foregroundStyle(.white)
        // Sat right at the safe-area edge before this, which on both Home (large title + gear
        // icon) and Scanner (toolbar + status pill) is exactly where the nav bar's own chrome
        // lives — clearing a compact nav bar's height avoids sitting behind/on top of it (#156).
        .padding(.top, 50)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        // The offline/online transition was never announced (#143) — `.onAppear` fires exactly
        // when this badge starts being shown (device just went offline); the matching "back
        // online" moment is this same view's `.onDisappear`, since the parent only mounts it
        // while `!NetworkMonitor.shared.isConnected`.
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: "Hors-ligne")
        }
        .onDisappear {
            UIAccessibility.post(notification: .announcement, argument: "Connexion rétablie")
        }
    }
}
