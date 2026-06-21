import Foundation

actor RequestThrottler {
    static let shared = RequestThrottler()

    private let minimumInterval: TimeInterval = 0.2
    private var lastRequestDate: Date?

    private init() {}

    func waitIfNeeded() async {
        if let last = lastRequestDate {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minimumInterval {
                let delay = minimumInterval - elapsed
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        lastRequestDate = Date()
    }
}
