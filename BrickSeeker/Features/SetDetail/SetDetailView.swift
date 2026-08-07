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
    /// Real BrickLink sales (#214), plotted as a scatter over the history lines. Loaded from the
    /// cache alongside `priceHistory` — same inputs, same refresh points, never fetched here.
    @State private var soldListings: [SoldListingEntry] = []
    /// Current value + growth shown in the header (`valuationCard`), recomputed locally from the
    /// cached quotes/retail price/paid price — never fetched. Reloaded everywhere `priceHistory`
    /// is, since it is derived from exactly the same inputs.
    @State private var valuation: SetValuation = .empty
    @State private var paidPriceEUR: Double?
    /// The owning list's condition, needed to value the set the way Collection/Statistics do.
    @State private var listCondition: ListCondition?
    @State private var showPaidPricePrompt = false
    @State private var paidPriceInputText = ""
    /// Seeded once from `pendingPriceScanEvent` — see the `init` doc. `@State`'s initial value is
    /// only applied the first time this view identity is created, so later re-inits triggered by
    /// unrelated `viewModel` changes (e.g. a silent collection-status reconcile) don't lose track
    /// of which scan the FAB's price entry attaches to.
    @State private var priceScanEventForPrompt: ScanEvent?
    @State private var showPricePrompt = false
    @State private var priceInputText = ""
    @State private var showPriceAlertSheet = false
    /// This set's alerts (#229), re-read whenever the sheet closes — a plain `LocalRepository` read
    /// rather than a `@Query`, matching how `paidPriceEUR`/`priceHistory` are already sourced here.
    @State private var priceAlerts: [PriceAlert] = []
    @State private var scanEventPendingDeletion: ScanEvent?
    /// Sets containing this minifig (issue #178) — only ever populated for a `fig-…` item, see
    /// `setsContainingMinifigSection`.
    @State private var setsContainingMinifig: [MinifigSetEntry] = []
    @State private var setsContainingMinifigTotalCount = 0
    @State private var isLoadingSetsContainingMinifig = false
    @State private var setsContainingMinifigErrorMessage: String?
    /// Cache-only resolved "new" price per set number, computed once when the gallery loads —
    /// never a live fetch for the whole list (issue #178, mirroring `MinifigGalleryView`'s own
    /// cache-only price rule).
    @State private var priceBySetNumInMinifigGallery: [String: Double] = [:]
    /// Minifigs contained in this set (issue #184) — the exact reverse of
    /// `setsContainingMinifig`, only ever populated for a real set, see `minifigsInSetSection`.
    @State private var minifigsInSet: [SetMinifigEntry] = []
    @State private var minifigsInSetTotalCount = 0
    @State private var isLoadingMinifigsInSet = false
    @State private var minifigsInSetErrorMessage: String?
    /// Cache-only BrickLink-used price per fig number (issue #184) — the same single-number
    /// convention `MinifigGalleryView.resolvedPrice` uses for a minifig card, since lego.com/
    /// Amazon/Cdiscount never sell one individually (issue #175).
    @State private var priceByFigNumInSetGallery: [String: Double] = [:]
    /// Sets "similar" to this one (issue #188) — same theme + a comparable part count, only ever
    /// populated for a real set, see `similarSetsSection`.
    @State private var similarSets: [LegoSet] = []
    @State private var isLoadingSimilarSets = false
    @State private var similarSetsErrorMessage: String?
    /// Cache-only resolved "new" price per set number (issue #188) — same convention as
    /// `priceBySetNumInMinifigGallery`.
    @State private var priceBySetNumInSimilarSetsGallery: [String: Double] = [:]
    /// Own, independent `ScannerViewModel` (issue #178) — deliberately NOT the presenting
    /// screen's shared instance. `SetDetailView` is always presented as the leaf content of an
    /// outer `.lookupResultSheets(for:)` (see that type's doc); reusing that same view model here
    /// would set its `state` on the very instance already driving this sheet, which — for a
    /// same-identity `true`→`true` re-render — does NOT get a fresh `SetDetailView` (`@State`'s
    /// initial value is only applied the first time a view identity is created, per this file's
    /// note on `priceScanEventForPrompt`), silently leaving the old set's data on screen. A local,
    /// scoped instance sidesteps that entirely: tapping a card here always transitions its own
    /// nested sheet from not-presented to presented, which always gets a fresh identity.
    @State private var relatedSetLookupViewModel = ScannerViewModel()
    /// Live query (not a one-shot repository read) so a location fix that arrives while the
    /// sheet is already open — the common case, GPS + geocoding take a few seconds — updates
    /// the freshly-recorded scan row in place.
    @Query private var scanEvents: [ScanEvent]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let reconcileOnAppear: Bool
    private let isOfflineResult: Bool
    /// `false` only when `SetDetailPagerView` hosts this view as one page of a swipeable sequence
    /// (#239): the pager owns the `NavigationStack`, the title and the "Fermer" button, so the bar
    /// stays put while the pages slide underneath it instead of sliding along with them. Every
    /// other presenter gets the self-contained view it always had.
    private let embedsNavigationChrome: Bool
    /// `false` while the pager is holding this page ready one swipe away (#239): the view renders
    /// its complete self from the local cache — image, status, quantity, valuation, cached quotes,
    /// history chart, scans — but fires **no** network work (lego.com's WKWebView scrape above all).
    /// Flipping it to `true` when the page becomes current starts exactly those requests, without
    /// rebuilding anything: the swipe lands on a page that already looks finished, which is the
    /// whole point. Always `true` for a sheet presented on its own.
    private let loadsLiveData: Bool
    /// Only used by `setsContainingMinifigSection` (issue #178) — a plain repository call kept
    /// at the View level, same as `scanHistorySection`'s direct `LocalRepository` reads just
    /// below, rather than growing `SetDetailViewModel` for a section unrelated to its existing
    /// collection/price responsibilities.
    var rebrickableRepository: RebrickableRepositoryProtocol = RebrickableRepository()

    init(
        legoSet: LegoSet,
        collectionStatus: CollectionStatus,
        initialListName: String? = nil,
        initialStorePrice: StorePrice? = nil,
        initialStorePriceFetchedAt: Date? = nil,
        initialIsInWishlist: Bool = false,
        reconcileOnAppear: Bool = false,
        isOfflineResult: Bool = false,
        pendingPriceScanEvent: ScanEvent? = nil,
        embedsNavigationChrome: Bool = true,
        loadsLiveData: Bool = true
    ) {
        _viewModel = State(initialValue: SetDetailViewModel(
            legoSet: legoSet,
            collectionStatus: collectionStatus,
            initialListName: initialListName,
            initialStorePrice: initialStorePrice,
            initialStorePriceFetchedAt: initialStorePriceFetchedAt,
            initialIsInWishlist: initialIsInWishlist
        ))
        let setNum = legoSet.setNum
        _scanEvents = Query(
            filter: #Predicate<ScanEvent> { $0.setNum == setNum },
            sort: [SortDescriptor(\.scannedAt, order: .reverse)]
        )
        _priceScanEventForPrompt = State(initialValue: pendingPriceScanEvent)
        self.reconcileOnAppear = reconcileOnAppear
        self.isOfflineResult = isOfflineResult
        self.embedsNavigationChrome = embedsNavigationChrome
        self.loadsLiveData = loadsLiveData
    }

    private var isMinifig: Bool { viewModel.legoSet.setNum.isMinifig }

    /// Rebrickable never returns `set_url` for a minifig (no `fetchMinifig` endpoint is called
    /// today, see issue #176) — falls back to the same URL convention lego.com pages use
    /// (`LegoStoreRepository.storeUrl`/`instructionsUrl`): construct it from the `fig-…` id rather
    /// than fetch it.
    private var rebrickableURL: URL? {
        if let setUrl = viewModel.legoSet.setUrl { return URL(string: setUrl) }
        guard isMinifig else { return nil }
        return URL(string: "https://rebrickable.com/minifigs/\(viewModel.legoSet.setNum)/")
    }

    var body: some View {
        // The `NavigationStack` is conditional, not the whole view: `SetDetailPagerView` provides
        // one of its own around the whole pager (#239) so the nav bar doesn't slide with the pages.
        // Everything below — including the nested `.sheet`s and the `.toolbar` — is identical
        // either way; a `.toolbar` declared on a descendant resolves against whichever stack is
        // above it.
        Group {
            if embedsNavigationChrome {
                NavigationStack { content }
            } else {
                content
            }
        }
        .onChange(of: viewModel.collectionStatus) { _, _ in
            syncCache()
            reloadValuation()
        }
        .onChange(of: viewModel.collectionListName) { _, _ in syncCache() }
        .onChange(of: viewModel.storePriceFetchedAt) { _, _ in syncStorePriceCache() }
        .onChange(of: viewModel.isInWishlist) { _, isInWishlist in
            LocalRepository(modelContext: modelContext).setWishlistStatus(setNum: viewModel.legoSet.setNum, isInWishlist: isInWishlist)
        }
        // Every network-touching `.task` is keyed on `loadsLiveData` rather than plain `.task`, so a
        // page the pager is holding ready (#239) builds its whole cached self without firing a
        // single request, and starts them the moment it becomes the current page. Purely local
        // work below stays on an unkeyed `.task` — it's what makes a held page look finished.
        .task(id: loadsLiveData) {
            guard loadsLiveData, reconcileOnAppear else { return }
            await viewModel.silentlyReconcileCollectionStatus()
        }
        .task(id: loadsLiveData) {
            guard loadsLiveData else { return }
            await viewModel.loadStorePriceIfNeeded()
        }
        .task(id: loadsLiveData) {
            // The cache seed runs either way (and is a cheap, idempotent local read) — it has to
            // stay in the same task as the refresh below, which reads the quotes it just seeded to
            // decide whether anything is stale enough to re-fetch.
            let setNum = viewModel.legoSet.setNum
            viewModel.setCachedPrices(LocalRepository(modelContext: modelContext).cachedPrices(setNum: setNum))
            guard loadsLiveData else { return }
            await refreshPricesIfNeeded()
        }
        .task {
            reloadPriceHistory()
            reloadValuation()
            reloadPriceAlerts()
        }
        .task {
            relatedSetLookupViewModel.localRepository = LocalRepository(modelContext: modelContext)
            relatedSetLookupViewModel.playsFeedbackSounds = false
        }
        .task(id: loadsLiveData) {
            guard loadsLiveData else { return }
            await loadSetsContainingMinifigIfNeeded()
        }
        .task(id: loadsLiveData) {
            guard loadsLiveData else { return }
            await loadMinifigsInSetIfNeeded()
        }
        .task(id: loadsLiveData) {
            guard loadsLiveData else { return }
            await loadSimilarSetsIfNeeded()
        }
    }

    private var content: some View {
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
                    Text(viewModel.legoSet.setNum.baseSetNum)
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

                // Shown whatever the Réglages toggle says (#224): this sheet is only ever
                // reached by an explicit action — a scan, a manual entry, a row tap — and
                // hiding what the user just pointed the camera at would be the confusing
                // outcome. The label explains why the same item is missing from the
                // suggestion lists instead of leaving that unexplained.
                // `!isMinifig` matters: a minifig has no theme of its own, so
                // `OfflineMinifigCatalogStore` borrows one from a set it appears in — and for
                // a figure sold in a magnet set or a watch that borrowed theme lands inside
                // "Gear", which badged Chewbacca as a derived product (seen on device).
                if !isMinifig, let kind = NonSetFilter.shared.kind(themeId: viewModel.legoSet.themeId) {
                    nonSetBadge(for: kind)
                }

                statusBadge

                quantityRow

                wishlistRow

                priceAlertRow

                valuationCard

                priceSection

                priceHistoryChart

                scanHistorySection

                setsContainingMinifigSection

                minifigsInSetSection

                similarSetsSection

                if viewModel.isLoading {
                    ProgressView()
                }

                if let errorMessage = viewModel.errorMessage {
                    DismissibleErrorLabel(message: errorMessage) {
                        viewModel.errorMessage = nil
                    }
                }

                actionButtons

                // `.subheadline` + vertical padding (not the previous bare `.footnote` text,
                // a ~16 pt tap target) and a trailing "opens in browser" icon on each (#150) —
                // both leave the app, which nothing on screen used to signal before the tap.
                HStack(spacing: 24) {
                    if let url = rebrickableURL {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Text("Voir sur Rebrickable")
                                ExternalLinkIcon()
                            }
                        }
                        .font(.subheadline)
                    }
                    // lego.com has no building-instructions page for a minifig (issue #173) —
                    // only shown for a real set.
                    if !isMinifig, let url = LegoStoreRepository.instructionsUrl(setNum: viewModel.legoSet.setNum) {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Text("Notice de montage")
                                ExternalLinkIcon()
                            }
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.vertical, 6)
            }
            .padding(16)
        }
        .overlay(alignment: .bottomTrailing) {
            if !viewModel.isInCollection, priceScanEventForPrompt != nil {
                storePriceCheckFAB
            }
        }
        .toolbar {
            // Omitted when the pager owns the chrome (#239) — it declares the one "Fermer"
            // button for the whole sequence, so pages don't each contribute a duplicate.
            if embedsNavigationChrome {
                ToolbarItem(placement: .topBarTrailing) {
                    // Just closes the sheet (#153) — it used to also unconditionally call an
                    // `onScanAgain` closure that reset the presenting `ScannerViewModel` back to
                    // `.scanning`, worded and modeled as "resume the camera" even when this sheet
                    // was opened from History/Collection/Wishlist/Statistics (`.listReopen`),
                    // where there's no camera to resume. `dismiss()` alone already flips the
                    // presenter's `isPresented` binding to `false`, and `LookupResultSheetsModifier`
                    // already resets that same view model's state from its binding's `set` — the
                    // one place that actually knows what dismissal should mean for a given
                    // presenter, rather than this view guessing via a second, redundant call.
                    Button("Fermer") {
                        dismiss()
                    }
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
        .alert(
            "Supprimer ce scan ?",
            isPresented: Binding(
                get: { scanEventPendingDeletion != nil },
                set: { if !$0 { scanEventPendingDeletion = nil } }
            )
        ) {
            Button("Supprimer", role: .destructive) {
                if let event = scanEventPendingDeletion {
                    LocalRepository(modelContext: modelContext).deleteScanEvent(event)
                }
            }
            Button("Annuler", role: .cancel) {}
        }
        .sheet(isPresented: $showPricePrompt) {
            ScanPriceEntryView(
                setNum: viewModel.legoSet.setNum,
                setName: viewModel.legoSet.name,
                referencePriceEUR: viewModel.storePrice?.amount,
                referenceCurrency: viewModel.storePrice?.currency ?? "EUR",
                quotes: viewModel.priceQuotes,
                priceText: $priceInputText,
                onSave: savePricePrompt
            )
        }
        .sheet(isPresented: $showPriceAlertSheet, onDismiss: reloadPriceAlerts) {
            PriceAlertEntryView(
                setNum: viewModel.legoSet.setNum,
                setName: viewModel.legoSet.name,
                setImgUrl: viewModel.legoSet.setImgUrl,
                storePriceEUR: viewModel.storePrice?.amount,
                quotes: viewModel.priceQuotes
            )
        }
        .sheet(isPresented: $showPaidPricePrompt) {
            ScanPriceEntryView(
                setNum: viewModel.legoSet.setNum,
                setName: viewModel.legoSet.name,
                referencePriceEUR: viewModel.storePrice?.amount,
                referenceCurrency: viewModel.storePrice?.currency ?? "EUR",
                quotes: viewModel.priceQuotes,
                priceText: $paidPriceInputText,
                purpose: .paidPrice,
                onSave: savePaidPrice
            )
        }
        .toast($viewModel.toastMessage)
        // Nested, not the presenter's shared instance — see `relatedSetLookupViewModel`'s doc.
        // No navigation context is passed: a set opened from one of this sheet's own galleries
        // stacks a *second* sheet, and paging inside it was deliberately left out (#239).
        .lookupResultSheets(for: relatedSetLookupViewModel)
    }

    /// Opens the "quel prix as-tu vu ?" sheet — only ever on an explicit FAB tap, never
    /// auto-presented over the scan result (issue #94, replacing the old auto-opening prompt).
    /// Requires `priceScanEventForPrompt` (see `ScannerViewModel.pendingPriceScanEvent`), the scan
    /// this price entry attaches to. The event always starts with `priceSeenEUR == nil` (see
    /// `recordScanEventIfNeeded`) — the field only ever gets a value the user typed here — but
    /// `event.priceSeenEUR` is still read defensively in case that ever changes upstream.
    private func openPricePrompt() {
        guard let event = priceScanEventForPrompt else { return }
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
        reloadValuation()
        evaluatePriceAlerts()
    }

    private func refreshPrices() async {
        await viewModel.loadPrices()
        LocalRepository(modelContext: modelContext).cachePrices(
            viewModel.priceQuotes, setNum: viewModel.legoSet.setNum, reconcile: true
        )
        reloadPriceHistory()
        reloadValuation()
        evaluatePriceAlerts()
    }

    private func refreshPricesIfNeeded() async {
        let didFetch = await viewModel.loadPricesIfNeeded()
        LocalRepository(modelContext: modelContext).cachePrices(
            viewModel.priceQuotes, setNum: viewModel.legoSet.setNum, reconcile: didFetch
        )
        reloadPriceHistory()
        reloadValuation()
        // Only after a genuine live fetch (#229): re-evaluating a cache-only read would let opening
        // a set's sheet fire a notification about the very price already on screen.
        if didFetch { evaluatePriceAlerts() }
    }

    /// Re-checks this set's alerts against the prices just written to the cache, and refreshes the
    /// row so a threshold crossed while the sheet is open shows its new "dernier prix vu".
    private func evaluatePriceAlerts() {
        PriceAlertEvaluator.evaluate(setNum: viewModel.legoSet.setNum, in: modelContext)
        reloadPriceAlerts()
    }

    private func reloadPriceAlerts() {
        priceAlerts = LocalRepository(modelContext: modelContext).priceAlerts(setNum: viewModel.legoSet.setNum)
    }

    private func reloadPriceHistory() {
        let repository = LocalRepository(modelContext: modelContext)
        priceHistory = repository.priceHistory(setNum: viewModel.legoSet.setNum)
        soldListings = repository.soldListings(setNum: viewModel.legoSet.setNum)
    }

    /// Recomputes the header's value/growth from local data only (cached quotes, lego.com retail,
    /// the paid price and the owning list's condition). Called from the same places as
    /// `reloadPriceHistory()` — they're derived from the same inputs, so they can't be allowed to
    /// drift apart.
    private func reloadValuation() {
        let repository = LocalRepository(modelContext: modelContext)
        let setNum = viewModel.legoSet.setNum
        paidPriceEUR = repository.paidPrice(setNum: setNum)
        listCondition = collectionListId.flatMap { repository.conditionByListId()[$0] }
        valuation = SetValuationCalculator.make(
            setNum: setNum,
            storePriceEUR: viewModel.storePrice?.amount ?? repository.cachedSet(setNum: setNum)?.storePriceEUR,
            paidPriceEUR: paidPriceEUR,
            condition: listCondition,
            quotes: viewModel.priceQuotes
        )
    }

    /// The list this set currently sits in, when it's owned — the input the valuation needs to know
    /// whether to price it as new or used.
    private var collectionListId: Int? {
        guard case .inCollection(let userSet) = viewModel.collectionStatus else { return nil }
        return userSet.listId
    }

    private func openPaidPricePrompt() {
        if let paidPriceEUR {
            paidPriceInputText = String(format: "%.2f", paidPriceEUR).replacingOccurrences(of: ".", with: ",")
        } else {
            paidPriceInputText = ""
        }
        showPaidPricePrompt = true
    }

    /// An emptied field **clears** the record rather than being ignored: the paid price can be
    /// seeded automatically from a scan (`seedPaidPriceFromScanIfNeeded`), and that guess can be
    /// wrong — seen at 39,99 € in the aisle, not bought, received as a gift later — so there has to
    /// be a way back out. Only an empty field clears; an unparseable one is left alone, since
    /// destroying the number on a typo would be the worse failure.
    private func savePaidPrice() {
        let normalised = paidPriceInputText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        let repository = LocalRepository(modelContext: modelContext)
        if normalised.isEmpty {
            repository.setPaidPrice(setNum: viewModel.legoSet.setNum, paidPriceEUR: nil)
        } else {
            // `setPaidPrice` treats a non-positive amount as a clear, so "0" erases too.
            guard let value = Double(normalised), value >= 0 else { return }
            repository.setPaidPrice(setNum: viewModel.legoSet.setNum, paidPriceEUR: value)
        }
        reloadValuation()
    }

    /// "Valeur estimée / Évolution" — the local stand-in for BrickEconomy's `current_value` +
    /// `growth`, computed by `SetValuationCalculator` from data already on the device. The growth
    /// is measured against what the user paid when that's known, and against the lego.com retail
    /// price otherwise — never against a marketplace quote (#227, see `SetValuation.Basis`); the
    /// caption always says which, so the number is never ambiguous.
    ///
    /// When no source has a price yet, the card deliberately still renders (as "—") with a refresh
    /// action rather than disappearing: an absent value is itself information, and hiding the card
    /// would leave no affordance to go get one.
    ///
    /// Only the value/growth block is an `.accessibilityElement(children: .combine)`: the two
    /// buttons stay separate elements. Combining them into the card would fold their labels into
    /// `valuationAccessibilityLabel` and leave VoiceOver announcing the figures with two unnamed
    /// custom actions attached.
    @ViewBuilder
    private var valuationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        // The condition qualifies the amount (issue #157's rule, as applied to the
                        // Collection row): 3,44 € for a minifig is an *occasion* price, and showing
                        // it as a bare "valeur estimée" hides which market it came from.
                        Text(valuation.valuedCondition.map { "Valeur estimée · \($0.displayName)" } ?? "Valeur estimée")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let currentValue = valuation.currentValueEUR {
                            Text(Decimal(currentValue).formatted(.currency(code: "EUR")))
                                .font(.title2.bold())
                                .contentTransition(.numericText(value: currentValue))
                        } else {
                            Text("—")
                                .font(.title2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Évolution")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let growth = valuation.growthPercent {
                            Text(formattedGrowth(growth))
                                .font(.title2.bold())
                                .foregroundStyle(growthColor(growth))
                        } else {
                            Text("—")
                                .font(.title2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(valuationBasisCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(valuationAccessibilityLabel)

            if !valuation.hasValue {
                Button {
                    Task { await refreshAllPrices() }
                } label: {
                    if pricesBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Actualiser", systemImage: "arrow.clockwise").font(.footnote)
                    }
                }
                .disabled(pricesBusy)
                // The busy state renders a bare `ProgressView`, which carries no label of its own.
                .accessibilityLabel("Actualiser les prix")
            }

            // Owned sets only: the paid price is what makes the growth a real gain/loss rather
            // than a market delta. Deliberately not the `storePriceCheckFAB`, which means the
            // opposite thing ("is this shelf price a good deal on a set I don't own yet?").
            if viewModel.isInCollection {
                Button(action: openPaidPricePrompt) {
                    HStack {
                        Text(paidPriceEUR == nil
                             ? "Renseigner le prix payé"
                             : "Prix payé : \(Decimal(paidPriceEUR ?? 0).formatted(.currency(code: "EUR")))")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.footnote)
                    // Without this the `Spacer` isn't hit-testable, so only the text itself would
                    // respond — a full-width row with a chevron that ignores taps on three quarters
                    // of its width.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 12)
    }

    /// `+12 %` / `−8 %`, with a real minus sign (U+2212) rather than a hyphen, and no sign at all
    /// on a rounded zero — `-0,4 %` must not render as a signless "0 %" in loss red.
    private func formattedGrowth(_ growth: Double) -> String {
        let rounded = Int(growth.rounded())
        if rounded > 0 { return "+\(rounded) %" }
        if rounded < 0 { return "−\(abs(rounded)) %" }
        return "0 %"
    }

    /// Colours the *displayed* figure, not the raw one: a value that rounds to zero reads as
    /// neutral, since painting "0 %" green would suggest a gain the number doesn't claim.
    private func growthColor(_ growth: Double) -> Color {
        switch Int(growth.rounded()) {
        case let rounded where rounded > 0: return .green
        case let rounded where rounded < 0: return Color.brickDanger
        default: return .secondary
        }
    }

    /// Names the reference the growth is measured against — without it, "+12 %" is meaningless —
    /// and, when there is no growth to show, says why rather than leaving a bare "—".
    private var valuationBasisCaption: String {
        guard let basisEUR = valuation.basisEUR else {
            // A minifig has no lego.com retail price to be missing (#175) — naming one as an
            // absent input would send the user looking for something that can never exist. The
            // paid price is its only possible reference, so that's the only one worth mentioning.
            if viewModel.legoSet.setNum.isMinifig {
                return "Prix payé inconnu — évolution indisponible"
            }
            return "Prix payé et prix retail inconnus — évolution indisponible"
        }
        let formatted = Decimal(basisEUR).formatted(.currency(code: "EUR"))
        switch valuation.basis {
        case .paid: return "vs prix payé \(formatted)"
        case .retail: return "vs prix retail \(formatted)"
        case .unknown: return "Référence inconnue"
        }
    }

    private var valuationAccessibilityLabel: String {
        var parts: [String] = []
        if let currentValue = valuation.currentValueEUR {
            let amount = Decimal(currentValue).formatted(.currency(code: "EUR"))
            // Same condition qualifier as the visible caption — "3,44 €" alone doesn't say whether
            // it's a new or a used quote.
            if let condition = valuation.valuedCondition {
                parts.append("Valeur estimée \(amount) en \(condition.displayName.lowercased())")
            } else {
                parts.append("Valeur estimée \(amount)")
            }
        } else {
            parts.append("Valeur estimée inconnue")
        }
        if let growth = valuation.growthPercent {
            switch Int(growth.rounded()) {
            case let rounded where rounded > 0: parts.append("évolution plus \(rounded) pour cent")
            case let rounded where rounded < 0: parts.append("évolution moins \(abs(rounded)) pour cent")
            default: parts.append("évolution stable")
            }
        }
        parts.append(valuationBasisCaption)
        return parts.joined(separator: ", ")
    }

    /// Our own recorded price readings as one line per source (issue #5), plus a scatter of the
    /// real BrickLink sales behind them (#214) — the local answer to BrickEconomy's "Set Value"
    /// visual. The lines are deliberately kept, not replaced: without BrickEconomy's API our own
    /// history is the only source of *trend* we have, while the sales say where the market
    /// actually cleared.
    ///
    /// Shown as soon as there is anything worth drawing: two history points make a trend, but so
    /// does a scatter on its own — a set with real sales and a single history reading used to
    /// render nothing at all.
    @ViewBuilder
    private var priceHistoryChart: some View {
        let bySource = Dictionary(grouping: priceHistory, by: \.source)
        let sales = salesToPlot
        if priceHistory.count > 1 || !sales.isEmpty {
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
                    ForEach(sales, id: \.persistentModelID) { sale in
                        PointMark(
                            x: .value("Date", sale.orderedAt),
                            y: .value("Prix", (sale.unitAmount as NSDecimalNumber).doubleValue)
                        )
                        // Its own series, so the legend names it and its colour can't be confused
                        // with a history line. `.symbol(by:)` as well as `.foregroundStyle(by:)`
                        // is **required**, not decoration: the history lines register both a
                        // colour *and* a symbol scale, and a series that joins only one of the two
                        // leaves the scales with different domains — at which point Swift Charts
                        // stops merging them and draws two full, near-duplicate legends.
                        .foregroundStyle(by: .value("Source", Self.salesSeriesName(sale.source)))
                        .symbol(by: .value("Source", Self.salesSeriesName(sale.source)))
                        // Small on purpose: at the 50-row cap a heavily-traded set packs its whole
                        // window into a 180 pt-tall chart, and default-sized marks merge into one
                        // blob that hides both the spread and the history lines behind it.
                        .symbolSize(12)
                        .opacity(0.6)
                    }
                }
                .frame(height: 180)
                // Swift Charts draws no accessible content by default — VoiceOver saw nothing
                // here at all (#143). A label + a plain-text summary of the latest reading per
                // source stands in for a full `AXChartDescriptor` at a fraction of the code, and
                // covers the actual question a VoiceOver user has ("what's the current price").
                .accessibilityLabel("Évolution des prix, \(bySource.count) source\(bySource.count > 1 ? "s" : "")")
                .accessibilityValue(priceHistoryAccessibilitySummary(bySource, sales: sales))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 12)
        }
    }

    /// The sales to scatter, filtered to the condition the set is actually valued in — plotting
    /// used sales against a sealed set's new prices would put two unrelated markets on one axis.
    ///
    /// A set with no known condition (not owned, so no list to take one from) shows **both**
    /// series rather than none: they're separately named and coloured in the legend, and hiding
    /// real data because we don't know which half to prefer would be the worse answer.
    private var salesToPlot: [SoldListingEntry] {
        switch listCondition {
        case .newSet: return soldListings.filter { $0.source == PriceSource.bricklinkNew.rawValue }
        case .used: return soldListings.filter { $0.source == PriceSource.bricklinkUsed.rawValue }
        case nil: return soldListings
        }
    }

    private static func salesSeriesName(_ source: String) -> String {
        source == PriceSource.bricklinkUsed.rawValue
            ? "Ventes BrickLink (occasion)"
            : "Ventes BrickLink (neuf)"
    }

    /// One "Source : dernier prix" clause per line, newest reading first, plus a closing clause per
    /// scatter series — read out as the `Chart`'s `accessibilityValue` (#143) since Swift Charts
    /// marks itself accessibility-hidden by default. The sales clause gives the count and the range
    /// rather than 50 individual points, which is the shape of what the scatter conveys visually.
    private func priceHistoryAccessibilitySummary(_ bySource: [String: [PriceHistoryEntry]], sales: [SoldListingEntry]) -> String {
        var clauses = bySource.keys.sorted().compactMap { source -> String? in
            guard let latest = bySource[source]?.max(by: { $0.fetchedAt < $1.fetchedAt }) else { return nil }
            let amount = latest.amount.formatted(.currency(code: latest.currency))
            return "\(source.priceHistorySourceDisplayName) : \(amount)"
        }

        let salesBySeries = Dictionary(grouping: sales, by: \.source)
        for series in salesBySeries.keys.sorted() {
            guard let entries = salesBySeries[series], !entries.isEmpty,
                  let low = entries.map(\.unitAmount).min(),
                  let high = entries.map(\.unitAmount).max() else { continue }
            let currency = entries[0].currency
            let range = "\(low.formatted(.currency(code: currency))) à \(high.formatted(.currency(code: currency)))"
            clauses.append("\(Self.salesSeriesName(series)) : \(entries.count) vente\(entries.count > 1 ? "s" : ""), de \(range)")
        }
        return clauses.joined(separator: ", ")
    }

    /// How many scan rows "Tes scans" shows before collapsing into an "et N scans plus
    /// anciens" line — keeps a much-rescanned set from bloating the sheet.
    private static let maxVisibleScanRows = 6
    /// Budgeted height per row in the embedded `List` below, sized generously enough for a
    /// two-line row (date + place name) plus default List row insets at the *default* text size.
    /// `@ScaledMetric` (#144) — a plain fixed 60 pt truncated the row at large accessibility
    /// Dynamic Type sizes, where date+place+price no longer fit on two lines.
    @ScaledMetric private var scanRowHeight: CGFloat = 60

    private var locatedScanEvents: [ScanEvent] {
        scanEvents.filter(\.hasLocation)
    }

    /// The scan where the lowest price was seen — the "meilleur prix vu ici" the localized
    /// history exists for. Nil when no scan has a recorded price. `scanEvents` is sorted
    /// newest-first and `min(by:)` keeps the first of equals, so a tie goes to the most
    /// recent scan.
    private var bestPriceScanID: PersistentIdentifier? {
        scanEvents
            .compactMap { event in event.priceSeenEUR.map { (event, $0) } }
            .min { $0.1 < $1.1 }?
            .0.persistentModelID
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

                // A plain, non-scrolling List (rather than the surrounding VStack's usual ForEach)
                // solely so each row can carry `.swipeActions` — SwiftUI only supports swipe
                // actions on List rows, not on arbitrary views (issue #88).
                List {
                    ForEach(scanEvents.prefix(Self.maxVisibleScanRows), id: \.persistentModelID) { event in
                        scanEventRow(event)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    scanEventPendingDeletion = event
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(min(scanEvents.count, Self.maxVisibleScanRows)) * scanRowHeight)
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
        // A plain map with no visible chrome read as a static illustration, not something to tap
        // (#150) — this small corner badge is the same "expand" affordance a Photos/Maps
        // thumbnail uses.
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.5), in: Circle())
                .padding(6)
        }
        .contentShape(Rectangle())
        .onTapGesture { showScanMap = true }
        .accessibilityLabel("Carte des scans de ce set")
        .accessibilityAddTraits(.isButton)
    }

    /// Says what this entry is instead of a set, and whether that's currently hiding it from the
    /// suggestion lists — the whole point of showing it here is to explain an absence elsewhere.
    /// Catalog artifacts get no "si vous le souhaitez" phrasing because the toggle doesn't reach
    /// them (see `NonSetFilter.shouldHide`).
    @ViewBuilder
    private func nonSetBadge(for kind: NonSetFilter.Kind) -> some View {
        let isHidden = NonSetFilter.shared.isEnabled
        Group {
            switch kind {
            case .merchandise:
                Label(
                    isHidden
                        ? "Produit dérivé — masqué des suggestions de sets"
                        : "Produit dérivé — ce n'est pas un set de briques",
                    systemImage: "tshirt"
                )
            case .book:
                Label(
                    isHidden
                        ? "Livre ou publication — masqué des suggestions de sets"
                        : "Livre ou publication — ce n'est pas un set de briques",
                    systemImage: "book"
                )
            case .exclusive:
                Label(
                    isHidden
                        ? "Exclusivité interne LEGO — masquée des suggestions de sets"
                        : "Exclusivité interne LEGO — jamais commercialisée",
                    systemImage: "lock.circle"
                )
            case .catalogArtifact:
                Label(
                    "Entrée technique Rebrickable — ce n'est pas un produit",
                    systemImage: "wrench.and.screwdriver"
                )
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// Drops non-set entries from a "sets containing this minifig" page (#224).
    ///
    /// Runs even when the toggle is off, unlike before: "Database Sets" are Rebrickable's own
    /// bookkeeping rows, they do list minifigs, and they're hidden unconditionally. That costs the
    /// offline catalogue's decode on a screen that previously skipped it — acceptable because
    /// `BrickSeekerApp` already calls `OfflineCatalogStore.warmUp()` at launch, so by the time a
    /// minifig sheet is open the snapshot is memoized and these are dictionary hits.
    private func filteringNonSets(_ entries: [MinifigSetEntry]) async -> [MinifigSetEntry] {
        var visible: [MinifigSetEntry] = []
        for entry in entries {
            let themeId = await OfflineCatalogStore.shared.lookup(setNum: entry.setNum)?.themeId
            if let themeId, NonSetFilter.shared.shouldHide(themeId: themeId) { continue }
            visible.append(entry)
        }
        return visible
    }

    /// Loads which sets this minifig appears in (issue #178) — the one live network call this
    /// section needs, since Rebrickable has no local/offline source for it. Runs once per view
    /// identity (guarded on `setsContainingMinifig.isEmpty`); pricing for each result is then
    /// resolved from the existing price cache only, never fetched live per card.
    private func loadSetsContainingMinifigIfNeeded() async {
        guard isMinifig, setsContainingMinifig.isEmpty, !isLoadingSetsContainingMinifig else { return }
        isLoadingSetsContainingMinifig = true
        defer { isLoadingSetsContainingMinifig = false }
        do {
            let response = try await rebrickableRepository.fetchSetsContainingMinifig(
                figNum: viewModel.legoSet.setNum, pageSize: 30
            )
            // Suggestion gallery, so merchandise is dropped (#224) — a minifig also "appears" in
            // keychains, magnets and watches, which is exactly the noise this filter exists for.
            // The theme comes from `OfflineCatalogStore`, not the response: this endpoint sends no
            // `theme_id` (verified live, see `MinifigSetEntry`). That snapshot is memoized after
            // its first read, so these are dictionary hits, not one decode per card — and a set
            // it doesn't know (or the whole catalogue not being downloaded) simply stays visible,
            // the same fail-open direction as the rest of the filter.
            let results = await filteringNonSets(response.results)
            setsContainingMinifig = results
            setsContainingMinifigTotalCount = response.count
            let repository = LocalRepository(modelContext: modelContext)
            var prices: [String: Double] = [:]
            for entry in results {
                let storePriceEUR = repository.cachedSet(setNum: entry.setNum)?.storePriceEUR
                let quotes = repository.cachedPrices(setNum: entry.setNum)
                prices[entry.setNum] = resolveNewPrice(storePriceEUR: storePriceEUR, quotes: quotes)
            }
            priceBySetNumInMinifigGallery = prices
        } catch {
            setsContainingMinifigErrorMessage = UserMessage.unknownError
        }
    }

    /// "Peut être trouvé dans les sets" gallery (issue #178) — a horizontally scrolling row of
    /// the same gallery-card look as `MinifigThumbnailView` (#170), shown only for a minifig.
    /// Tapping a card opens that set's own detail sheet via `relatedSetLookupViewModel`, exactly
    /// like every other list-reopen tap in the app (`ScanMapView`'s callers, `MinifigGalleryView`,
    /// etc.).
    @ViewBuilder
    private var setsContainingMinifigSection: some View {
        if isMinifig {
            VStack(alignment: .leading, spacing: 10) {
                Text("Peut être trouvé dans les sets")
                    .font(.subheadline.bold())

                if isLoadingSetsContainingMinifig, setsContainingMinifig.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let errorMessage = setsContainingMinifigErrorMessage, setsContainingMinifig.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if setsContainingMinifig.isEmpty {
                    Text("Aucun set connu pour cette minifig")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(setsContainingMinifig) { entry in
                                Button {
                                    relatedSetLookupViewModel.lookupSetNumber(entry.setNum, source: .listReopen)
                                } label: {
                                    minifigSetCard(entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    if setsContainingMinifigTotalCount > setsContainingMinifig.count {
                        Text("et \(setsContainingMinifigTotalCount - setsContainingMinifig.count) sets supplémentaires")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 12)
        }
    }

    private static let minifigSetCardWidth: CGFloat = 110

    private func minifigSetCard(_ entry: MinifigSetEntry) -> some View {
        VStack(spacing: 6) {
            SetThumbnailView(imageUrl: entry.setImgUrl, size: Self.minifigSetCardWidth)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.setNum.baseSetNum)
                        .font(.caption.bold())
                    if let quantity = entry.quantity, quantity > 1 {
                        Text("×\(quantity)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let price = priceBySetNumInMinifigGallery[entry.setNum] {
                    Text(Decimal(price).formatted(.currency(code: "EUR")))
                        .font(.caption2.bold())
                }
            }
        }
        .frame(width: Self.minifigSetCardWidth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
    }

    /// Loads the minifigs this set contains (issue #184) — the exact reverse of
    /// `loadSetsContainingMinifigIfNeeded` (#178). Runs once per view identity (guarded on
    /// `minifigsInSet.isEmpty`); pricing for each minifig is resolved from the existing price
    /// cache only (BrickLink used — the same single-number convention `MinifigGalleryView` uses
    /// for a minifig card, since lego.com/Amazon/Cdiscount never sell one individually, #175).
    private func loadMinifigsInSetIfNeeded() async {
        guard !isMinifig, minifigsInSet.isEmpty, !isLoadingMinifigsInSet else { return }
        isLoadingMinifigsInSet = true
        defer { isLoadingMinifigsInSet = false }
        do {
            let response = try await rebrickableRepository.fetchMinifigsInSet(
                setNum: viewModel.legoSet.setNum, pageSize: 30
            )
            minifigsInSet = response.results
            minifigsInSetTotalCount = response.count
            let repository = LocalRepository(modelContext: modelContext)
            var prices: [String: Double] = [:]
            for entry in response.results {
                let quotes = repository.cachedPrices(setNum: entry.setNum)
                if let quote = quotes.first(where: { $0.source == .bricklinkUsed }) {
                    prices[entry.setNum] = (quote.amount as NSDecimalNumber).doubleValue
                }
            }
            priceByFigNumInSetGallery = prices
        } catch {
            minifigsInSetErrorMessage = UserMessage.unknownError
        }
    }

    /// "Minifigs de ce set" gallery (issue #184) — the exact symmetric of
    /// `setsContainingMinifigSection` (#178), shown only for a real set. Collapses to nothing
    /// once loaded if the set has no known minifig (the common case for most non-CMF/non-licensed
    /// sets) rather than a persistent "aucune minifig" line — unlike `setsContainingMinifigSection`,
    /// where a minifig genuinely appearing in zero sets is the rare, worth-flagging case.
    @ViewBuilder
    private var minifigsInSetSection: some View {
        if !isMinifig, isLoadingMinifigsInSet || minifigsInSetErrorMessage != nil || !minifigsInSet.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Minifigs de ce set")
                    .font(.subheadline.bold())

                if isLoadingMinifigsInSet, minifigsInSet.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let errorMessage = minifigsInSetErrorMessage, minifigsInSet.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(minifigsInSet) { entry in
                                Button {
                                    openMinifigDetail(entry)
                                } label: {
                                    minifigInSetCard(entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    if minifigsInSetTotalCount > minifigsInSet.count {
                        Text("et \(minifigsInSetTotalCount - minifigsInSet.count) minifigs supplémentaires")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 12)
        }
    }

    /// Opens the tapped minifig's own detail sheet (issue #184). A `fig-…` id 404s against
    /// Rebrickable's live `/lego/sets/…` endpoints — `ScannerViewModel.resolveSet` only succeeds
    /// for one already cached (same "cache-first scan resolution" rule as everywhere else, see
    /// AGENTS.md), exactly the problem `MinifigGalleryView.openDetail` already works around by
    /// seeding a `CachedSet` row first.
    ///
    /// Crucially, that seed must carry the *derived* ownership (issue #193): a minifig is owned
    /// when an owned set contains it, exactly as the "Mes minifigs" gallery derives it (#170/#177).
    /// Seeding a flat `isInCollection: false` here (as this did originally) made every minifig
    /// opened from a set's gallery read "non possédée" even when its host set was owned — and the
    /// live sets endpoint can't correct it afterwards (it 404s on a `fig-…`, so `resolveSet` keeps
    /// the cached status as-is), so the wrong seed stuck. `CachedSet.asCollectionStatus()` then
    /// synthesises the `UserSet` from `isInCollection` + `quantity`, the same path the gallery
    /// relies on — no minifig-specific `CollectionStatus` case needed.
    ///
    /// An already-tracked row (e.g. seeded richer by the gallery, with real theme/year) is only
    /// ever *upgraded* to owned here, never downgraded and never re-written with this gallery's
    /// thinner data: `derivedOwnedMinifigQuantity` can be scope-limited (offline catalogue absent →
    /// host set only), so a locally-derived "0" must not clobber a correct "owned via another set".
    private func openMinifigDetail(_ entry: SetMinifigEntry) {
        Task { @MainActor in
            let repository = LocalRepository(modelContext: modelContext)
            let ownedQuantity = await derivedOwnedMinifigQuantity(entry, repository: repository)
            if repository.cachedSet(setNum: entry.setNum) == nil {
                repository.cacheSet(
                    LegoSet(
                        setNum: entry.setNum,
                        name: entry.name,
                        year: 0,
                        themeId: 0,
                        numParts: 0,
                        setImgUrl: entry.setImgUrl,
                        setUrl: nil
                    ),
                    isInCollection: ownedQuantity > 0,
                    listId: nil,
                    listName: nil,
                    markAsScanned: false
                )
                if ownedQuantity > 0 {
                    repository.setQuantity(setNum: entry.setNum, quantity: ownedQuantity)
                }
            } else if ownedQuantity > 0 {
                repository.setCollectionStatus(setNum: entry.setNum, isInCollection: true, listId: nil, listName: nil)
                repository.setQuantity(setNum: entry.setNum, quantity: ownedQuantity)
            }
            relatedSetLookupViewModel.lookupSetNumber(entry.setNum, source: .listReopen)
        }
    }

    /// How many copies of the tapped minifig the user owns, derived exactly like the "Mes minifigs"
    /// gallery (#170/#177, `MinifigGalleryView.ownedQuantityByFigNum`): summed across every owned
    /// set that contains it (`quantityPerSet × ` that set's own owned quantity), 0 if none does.
    /// Reads the offline minifig catalogue for the full set↔minifig join when it's downloaded;
    /// falls back to the set currently being viewed otherwise — this gallery (#184) is a live API
    /// call and shows without the catalogue, yet we still know this minifig sits in the host set
    /// `entry.quantity` times. A 0 from the fallback only means "not owned via *this* set", which is
    /// why `openMinifigDetail` never downgrades an already-tracked row on it.
    private func derivedOwnedMinifigQuantity(_ entry: SetMinifigEntry, repository: LocalRepository) async -> Int {
        let ownedQuantityBySetNum = Dictionary(
            repository.ownedSets().map { ($0.setNum, $0.quantity) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !ownedQuantityBySetNum.isEmpty else { return 0 }
        if let catalogEntry = await OfflineMinifigCatalogStore.shared.lookup(figNum: entry.setNum) {
            return catalogEntry.containingSets.reduce(into: 0) { total, containingSet in
                guard let ownedQuantity = ownedQuantityBySetNum[containingSet.setNum] else { return }
                total += containingSet.quantityPerSet * ownedQuantity
            }
        }
        guard let hostOwnedQuantity = ownedQuantityBySetNum[viewModel.legoSet.setNum] else { return 0 }
        return (entry.quantity ?? 1) * hostOwnedQuantity
    }

    private static let minifigInSetCardWidth: CGFloat = 110

    private func minifigInSetCard(_ entry: SetMinifigEntry) -> some View {
        VStack(spacing: 6) {
            SetThumbnailView(imageUrl: entry.setImgUrl, size: Self.minifigInSetCardWidth)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.setNum.baseSetNum)
                        .font(.caption.bold())
                    if let quantity = entry.quantity, quantity > 1 {
                        Text("×\(quantity)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let price = priceByFigNumInSetGallery[entry.setNum] {
                    Text(Decimal(price).formatted(.currency(code: "EUR")))
                        .font(.caption2.bold())
                }
            }
        }
        .frame(width: Self.minifigInSetCardWidth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
    }

    /// Loads sets "similar" to this one (issue #188) — Rebrickable has no dedicated endpoint for
    /// this, so it's derived via `RebrickableRepository.fetchSimilarSets` (same theme + a parts
    /// window around this set's own `numParts`). That filter always matches the reference set
    /// itself, so it's excluded here, client-side, then the page is re-sorted by actual part-count
    /// proximity (the server has no "closest to N parts" ordering). Runs once per view identity
    /// (guarded on `similarSets.isEmpty`); pricing for each result is resolved from the existing
    /// price cache only, same "never a live per-card fetch" rule as `loadSetsContainingMinifigIfNeeded`
    /// (#178).
    private func loadSimilarSetsIfNeeded() async {
        guard !isMinifig, similarSets.isEmpty, !isLoadingSimilarSets else { return }
        isLoadingSimilarSets = true
        defer { isLoadingSimilarSets = false }
        do {
            let response = try await rebrickableRepository.fetchSimilarSets(to: viewModel.legoSet, pageSize: 20)
            let currentSetNum = viewModel.legoSet.setNum
            let currentNumParts = viewModel.legoSet.numParts
            // No merchandise filter here (#224), deliberately: `fetchSimilarSets` queries
            // `theme_id=<this set's theme>`, so every result shares the reference set's theme and
            // is therefore merchandise exactly when the set being viewed already is. Filtering
            // could only ever empty this gallery for someone who deliberately opened a derived
            // product — never remove noise from a real set's suggestions.
            let results = response.results
                .filter { $0.setNum != currentSetNum }
                .sorted { abs($0.numParts - currentNumParts) < abs($1.numParts - currentNumParts) }
            similarSets = results
            let repository = LocalRepository(modelContext: modelContext)
            var prices: [String: Double] = [:]
            for entry in results {
                let storePriceEUR = repository.cachedSet(setNum: entry.setNum)?.storePriceEUR
                let quotes = repository.cachedPrices(setNum: entry.setNum)
                prices[entry.setNum] = resolveNewPrice(storePriceEUR: storePriceEUR, quotes: quotes)
            }
            priceBySetNumInSimilarSetsGallery = prices
        } catch {
            similarSetsErrorMessage = UserMessage.unknownError
        }
    }

    /// "Sets similaires" gallery (issue #188) — same visual pattern as `setsContainingMinifigSection`
    /// (#178)/`minifigsInSetSection` (#184), shown only for a real set. Collapses to nothing once
    /// loaded if no similar set was found (same reasoning as `minifigsInSetSection`: a niche theme/
    /// size combination genuinely having none is the common case, unlike a minifig appearing in zero
    /// sets), rather than a persistent empty-state line.
    @ViewBuilder
    private var similarSetsSection: some View {
        if !isMinifig, isLoadingSimilarSets || similarSetsErrorMessage != nil || !similarSets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sets similaires")
                    .font(.subheadline.bold())

                if isLoadingSimilarSets, similarSets.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let errorMessage = similarSetsErrorMessage, similarSets.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(similarSets) { entry in
                                Button {
                                    relatedSetLookupViewModel.lookupSetNumber(entry.setNum, source: .listReopen)
                                } label: {
                                    similarSetCard(entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 12)
        }
    }

    private static let similarSetCardWidth: CGFloat = 110

    private func similarSetCard(_ entry: LegoSet) -> some View {
        VStack(spacing: 6) {
            SetThumbnailView(imageUrl: entry.setImgUrl, size: Self.similarSetCardWidth)

            VStack(spacing: 2) {
                Text(entry.setNum.baseSetNum)
                    .font(.caption.bold())
                if let price = priceBySetNumInSimilarSetsGallery[entry.setNum] {
                    Text(Decimal(price).formatted(.currency(code: "EUR")))
                        .font(.caption2.bold())
                }
            }
        }
        .frame(width: Self.similarSetCardWidth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
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

            // A minifig has no standalone retail listing — lego.com/€ per pièce/Amazon/Cdiscount
            // never sell it individually, so only BrickLink actually quotes it (issue #175).
            if !isMinifig {
                legoStoreRow

                pricePerPartRow
            }

            let sources: [PriceSource] = isMinifig
                ? [.bricklinkNew, .bricklinkUsed]
                : [.amazon, .cdiscount, .bricklinkNew, .bricklinkUsed]
            ForEach(sources, id: \.self) { source in
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
                        // Trailing external-link icon (#150) — in this same list, some prices are
                        // tappable `Link`s and some are plain `Text`, with nothing before now to
                        // tell them apart.
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Text(Decimal(amount).formatted(.currency(code: code)))
                                ExternalLinkIcon()
                            }
                        }
                        .foregroundStyle(.primary)
                    } else {
                        Text(Decimal(amount).formatted(.currency(code: code)))
                    }
                }
            } else if viewModel.isLoadingStorePrice {
                ProgressView().controlSize(.small)
            } else if let reason = viewModel.storePriceErrorMessage {
                // Surfaces the specific reason (e.g. "Ce set n'est plus sur lego.com" for a 404)
                // instead of the generic "Indisponible" the other price rows fall back to — a set
                // genuinely removed from the store and one that's just slow to check aren't the
                // same thing, so this gets error styling (#149) while plain "Indisponible" below
                // stays neutral/secondary.
                InlineErrorLabel(message: reason, font: .subheadline)
            } else {
                Text("Indisponible")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Small coloured indicator for `StoreAvailabilityStatus`, shown next to the lego.com price —
    /// a price alone doesn't say whether the set is actively sold, temporarily out of stock, or
    /// retired with a residual price still displayed (see #64 / AGENTS.md). Icons/colours/wording
    /// come from `StoreAvailabilityStatus`'s display extension so this badge and the
    /// "Disponibilité" filter picker (#226) can't drift apart; `.unknown` still renders nothing
    /// here (`systemImage == nil`) — an empty state next to a price is noise, not information.
    @ViewBuilder
    private func availabilityBadge(_ status: StoreAvailabilityStatus) -> some View {
        if let symbol = status.systemImage {
            Image(systemName: symbol)
                .foregroundStyle(status.tint)
                .accessibilityLabel(status.label)
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
                        // This row opens Settings (to adjust the €/pièce threshold), unlike every
                        // other row in this list which is either static text or a `Link` out to
                        // the web — nothing distinguished it from a plain price (#150).
                        Image(systemName: "gearshape")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
    ///
    /// A BrickLink quote also carries the low/high of the sales its average was computed over
    /// (#213); that goes on a secondary caption line under the price, never in place of it.
    @ViewBuilder
    private func sourceRow(_ source: PriceSource) -> some View {
        let quote = viewModel.priceQuotes.first(where: { $0.source == source })
        VStack(alignment: .trailing, spacing: 2) {
            priceRow(label: source.displayName) {
                if let quote {
                    HStack(spacing: 6) {
                        if let promo = discountVsStore(quote.amount, currency: quote.currency) {
                            Text(promo.text)
                                .font(.caption2)
                                .foregroundStyle(promo.color)
                        }
                        if let sourceURL = quote.sourceURL {
                            Link(destination: sourceURL) {
                                HStack(spacing: 4) {
                                    Text(quote.amount.formatted(.currency(code: quote.currency)))
                                    ExternalLinkIcon()
                                }
                            }
                            .foregroundStyle(.primary)
                        } else {
                            Text(quote.amount.formatted(.currency(code: quote.currency)))
                        }
                    }
                } else {
                    priceStatus(loading: viewModel.pricesLoading)
                }
            }

            if let quote, let range = priceRange(quote) {
                // Orange on a thin sample (#240) so "sur 1 vente" reads as the caveat it is rather
                // than as one more grey decoration — same signal as the unknown-status warning.
                Text(range.text)
                    .font(.caption2)
                    .foregroundStyle(quote.isThinSample ? .orange : .secondary)
                    .accessibilityLabel(range.accessibilityLabel)
            }
        }
    }

    /// "12,00 € – 30,00 € (7 ventes)", or just "sur 1 vente" when there is no spread to show.
    ///
    /// The spread and the sample size are two independent facts, and the previous single guard tied
    /// them together: it bailed out entirely when `minAmount == maxAmount`, which is *exactly* the
    /// one-sale case (#240). A quote drawn from a single transaction therefore rendered as a bare
    /// number — cleaner, and so more credible, than the nine-sale quote right above it. That was
    /// backwards: the thinnest sample is the one that most needs qualifying.
    ///
    /// A missing bound still yields no range — a lone bound would imply a spread we don't have —
    /// but it no longer suppresses the lot count.
    private func priceRange(_ quote: PriceQuote) -> (text: String, accessibilityLabel: String)? {
        let spread: (low: String, high: String)? = {
            guard let minAmount = quote.minAmount, let maxAmount = quote.maxAmount, minAmount < maxAmount else {
                return nil
            }
            return (minAmount.formatted(.currency(code: quote.currency)),
                    maxAmount.formatted(.currency(code: quote.currency)))
        }()
        // `unit_quantity` counts distinct sales on the `sold` guide the app reads — "lots" was the
        // `stock` guide's word for the same field, and read as inventory rather than sample size.
        guard let lots = quote.lotCount, lots > 0 else {
            guard let spread else { return nil }
            return ("\(spread.low) – \(spread.high)", "Fourchette de \(spread.low) à \(spread.high)")
        }
        let sample = lots == 1 ? "1 vente" : "\(lots) ventes"
        guard let spread else {
            return ("sur \(sample)", "Cote établie sur \(sample)")
        }
        return ("\(spread.low) – \(spread.high) (\(sample))",
                "Fourchette de \(spread.low) à \(spread.high), sur \(sample)")
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
        let quantity: Int?
        if case .inCollection(let userSet) = viewModel.collectionStatus {
            listId = userSet.listId
            quantity = userSet.quantity
        } else {
            listId = nil
            quantity = nil
        }
        let repository = LocalRepository(modelContext: modelContext)
        // Reconciling collection status/name here must not mark the set "scanned" — this runs
        // every time the detail view's collection status resolves, including reopens from
        // History/Collection/Wishlist/Statistics, not just fresh scans. `cacheFoundState` (called
        // once, right when the resolve flow itself completes) already owns that decision — see
        // its doc and issue #133.
        repository.cacheSet(
            viewModel.legoSet,
            isInCollection: viewModel.isInCollection,
            listId: listId,
            listName: viewModel.collectionListName,
            markAsScanned: false
        )
        // `cacheSet` never touches `quantity` (see its doc) — propagated separately here so a
        // quantity edit (or a fresh `fetchUserSet` after one) reaches the SwiftData cache that
        // Statistics/export read from.
        if let quantity {
            repository.setQuantity(setNum: viewModel.legoSet.setNum, quantity: quantity)
        }
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
                // The only way out of this state (#149) — a plain footnote link read as
                // low-priority/optional text, not the actionable recovery it actually is.
                Button("Réessayer", systemImage: "arrow.clockwise") {
                    Task { await viewModel.retryCollectionStatus() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brickDanger)
                .controlSize(.small)
            }
        }
    }

    /// Number of copies owned (issue #115) — hidden entirely outside the collection, since a
    /// quantity only means something for a set actually owned. Bound to `collectionStatus`'s
    /// `UserSet.quantity` rather than a separate `@State`, so it always reflects the last
    /// server-confirmed value (`updateQuantity` refetches after its PUT).
    @ViewBuilder
    private var quantityRow: some View {
        if case .inCollection(let userSet) = viewModel.collectionStatus {
            Stepper(value: quantityBinding(current: userSet.quantity), in: 1...99) {
                Text("Quantité : ×\(userSet.quantity)")
            }
            .disabled(viewModel.isLoading)
        }
    }

    private func quantityBinding(current: Int) -> Binding<Int> {
        Binding(
            get: { current },
            set: { newValue in Task { await viewModel.updateQuantity(to: newValue) } }
        )
    }

    /// Toggles this set's Brickset wishlist status — independent of collection membership (a set
    /// can be owned, wishlisted, both, or neither), so shown regardless of `isInCollection`/
    /// `statusIsUnknown`. See `SetDetailViewModel.toggleWishlist` / `AGENTS.md` on why the
    /// wishlist lives on Brickset rather than as a Rebrickable setlist.
    private var wishlistRow: some View {
        Button {
            Task { await viewModel.toggleWishlist() }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isWishlistLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: viewModel.isInWishlist ? "heart.fill" : "heart")
                }
                Text(viewModel.isInWishlist ? "Dans votre liste cadeaux" : "Ajouter à votre liste cadeaux")
            }
            // `.secondary` read as disabled rather than as a live, tappable action (#150) — the
            // accent tint here reads as "you can tap this", matching every other action button
            // on this screen, while still keeping pink once it's actually in the wishlist.
            .foregroundStyle(viewModel.isInWishlist ? .pink : AppTheme.shared.accent)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isWishlistLoading)
        .accessibilityLabel(viewModel.isInWishlist ? "Retirer de la liste cadeaux" : "Ajouter à la liste cadeaux")
    }

    /// Opens the price-alert sheet, and doubles as this set's "an alert is armed" marker (#229) —
    /// shown whatever the collection status, since wanting to be told about a price drop is
    /// independent of owning the set (same reasoning as `wishlistRow`). Both conditions' alerts are
    /// summarised on one line: they're two separate alerts, but two rows here would give a rarely
    /// -used feature more of this screen than it's worth.
    private var priceAlertRow: some View {
        Button {
            showPriceAlertSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: priceAlertIconName)
                Text(priceAlertLabel)
            }
            .foregroundStyle(enabledPriceAlerts.isEmpty ? AppTheme.shared.accent : .orange)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(priceAlerts.isEmpty ? "Créer une alerte de prix" : "Modifier l'alerte de prix")
    }

    private var enabledPriceAlerts: [PriceAlert] {
        priceAlerts.filter(\.isEnabled)
    }

    /// Three states, not two: "no alert", "alert switched off", and "armed". A set whose only alert
    /// is disabled used to render exactly like one with no alert at all, which hid the fact that a
    /// threshold was still stored on it.
    private var priceAlertIconName: String {
        if !enabledPriceAlerts.isEmpty { return "bell.fill" }
        return priceAlerts.isEmpty ? "bell" : "bell.slash"
    }

    private var priceAlertLabel: String {
        let armed = enabledPriceAlerts.sorted { $0.conditionRaw < $1.conditionRaw }
        guard !armed.isEmpty else {
            return priceAlerts.isEmpty
                ? String(localized: "Alerte de prix")
                : String(localized: "Alerte de prix (désactivée)")
        }
        let descriptions = armed.map { alert -> String in
            guard let threshold = alert.effectiveThresholdEUR else { return alert.condition.displayName }
            return String(localized: "\(alert.condition.displayName.lowercased()) sous \(Decimal(threshold).formatted(.currency(code: "EUR")))")
        }
        return String(localized: "Alerte : \(descriptions.joined(separator: ", "))")
    }

    /// Floating button that opens the "quel prix as-tu vu ?" sheet on tap — never auto-presented
    /// (issue #94), shown only for a set not yet in the collection since there's no reason to
    /// compare a rayon price for one already owned.
    private var storePriceCheckFAB: some View {
        Button {
            openPricePrompt()
        } label: {
            Image(systemName: "tag.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .padding(16)
                .background(AppTheme.shared.accent, in: Circle())
                .shadow(radius: 4)
        }
        .padding(20)
        .accessibilityLabel("Vérifier un prix vu en magasin")
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
