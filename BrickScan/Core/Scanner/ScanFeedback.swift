import AudioToolbox
import UIKit

/// Sound + haptic feedback for the camera scanning flow, grouped here so the two always fire
/// together and share one pair of prepared generators. In-store scanning is the design target:
/// phone on silent + ambient noise means the haptic is often the only feedback the user
/// actually perceives (#80). Every entry point is gated by the caller on
/// `ScannerViewModel.playsFeedbackSounds`, so non-camera lookups (manual entry, photo import,
/// History taps) never vibrate.
@MainActor
enum ScanFeedback {
    // "Tock" — a short, neutral system sound used elsewhere in iOS for
    // lightweight confirmation feedback (e.g. Mail's swipe action).
    private static let candidateDetectedSoundID: SystemSoundID = 1103

    private static let impactGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    /// Warms up the Taptic Engine — call when the camera starts so the first haptic isn't
    /// swallowed by engine spin-up latency.
    static func prepare() {
        impactGenerator.prepare()
        notificationGenerator.prepare()
    }

    /// Sound + light impact the moment a candidate set number is identified — fired once per
    /// candidate from `resolveSet` (the 1.5 s debounce and 30 s anti-repeat upstream guarantee
    /// the once-per-candidate cadence; see AGENTS.md "Scanning pipeline").
    static func playCandidateDetected() {
        AudioServicesPlaySystemSound(candidateDetectedSoundID)
        impactGenerator.impactOccurred()
        impactGenerator.prepare()
    }

    /// Success haptic when a scanned set resolves to a result sheet / batch entry.
    static func playResolutionSucceeded() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    /// Error haptic when a scan ends in "Set non trouvé" or an error state.
    static func playResolutionFailed() {
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }
}
