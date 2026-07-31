import SwiftUI
import SwiftData

/// The "Surveillance des prix" rows in Réglages (#230): how many sets are under watch, when the
/// last background pass ran, and the Wi-Fi-only switch.
///
/// The last-pass date is not decoration. iOS grants `BGAppRefreshTask` wake-ups opportunistically
/// and silently, so without a visible timestamp there is no way at all to tell whether the system
/// is running the task, whether it never fires, or whether the whole feature is broken.
///
/// Its own file rather than another `@ViewBuilder` inside `SettingsView`: that `Form` has already
/// been split twice (`themeSection`, `pricePerPartSection`) because the type-checker gave up on it
/// as one expression.
struct BackgroundRefreshSection: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(BackgroundPriceRefresher.wifiOnlyKey) private var wifiOnly = false
    @State private var watchedCount = 0
    @State private var refresher = BackgroundPriceRefresher.shared

    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: "fr_FR"))

    var body: some View {
        HStack {
            Text("Sets surveillés")
            Spacer()
            Text("\(watchedCount)")
                .foregroundStyle(.secondary)
        }
        .task { watchedCount = LocalRepository(modelContext: modelContext).priceWatchTargets().count }

        if let lastRunAt = refresher.lastRunAt {
            HStack {
                Text("Dernier passage")
                Spacer()
                Text("\(lastRunAt.formatted(Self.dateStyle)) · \(refresher.lastRunProcessedCount) sets")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Aucun passage en tâche de fond pour l'instant")
                .foregroundStyle(.secondary)
        }

        Toggle("Wi-Fi uniquement", isOn: $wifiOnly)
    }
}
