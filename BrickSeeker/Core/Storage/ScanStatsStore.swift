import Foundation

final class ScanStatsStore: @unchecked Sendable {
    static let shared = ScanStatsStore()

    private let key = "total_scan_count"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var totalScans: Int {
        defaults.integer(forKey: key)
    }

    func recordScan() {
        defaults.set(totalScans + 1, forKey: key)
    }
}
