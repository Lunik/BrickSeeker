import AudioToolbox
import UIKit

@MainActor
enum ScanFeedback {
    // "Tock" — a short, neutral system sound used elsewhere in iOS for
    // lightweight confirmation feedback (e.g. Mail's swipe action).
    private static let candidateDetectedSoundID: SystemSoundID = 1103

    static func playCandidateDetectedSound() {
        AudioServicesPlaySystemSound(candidateDetectedSoundID)
    }

    private static let minifigFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

    static func playMinifigDetectedHaptic() {
        minifigFeedbackGenerator.impactOccurred()
    }
}
