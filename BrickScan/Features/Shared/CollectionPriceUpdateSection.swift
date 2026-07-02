import SwiftUI
import SwiftData

/// The "Prix de la collection" batch-update rows, shared by Réglages (inside a `Form` `Section`)
/// and Statistiques (inside a titled `VStack`) — last-completed date, progress, done/total
/// counter, error, and the start/resume button. Observes `CollectionPriceUpdater.shared`
/// **directly** (it's `@Observable @MainActor`), so both screens show the same live progress
/// with no per-view-model forwarding properties; the singleton, not any view model, owns the
/// actual job, and progress stays live even if the presenting screen is dismissed and reopened
/// mid-run.
struct CollectionPriceUpdateSection: View {
    @Environment(\.modelContext) private var modelContext
    /// Called when a run finishes to completion — Statistiques reloads its stats here.
    var onCompleted: (() -> Void)? = nil

    var priceRepository: PriceRepositoryProtocol = PriceRepository()
    var legoStoreRepository: LegoStoreRepositoryProtocol = LegoStoreRepository()

    @State private var errorMessage: String?

    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "fr_FR"))

    var body: some View {
        let updater = CollectionPriceUpdater.shared

        if let lastCompletedAt = updater.lastCompletedAt {
            Text("Dernière actualisation : \(lastCompletedAt.formatted(Self.dateStyle))")
                .foregroundStyle(.secondary)
        }

        if updater.isRunning {
            ProgressView(value: Double(updater.done), total: Double(max(updater.total, 1)))
        }

        if updater.isRunning || updater.hasResumableUpdate {
            Text("\(updater.done) / \(updater.total) sets")
                .foregroundStyle(.secondary)
        }

        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(Color.brickDanger)
                .font(.footnote)
        }

        Button(buttonTitle) {
            Task { await updateAllPrices() }
        }
        .disabled(updater.isRunning)
    }

    private var buttonTitle: String {
        let updater = CollectionPriceUpdater.shared
        if updater.isRunning {
            return "Mise à jour en cours…"
        }
        if updater.hasResumableUpdate {
            return "Reprendre (\(updater.total - updater.done) restants)"
        }
        return "Actualiser les prix de la collection"
    }

    private func updateAllPrices() async {
        errorMessage = nil
        let sets = LocalRepository(modelContext: modelContext).ownedSets().map { $0.asLegoSet() }
        guard !sets.isEmpty else {
            errorMessage = "Aucun set dans votre collection."
            return
        }

        await PriceUpdateNotifier.requestAuthorizationIfNeeded()

        let result = await CollectionPriceUpdater.shared.start(
            allSets: sets,
            priceRepository: priceRepository,
            legoStoreRepository: legoStoreRepository,
            persist: CollectionPriceUpdater.persistClosure(modelContext: modelContext)
        )

        if result.completed {
            PriceUpdateNotifier.notifyCompleted(total: result.total)
            onCompleted?()
        }
    }
}
