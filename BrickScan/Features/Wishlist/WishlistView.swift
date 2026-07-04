import SwiftUI
import SwiftData

/// Browses sets marked `wanted` on Brickset (see `AGENTS.md`/issue #6) — pushed from Home like
/// `CollectionView`, same convention: no own `NavigationStack`, relies on the parent's.
struct WishlistView: View {
    @Query(filter: #Predicate<CachedSet> { $0.isInWishlist }, sort: \CachedSet.name)
    private var cachedSets: [CachedSet]
    @Environment(\.modelContext) private var modelContext
    @State private var showImportSheet = false
    @State private var errorMessage: String?
    var bricksetRepository: BricksetRepositoryProtocol = BricksetRepository()
    let lookupViewModel: ScannerViewModel

    var body: some View {
        Group {
            if cachedSets.isEmpty {
                ContentUnavailableView(
                    "Liste cadeaux vide",
                    systemImage: "heart",
                    description: Text("Ajoute un set à ta liste cadeaux depuis sa fiche, ou importe une liste Rebrickable publique.")
                )
            } else {
                List(cachedSets, id: \.setNum) { cached in
                    Button {
                        lookupViewModel.lookupSetNumber(cached.setNum)
                    } label: {
                        SetRowView(
                            setNum: cached.setNum,
                            name: cached.name,
                            setImgUrl: cached.setImgUrl
                        ) {
                            if cached.isInCollection {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            remove(cached)
                        } label: {
                            Label("Retirer", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Liste cadeaux")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Importer depuis Rebrickable")
            }
        }
        .sheet(isPresented: $showImportSheet) {
            BricksetWishlistImportSheet()
        }
        .alert(
            "Erreur",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    /// Removes on Brickset first, only clearing `isInWishlist` locally (which drops the row via
    /// this view's `@Query` predicate) once that succeeds — otherwise a failed swipe (offline,
    /// expired Brickset session) would desync the app from the actual Brickset wishlist.
    private func remove(_ cached: CachedSet) {
        guard NetworkMonitor.shared.isConnected else {
            errorMessage = UserMessage.offlineStatus
            return
        }
        let setNum = cached.setNum
        Task {
            do {
                try await bricksetRepository.removeFromWishlist(setNum: setNum)
                LocalRepository(modelContext: modelContext).setWishlistStatus(setNum: setNum, isInWishlist: false)
            } catch APIError.missingCredentials {
                errorMessage = String(localized: "Lie ton compte Brickset dans Réglages pour utiliser la liste cadeaux.")
            } catch let error as APIError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = String(localized: "Une erreur est survenue")
            }
        }
    }
}
