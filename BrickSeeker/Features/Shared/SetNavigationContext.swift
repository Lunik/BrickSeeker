import Foundation

/// The list a `SetDetailView` was opened from (#239), carried down to the sheet so it can page to
/// the previous/next item without going back to the list and reopening another row.
///
/// **A snapshot, deliberately not a live list.** The entries are value types captured the moment
/// the row was tapped, in the order the screen was *actually displaying* them — filters, search and
/// sort included, which is the whole point: the Collection sorted by descending price does not have
/// the same "suivant" as History sorted by date. Snapshotting also keeps the sequence stable while
/// the sheet is open: removing the current set from the collection (an action the sheet itself
/// offers) must not renumber what's under the user's finger.
///
/// Each entry carries what the presenting screen already knew about the set's ownership rather than
/// just its `set_num`. `NewSetsView`/`MinifigGalleryView` browse *catalogues* where most items have
/// no `CachedSet` row at all until they're opened once (see their `ensureCached`/`cacheEntryIfNeeded`),
/// so re-deriving "owned" from the local cache alone would show an owned minifig as missing.
///
/// Absent (`nil`) for every entry point that has no list behind it — a camera scan, a manual entry,
/// a photo import, a price-drop notification, and the "sets similaires"/"minifigs de ce set"
/// galleries *inside* the sheet (second-level sheets don't page, see `SetDetailPagerView`). The
/// swipe is simply inactive there, which is the honest answer: there is no list.
struct SetNavigationContext: Equatable {
    /// One item of the snapshot. `isInCollection`/`listId`/`listName`/`quantity` mirror the
    /// `CachedSet` columns `SetDetailView` would otherwise read for itself — see the type doc for
    /// why they travel with the entry instead.
    struct Entry: Equatable {
        let legoSet: LegoSet
        let isInCollection: Bool
        let listId: Int?
        let listName: String?
        let quantity: Int

        init(
            legoSet: LegoSet,
            isInCollection: Bool = false,
            listId: Int? = nil,
            listName: String? = nil,
            quantity: Int = 1
        ) {
            self.legoSet = legoSet
            self.isInCollection = isInCollection
            self.listId = listId
            self.listName = listName
            self.quantity = quantity
        }

        /// The same shape `CachedSet.asCollectionStatus()` produces — used as the seed for a page
        /// the user swiped to, which `SetDetailView` then reconciles live and silently on appear
        /// (`reconcileOnAppear`), exactly like any other cache-first display in this app.
        var collectionStatus: CollectionStatus {
            guard isInCollection else { return .notInCollection }
            return .inCollection(UserSet(legoSet: legoSet, quantity: quantity, includeSpares: false, listId: listId))
        }
    }

    let entries: [Entry]
    let startIndex: Int

    /// Fails (returns `nil`) when there is nothing to page to — a single-item list, or a set that
    /// isn't in the array it was supposedly opened from. A `nil` context leaves the sheet exactly
    /// as it was before #239 rather than showing dead previous/next controls.
    init?(entries: [Entry], startIndex: Int) {
        guard entries.count > 1, entries.indices.contains(startIndex) else { return nil }
        self.entries = entries
        self.startIndex = startIndex
    }

    /// Locates `setNum` in an already-built entry array — for the catalogue screens
    /// (`NewSetsView`/`MinifigGalleryView`), which have to compose their entries themselves.
    init?(entries: [Entry], startingAt setNum: String) {
        guard let startIndex = entries.firstIndex(where: { $0.legoSet.setNum == setNum }) else { return nil }
        self.init(entries: entries, startIndex: startIndex)
    }

    /// Builds a context from a screen's already-filtered/sorted `CachedSet` array — the shape
    /// `CollectionView`/`HistoryView`/`WishlistView` all hold (`filteredSets`).
    init?(cachedSets: [CachedSet], startingAt setNum: String) {
        guard let startIndex = cachedSets.firstIndex(where: { $0.setNum == setNum }) else { return nil }
        self.init(
            entries: cachedSets.map { cached in
                Entry(
                    legoSet: cached.asLegoSet(),
                    isInCollection: cached.isInCollection,
                    listId: cached.currentListId,
                    listName: cached.currentListName,
                    quantity: cached.quantity
                )
            },
            startIndex: startIndex
        )
    }
}
