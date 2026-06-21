import AudioToolbox

enum ScanFeedback {
    // "Tock" — a short, neutral system sound used elsewhere in iOS for
    // lightweight confirmation feedback (e.g. Mail's swipe action).
    private static let setFoundSoundID: SystemSoundID = 1103

    static func playSetFoundSound() {
        AudioServicesPlaySystemSound(setFoundSoundID)
    }
}
