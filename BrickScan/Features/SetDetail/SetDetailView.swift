import SwiftUI
import SwiftData
import Charts
import MapKit

struct SetDetailView: View {
    @State private var viewModel: SetDetailViewModel
    @State private var showListPicker = false
    @State private var showMoveListPicker = false
    @State private var showRemoveConfirmation = false
    @State private var showSettings = false
    @State private var showScanMap = false
    @State private var priceHistory: [PriceHistoryEntry] = []
    /// Seeded once from `pendingPriceScanEvent` — see the `init` doc. `@State`'s initial value is
    /// only applied the first time this view identity is created, so later re-inits triggered by
    /// unrelated `viewModel` changes (e.g. a silent collection-status reconcile) can't retrigger
    /// the prompt.
    @State private var priceScanEventForPrompt: ScanEvent?
    @State private var hasShownPricePrompt = false
    @State private var showPricePrompt = false
    @State private var priceInputText = ""
    /// Live query (not a one-shot repository read) so a location fix that arrives while the
    /// sheet is already open — the common case, GPS + geocoding take a few seconds — updates
    /// the freshly-recorded scan row in place.
    @Query private var scanEvents: [ScanEvent]
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
        pendingPriceScanEvent: ScanEvent? = nil,
        onScanAgain: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: SetDetailViewModel(
            legoSet: legoSet,
            collectionStatus: collectionStatus,
            initialListName: initialListName,
            initialStorePrice: initialStorePrice,
            initialStorePriceFetchedAt: initialStorePriceFetchedAt
        ))
        let setNum = legoSet.setNum
        _scanEvents = Query(
            filter: #Predicate<ScanEvent> { $0.setNum == setNum },
            sort: [SortDescriptor(\.scannedAt, order: .reverse)]
        )
        _priceScanEventForPrompt = State(initialValue: pendingPriceScanEvent)
        self.reconcileOnAppear = reconcileOnAppear
        self.isOfflineResult = isOfflineResult
        self.onScanAgain = onScanAgain
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CachedRemoteImage(url: URL(string: viewModel.legoSet.setImgUrl ?? ""), refreshesLive: true) {
                        Image(systemName: "shippingbox")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                            .padding(40)
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

                    scanHistorySection

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
                        if let url = LegoStoreRepository.instructionsUrl(setNum: viewModel.legoSet.setNum) {
                            Link("Notice de montage", destination: url)
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
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showScanMap) {
                ScanMapView(setNum: viewModel.legoSet.setNum)
            }
            .sheet(isPresented: $showListPicker) {
                ListPickerView { listId, listName in
                    Task { await viewModel.addToList(listId: listId, listName: listName) }
                }
            }
            .sheet(isPresented: $showMoveListPicker) {
                ListPickerView(
                    excludeListId: {
                        if case .inCollection(let userSet) = viewModel.collectionStatus { return userSet.listId }
                        return nil
                    }()
                ) { listId, listName in
                    Task { await viewModel.moveToList(toListId: listId, toListName: listName) }
                }
            }
            .alert("Retirer de la collection ?", isPresented: $showRemoveConfirmation) {
                Button("Retirer", role: .destructive) {
                    Task { await viewModel.removeFromCollection() }
                }
                Button("Annuler", role: .cancel) {}
            }
            .alert("Quel prix as-tu vu ?", isPresented: $showPricePrompt) {
                TextField("Prix en €", text: $priceInputText)
                    .keyboardType(.decimalPad)
                Button("Enregistrer", action: savePricePrompt)
                Button("Passer", role: .cancel) {}
            } message: {
                Text("Renseigne le prix affiché en magasin pour ce scan — utile pour retrouver le meilleur prix vu ici.")
            }
            .toast($viewModel.toastMessage)
        }
        .onChange(of: viewModel.collectionStatus) { _, _ in syncCache() }
        .onChange(of: viewModel.collectionListName) { _, _ in syncCache() }
        .onChange(of: viewModel.storePriceFetchedAt) { _, _ in syncStorePriceCache() }
        .onAppear { presentPricePromptIfNeeded() }
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
            await refreshPricesIfNeeded()
        }
        .task {
            reloadPriceHistory()
        }
    }

    /// Shows the "quel prix as-tu vu ?" alert exactly once per sheet presentation, only when this
    /// SetDetail was opened from a genuine new camera scan (`priceScanEventForPrompt` — see
    /// `ScannerViewModel.pendingPriceScanEvent`). Prefills the auto-resolved price (lego.com →
    /// Amazon → BrickLink neuf) when one was already known, so the user confirms/corrects rather
    /// than typing from scratch.
    private func presentPricePromptIfNeeded() {
        guard !hasShownPricePrompt, let event = priceScanEventForPrompt else { return }
        hasShownPricePrompt = true
        if let existing = event.priceSeenEUR {
            priceInputText = String(format: "%.2f", existing).replacingOccurrences(of: ".", with: ",")
        }
        showPricePrompt = true
    }

    private func savePricePrompt() {
        guard let event = priceScanEventForPrompt else { return }
        let normalised = priceInputText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalised), value > 0 else { return }
        LocalRepository(modelContext: modelContext).updateScanEventPrice(event, priceSeenEUR: value)
    }

    private func syncStorePriceCache() {
        guard let storePrice = viewModel.storePrice, viewModel.storePriceFetchedAt != nil else { return }
        LocalRepository(modelContext: modelContext).cacheStorePrice(setNum: viewModel.legoSet.setNum, price: storePrice)
        reloadPriceHistory()
    }

    private func refreshPrices() async {
        await viewModel.loadPrices()
        LocalRepository(modelContext: modelContext).cachePrices(
            viewModel.priceQuotes, setNum: viewModel.legoSet.setNum, reconcile: true
        )
        reloadPriceHistory()
    }

    private func refreshPricesIfNeeded() async {
        let didFetch = await viewModel.loadPricesIfNeeded()
        LocalRepository(modelContext: modelContext).cachePrices(
            viewModel.priceQuotes, setNum: viewModel.legoSet.setNum, reconcile: didFetch
        )
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 12)
        }
    }

    /// How many scan rows "Tes scans" shows before collapsing into an "et N scans plus
    /// anciens" line — keeps a much-rescanned set from bloating the sheet.
    private static let maxVisibleScanRows = 6

    private var locatedScanEvents: [ScanEvent] {
        scanEvents.filter(\.hasLocation)
    }

    /// The scan where the lowest price was seen — the "meilleur prix vu ici" the localized
    /// history exists for. Nil when no scan has a recorded price. `scanEvents` is sorted
    /// newest-first and `min(by:)` keeps the first of equals, so a tie goes to the most
    /// recent scan.
    private var bestPriceScanID: PersistentIdentifier? {
        scanEvents
            .filter { $0.priceSeenEUR != nil }
            .min { ($0.priceSeenEUR ?? .infinity) < ($1.priceSeenEUR ?? .infinity) }?
            .persistentModelID
    }

    /// "Tes scans" — one row per camera scan of this set (issue #46), newest first, with the
    /// place captured at scan time when location was enabled, plus a mini-map of the located
    /// ones. Hidden entirely for a set never camera-scanned.
    @ViewBuilder
    private var scanHistorySection: some View {
        if !scanEvents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tes scans")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(scanEvents.count) scan\(scanEvents.count > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(scanEvents.prefix(Self.maxVisibleScanRows), id: \.persistentModelID) { event in
                    scanEventRow(event)
                }
                if scanEvents.count > Self.maxVisibleScanRows {
                    Text("et \(scanEvents.count - Self.maxVisibleScanRows) scans plus anciens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !locatedScanEvents.isEmpty {
                    scanMiniMap
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 12)
        }
    }

    private func scanEventRow(_ event: ScanEvent) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.scannedAt.formatted(ScanMapView.dateStyle))
                if let placeName = event.placeName {
                    Label(placeName, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let price = event.priceSeenEUR {
                    Text(Decimal(price).formatted(.currency(code: "EUR")))
                        .foregroundStyle(.primary)
                }
                if event.persistentModelID == bestPriceScanID {
                    Text(event.hasLocation ? "Meilleur prix vu ici" : "Meilleur prix")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
            }
        }
        .font(.subheadline)
    }

    /// Non-interactive preview of where this set was scanned — tapping opens the full-screen
    /// map (`ScanMapView`), where pins are selectable.
    private var scanMiniMap: some View {
        Map {
            ForEach(locatedScanEvents, id: \.persistentModelID) { event in
                if let latitude = event.latitude, let longitude = event.longitude {
                    Marker(
                        event.placeName ?? event.scannedAt.formatted(ScanMapView.dateStyle),
                        systemImage: "shippingbox.fill",
                        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    )
                    .tint(event.persistentModelID == bestPriceScanID ? .green : AppTheme.shared.accent)
                }
            }
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
        .contentShape(Rectangle())
        .onTapGesture { showScanMap = true }
        .accessibilityLabel("Carte des scans de ce set")
        .accessibilityAddTraits(.isButton)
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
                .accessibilityLabel("Actualiser les prix")
            }

            legoStoreRow

            pricePerPartRow

            ForEach([PriceSource.amazon, .bricklinkNew, .bricklinkUsed], id: \.self) { source in
                sourceRow(source)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 12)
    }

    @ViewBuilder
    private var legoStoreRow: some View {
        priceRow(label: "lego.com (officiel)") {
            if let amount = viewModel.storePrice?.amount {
                HStack(spacing: 6) {
                    availabilityBadge(viewModel.storePrice?.status ?? .unknown)
                    let code = viewModel.storePrice?.currency ?? "EUR"
                    if let url = LegoStoreRepository.storeUrl(setNum: viewModel.legoSet.setNum) {
                        Link(Decimal(amount).formatted(.currency(code: code)), destination: url)
                            .foregroundStyle(.primary)
                    } else {
                        Text(Decimal(amount).formatted(.currency(code: code)))
                    }
                }
            } else if viewModel.isLoadingStorePrice {
                ProgressView().controlSize(.small)
            } else {
                // Surfaces the specific reason (e.g. "Ce set n'est plus sur lego.com" for a 404)
                // instead of the generic "Indisponible" the other price rows fall back to —
                // a set genuinely removed from the store and one that's just slow to check
                // aren't the same thing.
                Text(viewModel.storePriceErrorMessage ?? "Indisponible")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Small coloured indicator for `StoreAvailabilityStatus`, shown next to the lego.com price —
    /// a price alone doesn't say whether the set is actively sold, temporarily out of stock, or
    /// retired with a residual price still displayed (see #64 / AGENTS.md).
    @ViewBuilder
    private func availabilityBadge(_ status: StoreAvailabilityStatus) -> some View {
        switch status {
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Disponible à l'achat")
        case .outOfStock:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Rupture de stock")
        case .retired:
            Image(systemName: "archivebox.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Retiré de la vente")
        case .unknown:
            EmptyView()
        }
    }

    /// €/pièce derived from the lego.com retail price ÷ numParts. Hidden when
    /// either value is unavailable or numParts is zero (avoids division-by-zero
    /// and meaningless "0.00 €/pièce" for sets with unknown part counts).
    /// Coloured green/red relative to the user's preferred PPP threshold.
    @ViewBuilder
    private var pricePerPartRow: some View {
        let numParts = viewModel.legoSet.numParts
        if numParts > 0, let storeAmount = viewModel.storePrice?.amount, storeAmount > 0 {
            let currency = viewModel.storePrice?.currency ?? "EUR"
            let ppp = Decimal(storeAmount) / Decimal(numParts)
            let threshold = AppTheme.shared.preferredPricePerPart
            let pppDouble = (ppp as NSDecimalNumber).doubleValue
            let pct = Int(((pppDouble - threshold) / threshold * 100).rounded())
            Button { showSettings = true } label: {
                priceRow(label: "€ / pièce") {
                    HStack(spacing: 6) {
                        if pct != 0 {
                            Text("\(pct > 0 ? "+" : "")\(pct)%")
                                .font(.caption2)
                                .foregroundStyle(pct < 0 ? .green : Color.brickDanger)
                        }
                        Text(ppp.formatted(.currency(code: currency)))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .buttonStyle(.plain)
        } else if viewModel.isLoadingStorePrice && numParts > 0 {
            priceRow(label: "€ / pièce") {
                ProgressView().controlSize(.small)
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
                        Link(quote.amount.formatted(.currency(code: quote.currency)), destination: sourceURL)
                            .foregroundStyle(.primary)
                    } else {
                        Text(quote.amount.formatted(.currency(code: quote.currency)))
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
        guard let pct = PriceComparison.percentVsStore(
            amount: amount,
            currency: currency,
            storeAmount: viewModel.storePrice?.amount,
            storeCurrency: viewModel.storePrice?.currency
        ), pct != 0 else { return nil }
        return ("\(pct > 0 ? "+" : "")\(pct)%", pct < 0 ? .green : .red)
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
            VStack(spacing: 12) {
                Button("Changer de liste") {
                    showMoveListPicker = true
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.shared.accent)

                Button("Retirer de la collection", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .font(.footnote)
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
