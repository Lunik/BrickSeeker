import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image("SplashIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    // Adjacent text already says "BrickSeeker" (#143) — hidden rather than
                    // doubly-announced (VoiceOver would otherwise read the image's own
                    // accessibility description, then the text, back to back).
                    .accessibilityHidden(true)

                Text("BrickSeeker")
                    .font(.largeTitle.bold())
                    // The brand accent can be yellow (F7B500) — on the light-mode system
                    // background that measured ~1.8:1 contrast, under the 3:1 AA minimum even for
                    // large text (#156). `.primary` guarantees proper contrast in both
                    // appearances regardless of which brand color is selected.
                    .foregroundStyle(.primary)
            }
        }
    }
}
