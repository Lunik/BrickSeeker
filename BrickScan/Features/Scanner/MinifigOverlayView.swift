import SwiftUI

/// Floats the minifigure's photo directly over a detected CMF box code,
/// tracking its position frame to frame. Never triggers any modal — the user
/// reviews and files results later from history.
struct MinifigOverlayView: View {
    let overlay: MinifigOverlayState

    private var cardSide: CGFloat {
        max(overlay.boundingBox.width, overlay.boundingBox.height) * 2.4
    }

    var body: some View {
        VStack(spacing: 6) {
            card
            label
        }
        .position(x: overlay.boundingBox.midX, y: overlay.boundingBox.midY)
        .animation(.easeOut(duration: 0.15), value: overlay.boundingBox.midX)
        .animation(.easeOut(duration: 0.15), value: overlay.boundingBox.midY)
    }

    @ViewBuilder
    private var card: some View {
        let side = max(cardSide, 84)
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white)
                .shadow(radius: 6)

            switch overlay.resolution {
            case .loading:
                ProgressView()
            case .resolved(_, let imgUrl):
                AsyncImage(url: URL(string: imgUrl ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(6)
                    default:
                        ProgressView()
                    }
                }
            case .unresolved:
                Image(systemName: "questionmark.diamond.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder
    private var label: some View {
        switch overlay.resolution {
        case .loading:
            EmptyView()
        case .resolved(let name, _):
            Text(name)
                .font(.footnote.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.7))
                .foregroundStyle(.white)
                .clipShape(Capsule())
        case .unresolved:
            Text("Code non reconnu")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.7))
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
    }
}
