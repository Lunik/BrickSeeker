import SwiftUI
import SwiftData
import Charts

struct SetDetailView: View {
    @State private var viewModel: SetDetailViewModel
    @State private var showListPicker = false
    @State private var showRemoveConfirmation = false
    @State private var priceHistory: [PriceHistoryEntry] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let onScanAgain: () -> Void
    private let reconcileOnAppear: Bool
    private let isOfflineResult: Bool

    init(
        legoSet: LegoSet,
        collectionStatus: CollectionStatus,
        initialListName: String? = nil,
        initialStorePrice: StorePrice? = nil,
        initialStorePriceFetchedAt: Date? = nil,
        reconcileOnAppear: Bool = false,
        isOfflineResult: Bool = false,
        onScanAgain: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: SetDetailViewModel(
            legoSet: legoSet,
            collectionStatus: collectionStatus,
            initialListName: initialListName,
            initialStorePrice: initialStorePrice,
            initialStorePriceFetchedAt: initialStorePriceFetchedAt
        ))
        self.reconcileOnAppear = reconcileOnAppear
        self.isOfflineResult = isOfflineResult
        self.onScanAgain = onScanAgain
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CachedRemoteImage(url: URL(string: viewModel.legoSet.setImgUrl ?? ""), refreshesLive: true) {
                        AnyView(
                            Image(systemName: "shippingbox")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.secondary)
                                .padding(40)
                        )
                    }
                    .frame(height: 220)

                    VStack(spacing: 4) {
                        Text(viewModel.legoSet.setNum)
                            .font(.title2.bold())
                        Text(viewModel.legoSet.name)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                        Text("\(viewModel.legoSet.year) · \(viewModel.legoSet.numParts) pièces")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if isOfflineResult {
                        Label("Résultat hors-ligne — identification depuis le catalogue embarqué", systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    statusBadge

                    priceSection

                    priceHistoryChart

                    if viewModel.isLoading {
                        ProgressView()
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Color.brickDanger)
                            .font(.footnote)
                    }

                    actionButtons

                    HStack(spacing: 16) {
                        if let setUrl = viewModel.legoSet.setUrl, let url = URL(string: setUrl) {
                            Link("Voir sur Rebrickable", destination: url)
                                .font(.footnote)
                        }
                    }
                }
                .padding(16)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") {
                        dismiss()
                        onScanAgain()
                    }
                }
            }
            .sheet(isPresented: $showListPicker) {
                ListPickerView { listId, listName in
                    Task { await viewModel.addToList(listId: listId, listName: listName) }
                }
            }
            .alert("Retirer de la collection ?", isPresented: $showRemoveConfirmation) {
                Button("Retirer", role: .destructive) {
                    Task { await viewModel.removeFromCollection() }
                }
                Button("Annuler", role: .cancel) {}
            }
            .overlay(alignment: .bottom) {
                if let toast = viewModel.toastMessage {
                    Text(toast)
                        .padding(12)
                        .background(.black.opacity(0.8))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 24)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            viewModel.toastMessage = nil
                        }
                }
            }
        }
        .onChange(of: viewModel.collectionStatus) { _, _ in syncCache() }
        .onChange(of: viewModel.collectionListName) { _, _ in syncCache() }
        .onChange(of: viewModel.storePriceFetchedAt) { _, _ in syncStorePriceCache() }
        .task {
            if reconcileOnAppear {
                await viewModel.silentlyReconcileCollectionStatus()
            }
        }
        .task {
            await viewModel.loadStorePriceIfNeeded()
        }
        .task {
            let setNum = viewModel.legoSet.setNum
            viewModel.setCachedPrices(LocalRepository(modelContext: modelContext).cachedPrices(setNum: setNum))
            if viewModel.priceQuotes.isEmpty {
                await refreshPrices()
            }
        }
        .task {
            reloadPriceHistory()
        }
    }

    private func syncStorePriceCache() {
        guard let storePrice = viewModel.storePrice, viewModel.storePriceFetchedAt != nil else { return }
        LocalRepository(modelContext: modelContext).cacheStorePrice(setNum: viewModel.legoSet.setNum, price: storePrice)
        reloadPriceHistory()
    }

    private func refreshPrices() async {
        await viewModel.loadPrices()
        LocalRepository(modelContext: modelContext).cachePrices(viewModel.priceQuotes, setNum: viewModel.legoSet.setNum)
        reloadPriceHistory()
    }

    private func reloadPriceHistory() {
        priceHistory = LocalRepository(modelContext: modelContext).priceHistory(setNum: viewModel.legoSet.setNum)
    }

    /// Line chart of every recorded price reading (one per source), shown only once there's more
    /// than a single point to draw a trend from — see issue #5.
    @ViewBuilder
    private var priceHistoryChart: some View {
        let bySource = Dictionary(grouping: priceHistory, by: \.source)
        if priceHistory.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Évolution des prix")
                    .font(.subheadline.bold())
                Chart {
                    ForEach(bySource.keys.sorted(), id: \.self) { source in
                        ForEach(bySource[source] ?? [], id: \.persistentModelID) { entry in
                            LineMark(
                                x: .value("Date", entry.fetchedAt),
                                y: .value("Prix", (entry.amount as NSDecimalNumber).doubleValue)
                            )
                            .foregroundStyle(by: .value("Source", source.priceHistorySourceDisplayName))
                            .symbol(by: .value("Source", source.priceHistorySourceDisplayName))
                        }
                    }
                }
                .frame(height: 180)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Whether any price source is currently being (re)fetched — drives the
    /// single refresh control's spinner.
    private var pricesBusy: Bool {
        viewModel.isLoadingStorePrice || viewModel.pricesLoading
    }

    /// One card listing every price source — the official lego.com price and
    /// the scraped BrickLink/Amazon quotes — in a consistent label/value row.
    private var priceSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Prix")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    Task { await refreshAllPrices() }
                } label: {
                    if pricesBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(pricesBusy)
            }

            legoStoreRow

            ForEach([PriceSource.amazon, .bricklinkNew, .bricklinkUsed], id: \.self) { source in
                sourceRow(source)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var legoStoreRow: some View {
        priceRow(label: "lego.com (officiel)") {
            if let amount = viewModel.storePrice?.amount {
                let code = viewModel.storePrice?.currency ?? "EUR"
                if let url = LegoStoreRepository.storeUrl(setNum: viewModel.legoSet.setNum) {
                    Link(formattedAmount(Decimal(amount), currency: code), destination: url)
                } else {
                    Text(formattedAmount(Decimal(amount), currency: code))
                }
            } else {
                priceStatus(loading: viewModel.isLoadingStorePrice)
            }
        }
    }

    /// A scraped-source row. Always rendered so the price list stays the same
    /// shape across sets — shows the quote, a loading indicator, or
    /// "Indisponible", consistently with the lego.com row.
    @ViewBuilder
    private func sourceRow(_ source: PriceSource) -> some View {
        priceRow(label: source.displayName) {
            if let quote = viewModel.priceQuotes.first(where: { $0.source == source }) {
                HStack(spacing: 6) {
                    if let promo = discountVsStore(quote.amount, currency: quote.currency) {
                        Text(promo.text)
                            .font(.caption2)
                            .foregroundStyle(promo.color)
                    }
                    if let sourceURL = quote.sourceURL {
                        Link(formattedAmount(quote.amount, currency: quote.currency), destination: sourceURL)
                    } else {
                        Text(formattedAmount(quote.amount, currency: quote.currency))
                    }
                }
            } else {
                priceStatus(loading: viewModel.pricesLoading)
            }
        }
    }

    /// Shared trailing for a row with no value yet: a spinner while its source
    /// is loading, otherwise "Indisponible" — same in every row.
    @ViewBuilder
    private func priceStatus(loading: Bool) -> some View {
        if loading {
            ProgressView().controlSize(.small)
        } else {
            Text("Indisponible").foregroundStyle(.secondary)
        }
    }

    private func priceRow<Trailing: View>(
        label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .font(.subheadline)
    }

    /// Percentage difference of a source price versus the official lego.com
    /// price — a small "-5%" promo hint shown left of the price. Returns nil
    /// when there's no reference price, the currencies differ, or it rounds to
    /// 0%. Green when cheaper than retail, red when more expensive.
    private func discountVsStore(_ amount: Decimal, currency: String) -> (text: String, color: Color)? {
        guard let storeAmount = viewModel.storePrice?.amount, storeAmount > 0,
              (viewModel.storePrice?.currency ?? "EUR") == currency else { return nil }
        let source = (amount as NSDecimalNumber).doubleValue
        let pct = Int((((source - storeAmount) / storeAmount) * 100).rounded())
        guard pct != 0 else { return nil }
        return ("\(pct > 0 ? "+" : "")\(pct)%", pct < 0 ? .green : .red)
    }

    private func formattedAmount(_ amount: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount) \(currency)"
    }

    private func refreshAllPrices() async {
        // Concurrent: lego.com, BrickLink and Amazon each load on their own web
        // view, so they fetch in parallel rather than one after another.
        async let store: Void = viewModel.refreshStorePrice()
        await refreshPrices()
        await store
    }

    private func syncCache() {
        let listId: Int?
        if case .inCollection(let userSet) = viewModel.collectionStatus {
            listId = userSet.listId
        } else {
            listId = nil
        }
        LocalRepository(modelContext: modelContext).cacheSet(
            viewModel.legoSet,
            isInCollection: viewModel.isInCollection,
            listId: listId,
            listName: viewModel.collectionListName
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.collectionStatus {
        case .inCollection:
            Label(
                viewModel.collectionListName.map { "Dans votre liste « \($0) »" } ?? "Dans votre collection",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .notInCollection:
            Label("Pas dans votre collection", systemImage: "xmark.circle.fill")
                .foregroundStyle(Color.brickDanger)
        case .unknown(let message):
            VStack(spacing: 8) {
                Label("Statut inconnu : \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Réessayer") {
                    Task { await viewModel.retryCollectionStatus() }
                }
                .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if viewModel.statusIsUnknown {
            EmptyView()
        } else if viewModel.isInCollection {
            Button("Retirer de la collection", role: .destructive) {
                showRemoveConfirmation = true
            }
        } else {
            Button("Ajouter à une liste") {
                showListPicker = true
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.shared.accent)
        }
    }
}
