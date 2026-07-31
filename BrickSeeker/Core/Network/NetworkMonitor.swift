import Network
import Observation

/// Tracks device-wide connectivity (Wi-Fi/cellular reachability, not "can we reach
/// rebrickable.com specifically") so the UI can show a persistent "Hors-ligne" indicator the
/// moment the device loses its network path — distinct from `APIError.networkUnavailable`, which
/// only surfaces after an actual request fails. `NWPathMonitor`'s handler fires on a background
/// queue; every update hops to the main actor before touching `isConnected` since this is an
/// `@Observable` `@MainActor` class read directly by SwiftUI.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected = true
    /// True when the current path is metered — cellular or a personal hotspot. Only read by the
    /// background price refresher's "Wi-Fi seulement" option (#230); nothing the user asked for
    /// explicitly is ever blocked on it.
    private(set) var isExpensive = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.lunik.brickseeker.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                self?.isConnected = connected
                self?.isExpensive = expensive
            }
        }
        monitor.start(queue: queue)
    }
}
