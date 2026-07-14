import Foundation
import Observation

/// Owns the offline catalogue's loading/downloading lifecycle for `NewSetsView`, mirroring
/// `MinifigGalleryViewModel`'s split with its view: filtering, sorting and windowing are plain
/// computed properties on the view itself (they depend on reactive `@Query` data — owned/wishlist
/// status, cached prices — that only a view can hold), not this class.
@Observable
@MainActor
final class NewSetsViewModel {
    var allSets: [LegoSet] = []
    /// `set_num → firstSeenAt` (`OfflineCatalogStore.allFirstSeenAt()`) — backs the `.dateAdded`
    /// sort, the actually-accurate "new" signal (see that store's doc). Loaded alongside `allSets`
    /// since both come from the same snapshot generation.
    var firstSeenBySetNum: [String: Date] = [:]
    var isLoadingCatalog = false
    var catalogMetadata: OfflineCatalogStore.Metadata?

    var isDownloadingCatalog = false
    var downloadProgress: Double = 0
    var downloadErrorMessage: String?

    private let store: OfflineCatalogStore

    init(store: OfflineCatalogStore = .shared) {
        self.store = store
        self.catalogMetadata = store.metadata
    }

    var hasCatalog: Bool { catalogMetadata != nil }

    var availableThemeIds: [Int] {
        Array(Set(allSets.map(\.themeId)))
    }

    var availableYears: [Int] {
        Array(Set(allSets.map(\.year))).sorted(by: >)
    }

    /// `allSets` only ever holds sets seen *after* `OfflineCatalogStore.initialSyncAt` — see that
    /// store's doc for why: the first-ever download can't tell "genuinely added to Rebrickable's
    /// catalogue" apart from "just synced to this device for the first time", so everything from
    /// that initial import is deliberately excluded, not just left unsorted. `nil` baseline (no
    /// download has completed under this tracking yet, including pre-#185 installs that already
    /// had a snapshot) means nothing is confirmed "new" yet, so `allSets` is empty rather than
    /// showing the whole unfiltered catalogue.
    func loadCatalog() async {
        guard hasCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        async let sets = store.allSets()
        async let firstSeen = store.allFirstSeenAt()
        let rawSets = await sets
        firstSeenBySetNum = await firstSeen

        guard let initialSyncAt = store.initialSyncAt else {
            allSets = []
            return
        }
        allSets = rawSets.filter {
            guard let seenAt = firstSeenBySetNum[$0.setNum] else { return false }
            return seenAt > initialSyncAt
        }
    }

    /// Shared by the empty-state "Télécharger le catalogue" CTA (catalog never downloaded) and the
    /// toolbar's "Actualiser le catalogue" button (catalog already present, pulling in anything
    /// Rebrickable added since) — both just mean "make the on-disk snapshot fresh".
    func downloadCatalog() async {
        isDownloadingCatalog = true
        downloadProgress = 0
        downloadErrorMessage = nil
        defer { isDownloadingCatalog = false }

        do {
            try await store.download { [weak self] value in
                self?.downloadProgress = value
            }
            catalogMetadata = store.metadata
            await loadCatalog()
        } catch let error as APIError {
            downloadErrorMessage = error.errorDescription
        } catch {
            downloadErrorMessage = String(localized: "Téléchargement impossible. Vérifiez votre réseau.")
        }
    }
}
