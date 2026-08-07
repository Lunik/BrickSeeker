import SwiftUI
import SwiftData

/// Pages `SetDetailView` left/right through the list the sheet was opened from (#239), when the
/// presenter supplied a `SetNavigationContext`. Without one the sheet is presented as a plain
/// `SetDetailSheetContent` and nothing here is involved.
///
/// **Why a paged `TabView` rather than a `DragGesture`.** The sheet already contains three
/// horizontal `ScrollView` galleries ("sets contenant cette minifig", "minifigs de ce set", "sets
/// similaires") plus the sheet's own interactive vertical dismissal. A drag gesture spanning the
/// whole sheet would have to arbitrate against all of them by hand; UIKit's paging already does it
/// natively — the innermost scroll view wins, so a swipe *on* a gallery scrolls that gallery and
/// never changes set. It also gives the expected rubber-band at both ends, which is the whole of
/// the "no wrap-around, just a small bounce" requirement.
///
/// **Why only one page ever loads, and why that isn't visible.** Opening a set is expensive:
/// `SetDetailView`'s `.task`s fetch the lego.com price through a hidden `WKWebView` that solves a
/// Cloudflare challenge (seconds), plus BrickLink/Amazon/Cdiscount quotes and the minifig/
/// similar-set galleries. A paged `TabView` normally keeps its neighbours alive, which would fire
/// every one of those on each swipe.
///
/// The split is therefore between *rendering* and *loading*, not between a placeholder and the real
/// thing. Neighbours build the **complete** `SetDetailView` — image, status, quantity, valuation,
/// cached quotes, history chart, scans, all of it local — with `loadsLiveData: false`, so they cost
/// no network at all; becoming the current page only flips that flag, which starts the requests
/// without rebuilding a single view. A swipe lands on a page that already looks finished.
///
/// The first take rendered a spinner-and-header placeholder instead and swapped it for the real
/// view once the page settled. It jumped, visibly: two different view types means SwiftUI tears the
/// first one down and lays the second one out, so the whole page popped into place a beat after the
/// gesture ended. Don't reintroduce a placeholder page here.
///
/// `liveIndex` still trails `index` by `settleDelay`, so flicking through five sets issues one
/// round of requests rather than five — but that delay is now invisible, since what it gates is
/// network work rather than content.
struct SetDetailPagerView: View {
    let context: SetNavigationContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The page the `TabView` is showing. Moves with the swipe (and with the toolbar buttons).
    @State private var index: Int
    /// The settled page: the one allowed to hit the network, and the centre of the built window.
    /// Starts equal to `index` so the set the user tapped loads immediately, with no settle delay.
    ///
    /// The point of it being *separate* from `index` is that it does not move during a gesture —
    /// see `isMaterialised`, which is why the window is keyed on this and not on `index`.
    @State private var liveIndex: Int

    /// How long a page has to stay put before it counts as settled. It gates requests and the
    /// window, never the content, so it costs nothing visually: long enough that flicking through
    /// several sets doesn't fire a round of requests for each one passed through, and that a
    /// gesture is comfortably over before the window is allowed to move.
    private static let settleDelay = Duration.milliseconds(400)

    init(context: SetNavigationContext) {
        self.context = context
        _index = State(initialValue: context.startIndex)
        _liveIndex = State(initialValue: context.startIndex)
    }

