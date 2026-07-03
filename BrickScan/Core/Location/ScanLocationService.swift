import Foundation
import CoreLocation
import Observation

/// One-shot capture of the device position at the moment of a camera scan (issue #46) — never
/// continuous tracking. Strictly opt-in (`isEnabled`, off by default, toggled in Settings) on
/// top of the system When-In-Use permission, and deliberately coarse
/// (`kCLLocationAccuracyHundredMeters`): "which store am I in" needs nothing finer.
///
/// A scan never waits on this: `captureLocation()` is fired-and-forgotten by the caller and the
/// fix is attached to the already-saved `ScanEvent` when (if) it arrives — scanning works
/// identically with location disabled, denied, or unavailable.
@MainActor
@Observable
final class ScanLocationService: NSObject, CLLocationManagerDelegate {
    static let shared = ScanLocationService()

    private static let enabledKey = "scan_location_enabled"

    /// User-level opt-in, independent of the system permission — persisted so it survives
    /// relaunches. Stored (not computed from UserDefaults) so @Observable notifies SwiftUI.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private(set) var authorizationStatus: CLAuthorizationStatus

    /// True when the user opted in but iOS permission is denied/restricted — Settings uses this
    /// to point at the system settings instead of silently recording nothing.
    var isPermissionBlocked: Bool {
        isEnabled && (authorizationStatus == .denied || authorizationStatus == .restricted)
    }

    private let manager = CLLocationManager()
    /// Keyed per request so a timeout only cancels its own capture, never a later one's.
    private var pendingCaptures: [UUID: CheckedContinuation<(latitude: Double, longitude: Double)?, Never>] = [:]

    private override init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestPermissionIfNeeded() {
        guard authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// One-shot position fix, or nil when disabled, unauthorized, failed, or slower than the
    /// timeout (a scan far outlives the moment its location is relevant — better a scan without
    /// position than a position captured three aisles later).
    func captureLocation(timeout: TimeInterval = 15) async -> (latitude: Double, longitude: Double)? {
        // Read the manager's live status, not the cached `authorizationStatus` property: the
        // latter is updated asynchronously from the `nonisolated` delegate callback, so right
        // after the user grants permission it can still read `.notDetermined` and drop the very
        // first scan's location. `CLLocationManager.authorizationStatus` is synchronous and current.
        let status = manager.authorizationStatus
        guard isEnabled,
              status == .authorizedWhenInUse || status == .authorizedAlways else {
            return nil
        }
        manager.requestLocation()
        let requestId = UUID()
        return await withCheckedContinuation { continuation in
            pendingCaptures[requestId] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.pendingCaptures.removeValue(forKey: requestId)?.resume(returning: nil)
            }
        }
    }

    private func resolveAllCaptures(with fix: (latitude: Double, longitude: Double)?) {
        let continuations = pendingCaptures.values
        pendingCaptures.removeAll()
        continuations.forEach { $0.resume(returning: fix) }
    }

    /// Human-readable place name ("Carrefour, Nice") for a captured fix, or nil — the
    /// coordinates alone are still useful (map pin), so geocoding failures are non-fatal.
    nonisolated static func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        let name = placemark.name
        let locality = placemark.locality
        switch (name, locality) {
        case let (name?, locality?) where name != locality:
            return "\(name), \(locality)"
        default:
            return name ?? locality
        }
    }

    // MARK: - CLLocationManagerDelegate (nonisolated — CoreLocation owns the calling context)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let fix = (latitude: coordinate.latitude, longitude: coordinate.longitude)
        Task { @MainActor in
            self.resolveAllCaptures(with: fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.resolveAllCaptures(with: nil)
        }
    }
}
