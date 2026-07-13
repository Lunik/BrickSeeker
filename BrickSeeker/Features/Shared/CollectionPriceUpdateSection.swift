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
            // Used to persist with no way to dismiss it short of starting another update (#149).
            DismissibleErrorLabel(message: errorMessage) {
                self.errorMessage = nil
            }
        }

        Button(buttonTitle) {
            Task { await updateAllPrices() }
        }
        .disabled(updater.isRunning)

        if !updater.isRunning && !updater.hasResumableUpdate && missingPriceCount > 0 {
            Button(String(localized: "Compléter les prix manquants (\(missingPriceCount))")) {
                Task { await updateMissingPrices() }
            }
        }
    }

    /// Owned sets that are both unpriced **and** still worth re-fetching — the actionable half of
    /// "missing" (issue #194). A set counts here only when:
    /// - `resolveCollectionPrice` finds no price at any source (even after the new↔used
    ///   cross-fallback) — not just `storePriceEUR == nil`, since an Amazon/BrickLink quote can
    ///   already value it with no lego.com price cached; **and**
    /// - the batch updater has never processed it (`pricesFetchedAt == nil`).
    ///
    /// A set the updater has *already* fetched from every source yet still can't price is
    /// "definitively introuvable", not "missing": re-fetching can never conjure a price that
    /// doesn't exist, so it's excluded here — otherwise "Compléter les prix manquants (N)" would
    /// keep advertising it and the user would click forever with N never reaching 0 (#194). The
    /// full "Actualiser les prix de la collection" button re-fetches *everything* regardless, so
    /// such a set can still be revisited if its price ever appears.
    private func setsMissingPrice() -> [CachedSet] {
        let repository = LocalRepository(modelContext: modelContext)
        let conditionByListId = repository.conditionByListId()
        return repository.ownedSets().filter { set in
            guard set.pricesFetchedAt == nil else { return false }
            let condition = set.currentListId.flatMap { conditionByListId[$0] }
            let quotes = repository.cachedPrices(setNum: set.setNum)
            return resolveCollectionPrice(storePriceEUR: set.storePriceEUR, condition: condition, quotes: quotes) == nil
        }
    }

    private var missingPriceCount: Int {
        setsMissingPrice().count
    }

    private var buttonTitle: String {
        let updater = CollectionPriceUpdater.shared
        if updater.isRunning {
            return String(localized: "Mise à jour en cours…")
        }
        if updater.hasResumableUpdate {
            return String(localized: "Reprendre (\(updater.total - updater.done) restants)")
        }
        return String(localized: "Actualiser les prix de la collection")
    }

    private func updateAllPrices() async {
        let sets = LocalRepository(modelContext: modelContext).ownedSets().map { $0.asLegoSet() }
        await runUpdate(sets: sets)
    }

    private func updateMissingPrices() async {
        let sets = setsMissingPrice().map { $0.asLegoSet() }
        await runUpdate(sets: sets)
    }

    private func runUpdate(sets: [LegoSet]) async {
        errorMessage = nil
        guard !sets.isEmpty else {
            errorMessage = String(localized: "Aucun set dans votre collection.")
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