    var body: some View {
        // The `NavigationStack` lives here, not in each page (`embedsNavigationChrome: false`), so
        // the bar and its buttons stay put while the content slides underneath.
        NavigationStack {
            TabView(selection: $index) {
                ForEach(context.entries.indices, id: \.self) { pageIndex in
                    page(at: pageIndex)
                        .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // The dots are hidden — a collection is hundreds of sets long, so they'd be a grey
            // smear rather than a position. This title says the same thing legibly, and doubles as
            // the discoverability hint that there is anything to swipe at all.
            .navigationTitle("\(index + 1) sur \(context.entries.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A gesture alone isn't an affordance, and VoiceOver swallows horizontal swipes
                // for its own navigation (same requirement as #143) — these buttons are the
                // non-gesture way to do it, for everyone.
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        move(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(index == 0)
                    .accessibilityLabel("Set précédent")

                    Button {
                        move(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(index == context.entries.count - 1)
                    .accessibilityLabel("Set suivant")
                }
                // The one "Fermer" for the whole sequence — the pages deliberately don't declare
                // their own (see `SetDetailView.embedsNavigationChrome`).
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") {
                        dismiss()
                    }
                }
            }
        }
        .task(id: index) {
            await settle()
        }
        .onChange(of: liveIndex, initial: true) { _, newValue in
            ensureCachedRow(for: context.entries[newValue])
        }
    }

    /// How far either side of `liveIndex` pages stay built. Two, not one, so that whichever way the
    /// next swipe goes — and the one after it, before `settleDelay` has elapsed — the page is
    /// already there and this window never has to move mid-gesture. Everything outside is
    /// `Color.clear`: a several-hundred-set collection can't afford a built page each.
    private static let materialisedRadius = 2

    /// **Deliberately keyed on `liveIndex`, never on `index`.** A paged `TabView` writes its
    /// selection binding the moment a drag passes the halfway point, *while the finger is still
    /// down* — so a window keyed on `index` would shift mid-gesture, tearing one page down and
    /// building another underneath the user. Measured, on a slow drag: the content tracked the
    /// finger 1:1 to 57%, then snapped back 32 pt in 11 ms and jumped straight to the next set,
    /// 1.7 s before the finger lifted. That was the "ça saute". `liveIndex` only moves once a page
    /// has settled, so during a gesture this window is frozen and nothing is rebuilt.
    private func isMaterialised(_ pageIndex: Int) -> Bool {
        abs(pageIndex - liveIndex) <= Self.materialisedRadius
    }

    @ViewBuilder
    private func page(at pageIndex: Int) -> some View {
        let entry = context.entries[pageIndex]
        if isMaterialised(pageIndex) {
            // One expression, not a placeholder/real-view branch: promoting a page to live only
            // flips `loadsLiveData`, so SwiftUI keeps the very same view — nothing is torn down,
            // rebuilt or re-laid-out under the user. The page slid in already looking finished
            // (its whole content comes from the local cache) and simply stays there.
            SetDetailSheetContent(
                legoSet: entry.legoSet,
                // The local cache is the freshest thing we have here: the resolve flow writes the
                // status it just found into it (`LocalRepository.cacheFoundState`), and every list
                // this context can come from is backed by it. The snapshot's own status is the
                // fallback for a catalogue entry that has never had a row.
                collectionStatus: cachedCollectionStatus(for: entry) ?? entry.collectionStatus,
                // Same contract as any other cache-first display in this app: show what's known
                // instantly, reconcile silently against the live status once on screen.
                reconcileOnAppear: true,
                embedsNavigationChrome: false,
                loadsLiveData: pageIndex == liveIndex
            )
        } else {
            Color.clear
        }
    }

    private func move(by offset: Int) {
        let target = index + offset
        guard context.entries.indices.contains(target) else { return }
        withAnimation {
            index = target
        }
    }

    /// Promotes the settled page to `liveIndex`. Re-run (and cancelled) by `.task(id: index)` on
    /// every page change, which is what makes a fast flick collapse into a single load.
    private func settle() async {
        guard index != liveIndex else { return }
        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled else { return }
        liveIndex = index
    }

    private func cachedCollectionStatus(for entry: SetNavigationContext.Entry) -> CollectionStatus? {
        LocalRepository(modelContext: modelContext).cachedSet(setNum: entry.legoSet.setNum)?.asCollectionStatus()
    }

    /// Mirrors `NewSetsView.ensureCached` / `MinifigGalleryView.cacheEntryIfNeeded`, which both run
    /// before opening a catalogue entry: `LocalRepository.setWishlistStatus`/`setCollectionStatus`
    /// silently no-op without an existing row, so swiping onto a set that has never been scanned or
    /// owned would otherwise give it a gift-list heart that doesn't stick. Only ever creates —
    /// an existing row is left alone rather than overwritten with the (older) snapshot.
    private func ensureCachedRow(for entry: SetNavigationContext.Entry) {
        let repository = LocalRepository(modelContext: modelContext)
        guard repository.cachedSet(setNum: entry.legoSet.setNum) == nil else { return }
        repository.cacheSet(
            entry.legoSet,
            isInCollection: entry.isInCollection,
            listId: entry.listId,
            listName: entry.listName,
            markAsScanned: false
        )
        if entry.isInCollection, entry.quantity > 1 {
            repository.setQuantity(setNum: entry.legoSet.setNum, quantity: entry.quantity)
        }
    }
}
