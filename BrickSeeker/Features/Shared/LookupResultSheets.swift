import SwiftUI
import SwiftData

/// The single implementation of "present a `ScannerViewModel`'s lookup results" — the
/// SetDetail sheet for `.found` and the ambiguous-picker sheet for `.ambiguous`, with the
/// bindings that resume scanning on dismiss and the cache re-read that seeds SetDetail's
/// initial list name / store price. Previously copy-pasted in 4 views (~200 lines).
///
/// `isGated`: pass `true` while a *nested* presenter owns the same view model's results — the
/// "gate the parent, nest in the child" pattern from AGENTS.md. `HomeView` gates itself with
/// `showHistory || showManualEntry` so History/ManualEntry can present their own nested sheets
/// (closing the result then reveals those screens again, not Home) and so two sibling `.sheet`s
/// never race on the same state change (SwiftUI can't cleanly close one sheet and open another
/// from the same parent in one transaction — this bit hard when a manually-typed set resolved
/// instantly from cache in the same frame the manual-entry sheet was dismissing).
struct LookupResultSheetsModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    let viewModel: ScannerViewModel
    var isGated: Bool = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: setDetailBinding) {
                if case .found(let legoSet, let collectionStatus) = viewModel.state {
                    // A list/gallery screen supplied the list it was showing (#239) → the sheet
                    // pages between its sets. Everything else — camera, manual entry, photo
                    // import, price-drop notification, the galleries inside the sheet itself —
                    // has no list behind it and gets the single, unpaged sheet it always had.
                    if let navigationContext = viewModel.navigationContext,
                       navigationContext.entries[navigationContext.startIndex].legoSet.setNum == legoSet.setNum {
                        SetDetailPagerView(context: navigationContext)
                    } else {
                        SetDetailSheetContent(
                            legoSet: legoSet,
                            collectionStatus: collectionStatus,
                            seedsListNameFromCache: viewModel.lastFoundWasFromCache,
                            reconcileOnAppear: viewModel.lastFoundWasFromCache,
                            isOfflineResult: viewModel.lastFoundWasOffline,
                            pendingPriceScanEvent: viewModel.pendingPriceScanEvent
                        )
                    }
                }
            }
            .sheet(isPresented: ambiguousBinding) {
                if case .ambiguous(let sets) = viewModel.state {
                    AmbiguousSetPickerView(sets: sets) { selected in
                        viewModel.selectAmbiguousSet(selected)
                    } onCancel: {
                        viewModel.resumeScanning()
                    }
                }
            }
    }

    private var setDetailBinding: Binding<Bool> {
        Binding(
            get: {
                guard !isGated else { return false }
                if case .found = viewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { viewModel.resumeScanning() }
            }
        )
    }

    private var ambiguousBinding: Binding<Bool> {
        Binding(
            get: {
                guard !isGated else { return false }
                if case .ambiguous = viewModel.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { viewModel.resumeScanning() }
            }
        )
    }
}

/// One set's `SetDetailView`, seeded with what the local cache already knows about it (its list
/// name, the last lego.com price fetched for it, whether it's on the gift list). Used both by
/// `LookupResultSheetsModifier` for a lone result and by `SetDetailPagerView` for each of its
/// pages (#239), so the two can't drift apart on what a freshly-opened sheet starts with.
struct SetDetailSheetContent: View {
    @Environment(\.modelContext) private var modelContext

    let legoSet: LegoSet
    let collectionStatus: CollectionStatus
    /// `false` only for a result resolved live rather than from the cache — the cached list name
    /// would then be the stale half of an answer the network is about to give in full.
    var seedsListNameFromCache: Bool = true
    var reconcileOnAppear: Bool = false
    var isOfflineResult: Bool = false
    var pendingPriceScanEvent: ScanEvent?
    /// See `SetDetailView.embedsNavigationChrome` — `false` when the pager owns the nav bar.
    var embedsNavigationChrome: Bool = true

    var body: some View {
        let cached = LocalRepository(modelContext: modelContext).cachedSet(setNum: legoSet.setNum)
        SetDetailView(
            legoSet: legoSet,
            collectionStatus: collectionStatus,
            initialListName: seedsListNameFromCache ? cached?.currentListName : nil,
            initialStorePrice: cached?.storePriceEUR.map { StorePrice(amount: $0, currency: "EUR", availability: cached?.storeAvailability) },
            initialStorePriceFetchedAt: cached?.storePriceFetchedAt,
            initialIsInWishlist: cached?.isInWishlist ?? false,
            reconcileOnAppear: reconcileOnAppear,
            isOfflineResult: isOfflineResult,
            pendingPriceScanEvent: pendingPriceScanEvent,
            embedsNavigationChrome: embedsNavigationChrome
        )
    }
}

extension View {
    /// Presents SetDetail/AmbiguousSetPicker sheets for `viewModel`'s lookup results — see
    /// `LookupResultSheetsModifier`. Any new presenter of lookup results should use this rather
    /// than re-implementing the bindings/sheets.
    func lookupResultSheets(for viewModel: ScannerViewModel, isGated: Bool = false) -> some View {
        modifier(LookupResultSheetsModifier(viewModel: viewModel, isGated: isGated))
    }
}

extension ScannerViewModel {
    /// True while an (ungated) `lookupResultSheets` presenter is showing one of its two sheets —
    /// derived from `state` the same way the modifier's bindings are. `ScannerView` uses this to
    /// pause the camera while a result is on screen.
    var isPresentingLookupResult: Bool {
        switch state {
        case .found, .ambiguous: return true
        default: return false
        }
    }
}
