import Foundation

actor RequestThrottler {
    static let shared = RequestThrottler()

    private let minimumInterval: TimeInterval
    private var lastRequestDate: Date?

    // Not private — each remote host (Rebrickable, Brickset, …) should own its own instance, so
    // a burst of requests to one doesn't needlessly throttle unrelated traffic to the other.
    // Customizable per-host: 0.2s is fine for Rebrickable, but Brickset returns HTTP 429 on a
    // back-to-back getSets+setCollection pair spaced only 0.2s apart (confirmed live) — see
    // `BricksetClient`.
    init(minimumInterval: TimeInterval = 0.2) {
        self.minimumInterval = minimumInterval
    }

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
