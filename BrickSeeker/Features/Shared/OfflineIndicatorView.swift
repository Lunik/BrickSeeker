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
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
