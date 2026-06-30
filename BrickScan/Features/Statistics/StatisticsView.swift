import SwiftUI
import SwiftData
import Charts

private let frenchDateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "fr_FR"))

struct StatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: StatisticsViewModel?
    @State private var csvURL: URL?
    @State private var pdfURL: URL?
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
        .onChange(of: viewModel?.isUpdatingAllPrices) { _, isUpdating in
            UIApplication.shared.isIdleTimerDisabled = isUpdating ?? false
        }
        .sheet(item: $csvURL) { url in ShareSheet(items: [url]) }
        .sheet(item: $pdfURL) { url in ShareSheet(items: [url]) }
    }

    private func totalsSection(_ stats: CollectionStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Totaux").font(.headline)
            HStack(spacing: 12) {
                statCard(title: "Sets", value: "\(stats.setCount)", icon: "shippingbox")
                statCard(title: "Pièces", value: "\(stats.partCount)", icon: "puzzlepiece")
                statCard(title: "Thèmes", value: "\(stats.themeCount)", icon: "tag")
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
                BarMark(x: .value("Sets", entry.setCount), y: .value("Thème", viewModel.themeName(forThemeId: entry.themeId)))
            }
            .frame(height: CGFloat(min(stats.themeBreakdown.count, 10)) * 28 + 20)
        }
    }

    private func valueSection(_ viewModel: StatisticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Valeur estimée").font(.headline)
            Text(viewModel.stats.totalValueEUR.formatted(.currency(code: "EUR")))
                .font(.title2.bold())
            Text("Basée sur \(viewModel.stats.setsWithKnownPrice) / \(viewModel.stats.setCount) sets dont le prix est connu")
                .font(.caption)
                .foregroundStyle(.secondary)

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

            if let lastCompletedAt = viewModel.priceUpdateLastCompletedAt {
                Text("Dernière actualisation : \(lastCompletedAt.formatted(frenchDateStyle))")
                    .foregroundStyle(.secondary)
            }

            if viewModel.isUpdatingAllPrices {
                ProgressView(value: Double(viewModel.priceUpdateDone), total: Double(max(viewModel.priceUpdateTotal, 1)))
            }

            if viewModel.isUpdatingAllPrices || viewModel.hasResumablePriceUpdate {
                Text("\(viewModel.priceUpdateDone) / \(viewModel.priceUpdateTotal) sets")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = viewModel.priceUpdateErrorMessage {
                Text(errorMessage).foregroundStyle(Color.brickDanger).font(.footnote)
            }

            Button(priceUpdateButtonTitle(viewModel)) {
                Task { await viewModel.updateAllPrices(modelContext: modelContext) }
            }
            .disabled(viewModel.isUpdatingAllPrices)
        }
    }

    private func exportSection(_ viewModel: StatisticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exporter").font(.headline)
            HStack(spacing: 12) {
                Button("Exporter en CSV") {
                    csvURL = CollectionReportExporter.writeCSVToTempFile(
                        sets: viewModel.setsForExport,
                        priceEUR: viewModel.effectivePriceEUR
                    )
                }
                Button("Exporter en PDF") {
                    pdfURL = CollectionReportExporter.writePDFToTempFile(
                        sets: viewModel.setsForExport,
                        stats: viewModel.stats,
                        priceEUR: viewModel.effectivePriceEUR,
                        lastSyncedAt: LocalRepository(modelContext: modelContext).lastFullSyncAt(),
                        lastPriceUpdateAt: viewModel.priceUpdateLastCompletedAt
                    )
                }
            }
        }
    }

    private func priceUpdateButtonTitle(_ viewModel: StatisticsViewModel) -> String {
        if viewModel.isUpdatingAllPrices { return "Mise à jour en cours…" }
        if viewModel.hasResumablePriceUpdate {
            return "Reprendre (\(viewModel.priceUpdateTotal - viewModel.priceUpdateDone) restants)"
        }
        return "Actualiser les prix de la collection"
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(value).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.primary)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
