import Foundation
import Observation

/// App-wide signal for the initial collection sync kicked off at launch (see
/// `BrickSeekerApp`'s `.task`/`HomeViewModel.syncCollection`) — lets any screen distinguish
/// "still syncing, don't know yet" from "synced, genuinely empty" (#148). Modeled on
/// `NetworkMonitor.shared`: a singleton `@Observable @MainActor` class, not `@Published`
/// (this app uses the Observation framework, not Combine).
@Observable @MainActor
final class SyncStatusStore {
    static let shared = SyncStatusStore()
    private init() {}

    /// True only while a full network sync of the collection is actually in flight.
    var isSyncing = false
    /// True once the first sync attempt at launch has resolved — success, a handled error, or an
    /// early return because the account isn't linked / the device is offline. Screens use this
    /// (together with `isSyncing`) to tell "haven't tried yet" apart from "tried and it's empty".
    var didAttemptInitialSync = false
}
