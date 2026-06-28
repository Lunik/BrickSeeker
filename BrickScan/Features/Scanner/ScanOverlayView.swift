import SwiftUI

struct ScanOverlayView: View {
    let state: ScannerState
    var candidateDetected: Bool = false
    var candidateThumbnail: UIImage? = nil

    private var frameColor: Color {
        switch state {
        case .processing:
            return .brickStud
        case .error:
            return .brickDanger
        case .found, .ambiguous:
            return .green
        default:
            return candidateDetected ? .green : .white
        }
    }

    private var statusText: String {
        switch state {
        case .scanning:
            return candidateDetected ? "Détecté ! Vérification..." : "Scan en cours..."
        case .processing:
            return "Recherche..."
        case .found:
            return "Set détecté !"
        case .ambiguous:
            return "Plusieurs résultats trouvés"
        case .notFound:
            return "Set non trouvé. Essayez de scanner à nouveau."
        case .error(let message):
            return message
        case .permissionDenied:
            return "Accès caméra refusé"
        }
    }

    var body: some View {
        VStack {
            Text(statusText)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 24)
                .animation(.easeInOut(duration: 0.2), value: statusText)

            Spacer()

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(frameColor, lineWidth: candidateDetected ? 5 : 3)
                .frame(width: ScannerViewModel.reticleSize.width, height: ScannerViewModel.reticleSize.height)
                .scaleEffect(candidateDetected && state == .scanning ? 1.04 : 1)
                .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: candidateDetected)
                .overlay {
                    if state == .processing {
                        ProgressView()
                            .tint(.white)
                    } else if candidateDetected, state == .scanning {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let candidateThumbnail, candidateDetected || state == .processing {
                        // .fit (not .fill) inside a bounding box, not a fixed frame, so the
                        // thumbnail keeps the actual aspect ratio of the captured text crop instead
                        // of being stretched to a fixed shape.
                        Image(uiImage: candidateThumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 110, maxHeight: 70)
                            .fixedSize()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .shadow(radius: 3)
                            .offset(x: 12, y: -12)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

            Spacer()

            Text("Pointez la caméra vers le numéro de set")
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
    }
}

extension Color {
    init(hex: String) {
        var hexValue = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexValue = hexValue.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexValue).scanHexInt64(&rgb)

        let red = Double((rgb & 0xFF0000) >> 16) / 255
        let green = Double((rgb & 0x00FF00) >> 8) / 255
        let blue = Double(rgb & 0x0000FF) / 255

        self.init(red: red, green: green, blue: blue)
    }
}
