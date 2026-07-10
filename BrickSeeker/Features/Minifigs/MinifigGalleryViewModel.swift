import Foundation
import Observation

/// Owns the offline minifig catalogue's loading/downloading lifecycle for `MinifigGalleryView`.
/// Filtering, sorting, sectioning and windowing are deliberately kept out of this class and live
/// in the view instead (as plain computed properties over `allEntries`), mirroring
/// `CollectionView`'s split with `CollectionViewModel` — those depend on reactive `@Query` data
/// (owned set numbers, cached prices) that only a view can hold.
@Observable
@MainActor
final class MinifigGalleryViewModel {
    var allEntries: [OfflineMinifigCatalogStore.MinifigCatalogEntry] = []
    var isLoadingCatalog = false
    var catalogMetadata: OfflineMinifigCatalogStore.Metadata?

    var isDownloadingCatalog = false
    var downloadProgress: Double = 0
    var downloadErrorMessage: String?

    private let store: OfflineMinifigCatalogStore

    init(store: OfflineMinifigCatalogStore = .shared) {
        self.store = store
        self.catalogMetadata = store.metadata
    }

    var hasCatalog: Bool { catalogMetadata != nil }

    var availableThemeIds: [Int] {
        Array(Set(allEntries.compactMap(\.themeId)))
    }

    var availableYears: [Int] {
        Array(Set(allEntries.compactMap(\.year))).sorted(by: >)
    }

    func loadCatalog() async {
        guard hasCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        allEntries = await store.allEntries()
    }

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

    func purgeCatalog() {
        store.purge()
        catalogMetadata = nil
        allEntries = []
    }
}
