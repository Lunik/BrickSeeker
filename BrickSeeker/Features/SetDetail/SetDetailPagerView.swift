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
/// **Why only one page is ever real.** Opening a set is expensive: `SetDetailView`'s `.task`s fetch
/// the lego.com price through a hidden `WKWebView` that solves a Cloudflare challenge (seconds),
/// plus BrickLink/Amazon/Cdiscount quotes and the minifig/similar-set galleries. A paged `TabView`
/// normally keeps its neighbours alive, which would double every one of those on each swipe — so
/// neighbours render `inertPage`, a static header with no network path at all, and the real view is
/// only built for `liveIndex`. `liveIndex` additionally trails `index` by `settleDelay`, so flicking
/// through five sets loads the one the user stopped on, not five.
struct SetDetailPagerView: View {
    let context: SetNavigationContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The page the `TabView` is showing. Moves with the swipe (and with the toolbar buttons).
    @State private var index: Int
    /// The page whose `SetDetailView` is actually instantiated — see the type doc. Starts equal to
    /// `index` so the set the user tapped loads immediately, with no settle delay.
    @State private var liveIndex: Int

    /// How long a page has to stay put before it starts loading. Just longer than the paging
    /// animation, so a deliberate one-set swipe barely shows the placeholder while a fast flick
    /// through several never materialises the ones in between.
    private static let settleDelay = Duration.milliseconds(350)

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

    @ViewBuilder
    private func page(at pageIndex: Int) -> some View {
        let entry = context.entries[pageIndex]
        if pageIndex == liveIndex {
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
                embedsNavigationChrome: false
            )
        } else if abs(pageIndex - index) <= 1 {
            inertPage(for: entry.legoSet)
        } else {
            // Far-away pages exist only so the `TabView` has something to tag — building even a
            // placeholder for all of them would mean hundreds of image loads on a large collection.
            Color.clear
        }
    }

    /// What a neighbouring page shows: the exact header `SetDetailView` opens with — hero image,
    /// number, name, year and part count, all of which the snapshot already carries — so the swap
    /// to the real view reads as the rest of the page filling in rather than a different screen.
    /// Deliberately inert: no view model, no `.task`, and a cache-only image (`refreshesLive:
    /// false`), so sliding past a set costs nothing.
    private func inertPage(for legoSet: LegoSet) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                CachedRemoteImage(url: URL(string: legoSet.setImgUrl ?? ""), refreshesLive: false) {
                    Image(systemName: "shippingbox")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(40)
                }
                .frame(height: 220)

                VStack(spacing: 4) {
                    Text(legoSet.setNum.baseSetNum)
                        .font(.title2.bold())
                    Text(legoSet.name)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    Text("\(legoSet.year) · \(legoSet.numParts) pièces")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ProgressView()
                    .padding(.top, 24)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .scrollDisabled(true)
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
