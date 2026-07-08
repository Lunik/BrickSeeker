import SwiftUI
import SwiftData

/// Browses sets marked `wanted` on Brickset (see `AGENTS.md`/issue #6) — pushed from Home like
/// `CollectionView`, same convention: no own `NavigationStack`, relies on the parent's.
struct WishlistView: View {
    @Query(filter: #Predicate<CachedSet> { $0.isInWishlist }, sort: \CachedSet.name)
    private var cachedSets: [CachedSet]
    @Query private var allCachedPrices: [CachedSetPrice]
    @Environment(\.modelContext) private var modelContext
    @State private var showImportSheet = false
    @State private var errorMessage: String?
    var bricksetRepository: BricksetRepositoryProtocol = BricksetRepository()
    var rebrickableRepository: RebrickableRepositoryProtocol = RebrickableRepository()
    let lookupViewModel: ScannerViewModel

    /// Memoized from `allCachedPrices` (see the `.onChange` in `body`), same pattern as `CollectionView`.
    @State private var pricesBySetNum: [String: [PriceQuote]] = [:]

    @State private var editMode: EditMode = .inactive
    @State private var selectedSetNums: Set<String> = []
    @State private var isPerformingBulkAction = false
    @State private var selectionActionError: String?
    @State private var showAddToListPicker = false
    @State private var showRemoveConfirmation = false

    /// Amazon → lego.com → BrickLink new → BrickLink used (see `resolveWishlistPrice`) — Amazon
    /// first per request, and always this fixed chain regardless of any list condition, since a
    /// wishlist set isn't necessarily owned or tied to a `CachedSetList`.
    private func resolvedPrice(for cached: CachedSet) -> Double? {
        resolveWishlistPrice(
            storePriceEUR: cached.storePriceEUR,
            quotes: pricesBySetNum[cached.setNum] ?? []
        )
    }

    private var selectedCachedSets: [CachedSet] {
        cachedSets.filter { selectedSetNums.contains($0.setNum) }
    }

    /// Reuses `CollectionPriceUpdater.shared`, same as `CollectionView`/`HistoryView`'s bulk
    /// refresh (#141) — a single global run, so a concurrent/paused unrelated job means `.busy`,
    /// not silently hijacking that other queue.
    private func refreshSelectedPrices() async {
        selectionActionError = nil
        let selected = selectedCachedSets
        guard !selected.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let outcome = await CollectionPriceUpdater.shared.refreshPrices(
            for: selected.map { $0.asLegoSet() },
            persist: CollectionPriceUpdater.persistClosure(modelContext: modelContext)
        )

        switch outcome {
        case .completed:
            editMode = .inactive
        case .busy:
            selectionActionError = String(
                localized: "Une actualisation des prix de la collection est déjà en cours ou en attente de reprise. Terminez-la avant d'actualiser une sélection."
            )
        case .cancelled:
            break
        }
    }

    /// Bulk counterpart to `remove(_:)` — same Brickset-first-then-local-cache order, so a
    /// failed removal (offline, expired session) doesn't desync a set that Brickset still lists.
    private func removeSelectedFromWishlist() async {
        selectionActionError = nil
        guard NetworkMonitor.shared.isConnected else {
            selectionActionError = UserMessage.offlineStatus
            return
        }
        let selected = selectedCachedSets
        guard !selected.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in selected {
            do {
                try await bricksetRepository.removeFromWishlist(setNum: cached.setNum)
                localRepository.setWishlistStatus(setNum: cached.setNum, isInWishlist: false)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = String(localized: "\(failureCount) set(s) n'ont pas pu être retirés de la liste cadeaux.")
        } else {
            editMode = .inactive
        }
    }

    /// Adds every selected set to `listId` on Rebrickable — doesn't touch wishlist status, same
    /// as `SetDetailViewModel.addToList` (a set can be both owned and still wanted).
    private func addSelectedToCollection(listId: Int, listName: String) async {
        selectionActionError = nil
        let selected = selectedCachedSets
        guard !selected.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in selected {
            do {
                try await rebrickableRepository.addSetToList(setNum: cached.setNum, listId: listId)
                localRepository.setCollectionStatus(setNum: cached.setNum, isInCollection: true, listId: listId, listName: listName)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = String(localized: "\(failureCount) set(s) n'ont pas pu être ajoutés à la collection. Vérifiez votre connexion.")
        } else {
            editMode = .inactive
        }
    }

    var body: some View {
        Group {
            if cachedSets.isEmpty {
                ContentUnavailableView(
                    "Liste cadeaux vide",
                    systemImage: "heart",
                    description: Text("Ajoute un set à ta liste cadeaux depuis sa fiche, ou importe une liste Rebrickable publique.")
                )
            } else {
                List(cachedSets, id: \.setNum, selection: $selectedSetNums) { cached in
                    Button {
                        lookupViewModel.lookupSetNumber(cached.setNum, source: .listReopen)
                    } label: {
                        SetRowView(
                            setNum: cached.setNum,
                            name: cached.name,
                            setImgUrl: cached.setImgUrl,
                            resolvedPrice: resolvedPrice(for: cached)
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
            // Pinned to the bottom bar rather than the top-trailing spot, matching Collection/
            // History (#141) — kept consistent across all three even though Wishlist has no
            // search bar of its own to fight with.
            if !cachedSets.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    if editMode.isEditing {
                        Menu {
                            Button {
                                Task { await refreshSelectedPrices() }
                            } label: {
                                Label("Actualiser les prix", systemImage: "arrow.clockwise")
                            }
                            Button {
                                showAddToListPicker = true
                            } label: {
                                Label("Ajouter à la collection", systemImage: "shippingbox")
                            }
                            // Not `role: .destructive` — SwiftUI previews a destructive Menu item
                            // across the List's selected rows the instant the Menu opens (a red
                            // flash on the selection background), not just on tap. The icon still
                            // renders in the app's red accent color either way.
                            Button {
                                showRemoveConfirmation = true
                            } label: {
                                Label("Retirer de la liste cadeaux", systemImage: "trash")
                            }
                        } label: {
                            if isPerformingBulkAction {
                                ProgressView()
                            } else {
                                Label("Actions (\(selectedSetNums.count))", systemImage: "ellipsis.circle")
                            }
                        }
                        .disabled(selectedSetNums.isEmpty || isPerformingBulkAction)
                    }
                    Button {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    } label: {
                        if editMode.isEditing {
                            Text("Terminé")
                        } else {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                    .accessibilityLabel(editMode.isEditing ? "Terminé" : "Actions")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, newValue in
            if !newValue.isEditing {
                selectedSetNums.removeAll()
            }
        }
        .sheet(isPresented: $showImportSheet) {
            BricksetWishlistImportSheet()
        }
        .sheet(isPresented: $showAddToListPicker) {
            ListPickerView(repository: rebrickableRepository) { listId, listName in
                Task { await addSelectedToCollection(listId: listId, listName: listName) }
            }
        }
        .alert("Retirer de la liste cadeaux ?", isPresented: $showRemoveConfirmation) {
            Button("Retirer", role: .destructive) {
                Task { await removeSelectedFromWishlist() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(selectedSetNums.count) set(s) seront retirés de votre liste cadeaux.")
        }
        .onChange(of: SetPriceIndex.Version(allCachedPrices), initial: true) { _, _ in
            pricesBySetNum = SetPriceIndex.pricesBySetNum(allCachedPrices)
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
        .alert(
            "Action impossible",
            isPresented: Binding(
                get: { selectionActionError != nil },
                set: { isPresented in if !isPresented { selectionActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(selectionActionError ?? "")
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
