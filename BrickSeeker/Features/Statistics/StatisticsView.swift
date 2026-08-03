import SwiftUI
import SwiftData
import Charts

struct StatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: StatisticsViewModel?
    @State private var csvFile: ShareableFile?
    @State private var pdfFile: ShareableFile?
    @State private var exportErrorMessage: String?
    @State private var showSettings = false
    /// `.busy` feedback for the "Valeur estimée" reload button — inline in that card rather than
    /// an alert, since it's a "not now" state (another batch owns the queue), not a failure.
    @State private var valueRefreshMessage: String?
    let lookupViewModel: ScannerViewModel

    /// True while the initial launch sync (#148) is still unresolved and there's nothing to show
    /// yet — mirrors `CollectionView.isInitialCollectionLoad`, keyed on `setCount` since
    /// `StatisticsViewModel` has no empty-collection collection to check directly.
    private var isInitialStatsLoad: Bool {
        (viewModel?.stats.setCount ?? 0) == 0
            && (SyncStatusStore.shared.isSyncing || !SyncStatusStore.shared.didAttemptInitialSync)
    }

    var body: some View {
        ScrollView {
            if let viewModel, viewModel.stats.setCount > 0 {
                VStack(alignment: .leading, spacing: 24) {
                    totalsSection(viewModel.stats)
                    if !viewModel.stats.yearBreakdown.isEmpty {
                        yearChartSection(viewModel.stats)
                    }
                    if !viewModel.stats.themeBreakdown.isEmpty {
                        themeChartSection(viewModel.stats, viewModel)
                    }
                    valueSection(viewModel)
                    valueHistorySection(viewModel)
                    superlativesSection(viewModel.stats)
                    exportSection(viewModel)
                }
                .padding()
            } else if isInitialStatsLoad {
                ProgressView("Synchronisation…")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                ContentUnavailableView {
                    Label("Aucune statistique", systemImage: "chart.bar")
                } description: {
                    Text("Liez votre compte Rebrickable et synchronisez depuis l'accueil.")
                } actions: {
                    Button("Ouvrir les Réglages") {
                        showSettings = true
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 400)
            }
        }
        .navigationTitle("Statistiques")
        .onAppear {
            if viewModel == nil {
                viewModel = StatisticsViewModel(localRepository: LocalRepository(modelContext: modelContext))
            }
            viewModel?.load()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // `initial: true` re-checks the current state as soon as this view appears — a batch can
        // already be `isRunning` (started from Collection's bulk actions, #141) before the user
        // ever navigates here, and a plain `.onChange` only fires on future transitions, missing
        // that already-true state for the rest of the batch (#162).
        .onChange(of: CollectionPriceUpdater.shared.isRunning, initial: true) { _, isUpdating in
            UIApplication.shared.isIdleTimerDisabled = isUpdating
        }
        .onChange(of: CollectionPriceUpdater.shared.done) { _, _ in
            // Each increment means the batch just persisted one more set's price (see
            // CollectionPriceUpdater.start) — recompute so the total/coverage climb live
            // instead of staying frozen until the whole batch finishes (#48).
            if CollectionPriceUpdater.shared.isRunning {
                viewModel?.recomputeStats()
            }
        }
        // Reloads once the initial (or a pull-to-refresh) sync finishes — this view can be on
        // screen before the launch sync started/completed (#148).
        .onChange(of: SyncStatusStore.shared.isSyncing) { _, syncing in
            if !syncing { viewModel?.load() }
        }
        .sheet(item: $csvFile) { file in ShareSheet(items: [file.url]) }
        .sheet(item: $pdfFile) { file in ShareSheet(items: [file.url]) }
        .sheet(isPresented: $showSettings, onDismiss: {
            viewModel?.load()
        }) {
            SettingsView()
        }
        .alert(
            "Export impossible",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { isPresented in if !isPresented { exportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private func totalsSection(_ stats: CollectionStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Totaux").font(.headline)
            HStack(spacing: 12) {
                StatCard(title: "Sets", value: "\(stats.setCount)", icon: "shippingbox")
                StatCard(title: "Pièces", value: "\(stats.partCount)", icon: "puzzlepiece")
                StatCard(title: "Thèmes", value: "\(stats.themeCount)", icon: "tag")
            }
        }
    }

    private func yearChartSection(_ stats: CollectionStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Répartition par année").font(.headline)
            Chart(stats.yearBreakdown) { entry in
                BarMark(x: .value("Période", entry.label), y: .value("Sets", entry.setCount))
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 200)
            // Swift Charts draws no accessible content by default (#143) — a plain-text summary
            // covers the actual question a VoiceOver user has, without a full `AXChartDescriptor`.
            .accessibilityLabel("Répartition des sets par année")
            .accessibilityValue(
                stats.yearBreakdown.map { "\($0.label) : \($0.setCount)" }.joined(separator: ", ")
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func themeChartSection(_ stats: CollectionStats, _ viewModel: StatisticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Répartition par thème").font(.headline)
            Chart(stats.themeBreakdown.prefix(10)) { entry in
                BarMark(x: .value("Sets", entry.setCount), y: .value("Thème", entry.themeName))
            }
            .frame(height: CGFloat(min(stats.themeBreakdown.count, 10)) * 28 + 20)
            .accessibilityLabel("Répartition des sets par thème")
            .accessibilityValue(
                stats.themeBreakdown.prefix(10).map { "\($0.themeName) : \($0.setCount)" }.joined(separator: ", ")
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func valueSection(_ viewModel: StatisticsViewModel) -> some View {
        let updater = CollectionPriceUpdater.shared

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Valeur estimée").font(.headline)
                Spacer()
                // While a batch runs, the icon gives way to live progress rather than a dead
                // spinner — `CollectionPriceUpdater` is `@Observable @MainActor`, so reading
                // `isRunning`/`done`/`total` here is enough to track a run started from anywhere
                // (this button, the section below, or Collection's bulk actions).
                if updater.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(updater.done) / \(updater.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await refreshCollectionValue(viewModel) }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Actualiser la valeur estimée")
                }
            }

            if let valueRefreshMessage {
                DismissibleErrorLabel(message: valueRefreshMessage) {
                    self.valueRefreshMessage = nil
                }
            }

            Text(viewModel.stats.totalValueEUR.formatted(.currency(code: "EUR")))
                .font(.title2.bold())
                .contentTransition(.numericText(value: viewModel.stats.totalValueEUR))
                .animation(.default, value: viewModel.stats.totalValueEUR)
            // Both units, deliberately: the total above weights each price by `quantity`, so
            // "X / Y sets" alone described a different quantity than the number it sat under.
            Text("Basée sur \(viewModel.stats.setsWithKnownPrice) / \(viewModel.stats.setCount) sets (\(viewModel.stats.pricedUnitCount) / \(viewModel.stats.unitCount) exemplaires) dont le prix est connu")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(viewModel.stats.setsWithKnownPrice)))
                .animation(.default, value: viewModel.stats.setsWithKnownPrice)

            // The batch rows live in this card rather than a second one below it: price freshness,
            // progress, resume and "prix manquants" are all state *about the number above*, and a
            // separate "Prix de la collection" card restated the same run's title, counter and
            // refresh button. `.embedded` drops exactly the rows this card's header already shows.
            CollectionPriceUpdateSection(layout: .embedded, onCompleted: { viewModel.load() })
                .padding(.top, 4)

            // `.caption` alone was a ~16 pt tap target (#150) — `.subheadline` plus vertical
            // padding gets this closer to the 44 pt minimum.
            NavigationLink {
                ListConditionsView()
            } label: {
                HStack(spacing: 4) {
                    Text("Configurer le type (neuf/occasion) des listes")
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline)
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// Re-fetches prices for the whole owned collection straight from the value card, through the
    /// **existing** `refreshPrices(for:persist:)` entry point — it already does authorize →
    /// start → notify. `.busy` means a global run is in flight or a paused queue is waiting to be
    /// resumed; that's surfaced as a message rather than hijacking or silently resuming the other
    /// job (the reason `refreshPrices` reports it instead of just starting).
    private func refreshCollectionValue(_ viewModel: StatisticsViewModel) async {
        valueRefreshMessage = nil

        let outcome = await CollectionPriceUpdater.shared.refreshPrices(
            for: viewModel.setsForExport.map { $0.asLegoSet() },
            persist: CollectionPriceUpdater.persistClosure(modelContext: modelContext)
        )

        switch outcome {
        case .completed:
            viewModel.load()
        case .busy:
            valueRefreshMessage = String(
                localized: "Une actualisation des prix de la collection est déjà en cours ou en attente de reprise. Terminez-la avant d'en relancer une."
            )
        case .cancelled:
            break
        }
    }

    /// The monthly value series (#216) — one point per month the app took a reading, written by
    /// `StatisticsViewModel.load()` and by every completed price batch.
    ///
    /// Hidden below two points on purpose: a single dot is not an evolution, and the first month a
    /// user opens this screen would otherwise show an empty-looking chart with one mark in it.
    @ViewBuilder
    private func valueHistorySection(_ viewModel: StatisticsViewModel) -> some View {
        let points = Self.valuePoints(viewModel.valueSnapshots)
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                Text("Valeur de la collection").font(.headline)
                Chart(points) { point in
                    LineMark(
                        x: .value("Mois", point.date),
                        y: .value("Valeur", point.valueEUR)
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)

                    // Greyed rather than dropped: the reading is genuine, it's the *coverage* that
                    // was thin (prices expire after 7 days — see `recordCollectionValueSnapshot`),
                    // so the point under-states the collection and shouldn't read like the others.
                    PointMark(
                        x: .value("Mois", point.date),
                        y: .value("Valeur", point.valueEUR)
                    )
                    .foregroundStyle(point.isReliable ? Color.accentColor : Color.secondary)
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date.formatted(Self.monthAxisStyle)).font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.currency(code: "EUR").precision(.fractionLength(0))))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                // Without the padding the first and last `PointMark` sit exactly on the plot edges
                // and get drawn half-clipped — confirmed on the simulator, not assumed.
                .chartXScale(range: .plotDimension(startPadding: 8, endPadding: 8))
                .frame(height: 200)
                // Same plain-text summary approach as the other charts (#143) — Swift Charts draws
                // no accessible content of its own.
                .accessibilityLabel("Évolution de la valeur de la collection")
                .accessibilityValue(
                    points.map { point in
                        "\(point.date.formatted(Self.monthAxisStyle)) : \(point.valueEUR.formatted(.currency(code: "EUR").precision(.fractionLength(0))))"
                    }.joined(separator: ", ")
                )

                if points.contains(where: { !$0.isReliable }) {
                    Text("Les points grisés reposent sur une couverture de prix partielle : tous les sets n'avaient pas de prix connu ce mois-là.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private static let monthAxisStyle = Date.FormatStyle(locale: Locale(identifier: "fr_FR"))
        .month(.abbreviated)
        .year(.twoDigits)

    /// Chart-ready projection of the stored snapshots. A row whose `monthKey` doesn't parse is
    /// dropped rather than plotted at a made-up date — nothing this app writes can produce one, but
    /// the chart shouldn't be the thing that invents a value for it.
    private static func valuePoints(_ snapshots: [CollectionValueSnapshot]) -> [CollectionValuePoint] {
        snapshots.compactMap { snapshot in
            guard let date = snapshot.monthStart() else { return nil }
            return CollectionValuePoint(
                id: snapshot.monthKey,
                date: date,
                valueEUR: snapshot.totalValueEUR,
                isReliable: snapshot.coverage >= CollectionValueSnapshot.reliableCoverage
            )
        }
    }

    @ViewBuilder
    private func superlativesSection(_ stats: CollectionStats) -> some View {
        // The header rendered even with all three rows absent, e.g. a collection with no priced
        // set — an orphaned "Superlatifs" title over nothing (#147).
        if stats.mostExpensiveSet != nil || stats.oldestSet != nil || stats.largestSet != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Superlatifs").font(.headline)
                if let mostExpensive = stats.mostExpensiveSet, let price = stats.mostExpensiveSetPriceEUR {
                    superlativeLink(set: mostExpensive, label: "Le plus cher : \(mostExpensive.setNum) — \(mostExpensive.name) (\(price.formatted(.currency(code: "EUR"))))")
                }
                if let oldest = stats.oldestSet {
                    superlativeLink(set: oldest, label: "Le plus ancien : \(oldest.setNum) — \(oldest.name) (\(oldest.year))")
                }
                if let largest = stats.largestSet {
                    superlativeLink(set: largest, label: "Le plus de pièces : \(largest.setNum) — \(largest.name) (\(largest.numParts) pièces)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private func superlativeLink(set: CachedSet, label: String) -> some View {
        Button {
            lookupViewModel.lookupSetNumber(set.setNum, source: .listReopen)
        } label: {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func exportSection(_ viewModel: StatisticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exporter").font(.headline)
            HStack(spacing: 12) {
                Button("Exporter en CSV") {
                    // `writeCSVToTempFile` returning nil (disk write failure) used to just not
                    // open the share sheet, with no feedback at all — the button looked dead
                    // (#149).
                    guard let file = CollectionReportExporter.writeCSVToTempFile(
                        sets: viewModel.setsForExport,
                        priceEUR: viewModel.effectivePriceEUR
                    ).map(ShareableFile.init) else {
                        exportErrorMessage = String(localized: "Impossible de créer le fichier CSV. Vérifiez l'espace disponible sur l'appareil.")
                        return
                    }
                    csvFile = file
                }
                Button("Exporter en PDF") {
                    guard let file = CollectionReportExporter.writePDFToTempFile(
                        sets: viewModel.setsForExport,
                        stats: viewModel.stats,
                        priceEUR: viewModel.effectivePriceEUR,
                        lastSyncedAt: LocalRepository(modelContext: modelContext).lastFullSyncAt(),
                        lastPriceUpdateAt: CollectionPriceUpdater.shared.lastCompletedAt
                    ).map(ShareableFile.init) else {
                        exportErrorMessage = String(localized: "Impossible de créer le fichier PDF. Vérifiez l'espace disponible sur l'appareil.")
                        return
                    }
                    pdfFile = file
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

}

/// One plotted month of the collection-value chart (#216). A value type rather than the
/// `CollectionValueSnapshot` itself: `monthStart()` is optional and `coverage` is a threshold
/// question, and neither belongs inside a `Chart` content builder.
private struct CollectionValuePoint: Identifiable {
    /// The snapshot's `monthKey` — already unique per row by construction.
    let id: String
    let date: Date
    let valueEUR: Double
    let isReliable: Bool
}

/// Local `Identifiable` wrapper for `.sheet(item:)` — deliberately not a retroactive
/// `Identifiable` conformance on `URL` itself, which would collide if Apple (or another
/// module) ever declares one.
private struct ShareableFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
