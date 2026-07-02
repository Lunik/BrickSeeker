import SwiftUI
import SwiftData
import Charts

struct StatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: StatisticsViewModel?
    @State private var csvFile: ShareableFile?
    @State private var pdfFile: ShareableFile?
    let lookupViewModel: ScannerViewModel

    var body: some View {
        ScrollView {
            if let viewModel {
                VStack(alignment: .leading, spacing: 24) {
                    totalsSection(viewModel.stats)
                    if !viewModel.stats.yearBreakdown.isEmpty {
                        yearChartSection(viewModel.stats)
                    }
                    if !viewModel.stats.themeBreakdown.isEmpty {
                        themeChartSection(viewModel.stats, viewModel)
                    }
                    valueSection(viewModel)
                    superlativesSection(viewModel.stats)
                    priceUpdateSection(viewModel)
                    exportSection(viewModel)
                }
                .padding()
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
        .onChange(of: CollectionPriceUpdater.shared.isRunning) { _, isUpdating in
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
        .sheet(item: $csvFile) { file in ShareSheet(items: [file.url]) }
        .sheet(item: $pdfFile) { file in ShareSheet(items: [file.url]) }
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
        }
    }

    private func themeChartSection(_ stats: CollectionStats, _ viewModel: StatisticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Répartition par thème").font(.headline)
            Chart(stats.themeBreakdown.prefix(10)) { entry in
                BarMark(x: .value("Sets", entry.setCount), y: .value("Thème", ThemeNameStore.shared.displayName(forThemeId: entry.themeId)))
            }
            .frame(height: CGFloat(min(stats.themeBreakdown.count, 10)) * 28 + 20)
        }
    }

    private func valueSection(_ viewModel: StatisticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Valeur estimée").font(.headline)
            Text(viewModel.stats.totalValueEUR.formatted(.currency(code: "EUR")))
                .font(.title2.bold())
                .contentTransition(.numericText(value: viewModel.stats.totalValueEUR))
                .animation(.default, value: viewModel.stats.totalValueEUR)
            Text("Basée sur \(viewModel.stats.setsWithKnownPrice) / \(viewModel.stats.setCount) sets dont le prix est connu")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(viewModel.stats.setsWithKnownPrice)))
                .animation(.default, value: viewModel.stats.setsWithKnownPrice)

            NavigationLink {
                ListConditionsView()
            } label: {
                HStack(spacing: 4) {
                    Text("Configurer le type (neuf/occasion) des listes")
                    Image(systemName: "chevron.right")
                }
                .font(.caption)
            }
        }
    }

    private func superlativesSection(_ stats: CollectionStats) -> some View {
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
    }

    private func superlativeLink(set: CachedSet, label: String) -> some View {
        Button {
            lookupViewModel.lookupSetNumber(set.setNum)
        } label: {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func priceUpdateSection(_ viewModel: StatisticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prix de la collection").font(.headline)
            CollectionPriceUpdateSection(onCompleted: { viewModel.load() })
        }
    }

    private func exportSection(_ viewModel: StatisticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exporter").font(.headline)
            HStack(spacing: 12) {
                Button("Exporter en CSV") {
                    csvFile = CollectionReportExporter.writeCSVToTempFile(
                        sets: viewModel.setsForExport,
                        priceEUR: viewModel.effectivePriceEUR
                    ).map(ShareableFile.init)
                }
                Button("Exporter en PDF") {
                    pdfFile = CollectionReportExporter.writePDFToTempFile(
                        sets: viewModel.setsForExport,
                        stats: viewModel.stats,
                        priceEUR: viewModel.effectivePriceEUR,
                        lastSyncedAt: LocalRepository(modelContext: modelContext).lastFullSyncAt(),
                        lastPriceUpdateAt: CollectionPriceUpdater.shared.lastCompletedAt
                    ).map(ShareableFile.init)
                }
            }
        }
    }

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
