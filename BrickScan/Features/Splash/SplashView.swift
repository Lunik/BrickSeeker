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

                Text("BrickScan")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color(hex: "E3000B"))
            }
        }
    }
}
