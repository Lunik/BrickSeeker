import SwiftUI
import SwiftData

/// Browses sets marked `wanted` on Brickset (see `AGENTS.md`/issue #6) — pushed from Home like
/// `CollectionView`, same convention: no own `NavigationStack`, relies on the parent's.
struct WishlistView: View {
    @Query(filter: #Predicate<CachedSet> { $0.isInWishlist }, sort: \CachedSet.name)
    private var cachedSets: [CachedSet]
    @Query private var allCachedPrices: [CachedSetPrice]
    @Environment(\.modelContext) private var modelContext
    @Bindable private var filter = WishlistFilterState.shared
    @State private var showImportSheet = false
    @State private var showFilters = false
    @State private var errorMessage: String?
    var bricksetRepository: BricksetRepositoryProtocol = BricksetRepository()
    var rebrickableRepository: RebrickableRepositoryProtocol = RebrickableRepository()
    let lookupViewModel: ScannerViewModel

    /// Memoized from `allCachedPrices` (see the `.onChange` in `body`), same pattern as `CollectionView`.
    @State private var pricesBySetNum: [String: [PriceQuote]] = [:]

    @State private var isSelecting = false
    @State private var selectedSetNums: Set<String> = []
    @State private var isPerformingBulkAction = false
    @State private var selectionActionError: String?
    @State private var showAddToListPicker = false
    @State private var showRemoveConfirmation = false
    /// Sets targeted by the next `showAddToListPicker`/`showRemoveConfirmation` flow — either the
    /// current multi-select checkbox selection, or the single row long-pressed for a context menu
    /// action (#172), set right before presenting the sheet/alert.
    @State private var pendingActionTargets: [CachedSet] = []

    private var filteredSets: [CachedSet] { cachedSets.filteredAndSorted(by: filter, resolvedPrice: resolvedPrice) }
    private var availableThemeIds: [Int] { Set(cachedSets.map(\.themeId)).sorted() }
    private var availableYears: [Int] { Set(cachedSets.map(\.year)).sorted(by: >) }

    private var areAllFilteredSelected: Bool {
        !filteredSets.isEmpty && filteredSets.allSatisfy { selectedSetNums.contains($0.setNum) }
    }

    private func toggleSelection(_ setNum: String) {
        if selectedSetNums.contains(setNum) {
            selectedSetNums.remove(setNum)
        } else {
            selectedSetNums.insert(setNum)
        }
    }

    /// Selects/deselects only the sets currently visible under the active filters/search (#164) —
    /// never the whole wishlist.
    private func toggleSelectAll() {
        if areAllFilteredSelected {
            selectedSetNums.subtract(filteredSets.map(\.setNum))
        } else {
            selectedSetNums.formUnion(filteredSets.map(\.setNum))
        }
    }

    /// Amazon → lego.com → BrickLink new → BrickLink used (see `resolveWishlistPrice`) — Amazon
    /// first per request, and always this fixed chain regardless of any list condition, since a
    /// wishlist set isn't necessarily owned or tied to a `CachedSetList`.
    private func resolvedPrice(for cached: CachedSet) -> Double? {
        resolveWishlistPrice(
            storePriceEUR: cached.storePriceEUR,
            quotes: pricesBySetNum[cached.setNum] ?? []
        )
    }

    /// Caption for the row price (issue #157) — "Meilleure offre" covers the common case, but a
    /// wishlist skews toward retired/hard-to-find sets where `resolveWishlistPrice` can silently
    /// fall through to a BrickLink used price (see `resolveWishlistPriceCondition`'s doc comment).
    private func priceLabel(for cached: CachedSet) -> String? {
        switch resolveWishlistPriceCondition(storePriceEUR: cached.storePriceEUR, quotes: pricesBySetNum[cached.setNum] ?? []) {
        case .newSet: return "Meilleure offre"
        case .used: return "Meilleure offre (occasion)"
        case nil: return nil
        }
    }

    private var selectedCachedSets: [CachedSet] {
        cachedSets.filter { selectedSetNums.contains($0.setNum) }
    }

    /// Reuses `CollectionPriceUpdater.shared`, same as `CollectionView`/`HistoryView`'s bulk
    /// refresh (#141) — a single global run, so a concurrent/paused unrelated job means `.busy`,
    /// not silently hijacking that other queue. Shared by the bulk menu (`selectedCachedSets`)
    /// and the row context menu (`[cached]`, #172).
    private func refreshPrices(for sets: [CachedSet]) async {
        selectionActionError = nil
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let outcome = await CollectionPriceUpdater.shared.refreshPrices(
            for: sets.map { $0.asLegoSet() },
            persist: CollectionPriceUpdater.persistClosure(modelContext: modelContext)
        )

        switch outcome {
        case .completed:
            isSelecting = false
        case .busy:
            selectionActionError = String(
                localized: "Une actualisation des prix de la collection est déjà en cours ou en attente de reprise. Terminez-la avant d'actualiser une sélection."
            )
        case .cancelled:
            break
        }
    }

    /// Counterpart to `remove(_:)` (used by the row's swipe action, which removes without
    /// confirmation) — this path keeps the confirmation alert, shared by the bulk menu
    /// (`selectedCachedSets`) and the row context menu (`[cached]`, via `pendingActionTargets`,
    /// #172). Same Brickset-first-then-local-cache order, so a failed removal (offline, expired
    /// session) doesn't desync a set that Brickset still lists.
    private func removeFromWishlist(_ sets: [CachedSet]) async {
        selectionActionError = nil
        guard NetworkMonitor.shared.isConnected else {
            selectionActionError = UserMessage.offlineStatus
            return
        }
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in sets {
            do {
                try await bricksetRepository.removeFromWishlist(setNum: cached.setNum)
                localRepository.setWishlistStatus(setNum: cached.setNum, isInWishlist: false)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = setsCountSentence(
                failureCount,
                singular: "n'a pas pu être retiré de la liste cadeaux.",
                plural: "n'ont pas pu être retirés de la liste cadeaux."
            )
        } else {
            isSelecting = false
        }
    }

    /// Adds every set in `sets` to `listId` on Rebrickable — doesn't touch wishlist status, same
    /// as `SetDetailViewModel.addToList` (a set can be both owned and still wanted). Shared by the
    /// bulk menu and the row context menu (`[cached]`, via `pendingActionTargets`, #172).
    private func addToCollection(_ sets: [CachedSet], listId: Int, listName: String) async {
        selectionActionError = nil
        guard !sets.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for cached in sets {
            do {
                try await rebrickableRepository.addSetToList(setNum: cached.setNum, listId: listId)
                localRepository.setCollectionStatus(setNum: cached.setNum, isInCollection: true, listId: listId, listName: listName)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = setsCountSentence(
                failureCount,
                singular: "n'a pas pu être ajouté à la collection. Vérifiez votre connexion.",
                plural: "n'ont pas pu être ajoutés à la collection. Vérifiez votre connexion."
            )
        } else {
            isSelecting = false
        }
    }

    var body: some View {
        Group {
            if cachedSets.isEmpty {
                ContentUnavailableView(
                    "Liste cadeaux vide",
                    // `heart` (outline) here, `heart.fill` everywhere else the wishlist marker
                    // shows (`SetRowView`, this same button's own toolbar icon) — mismatched
                    // iconography for the same concept (#156).
                    systemImage: "heart.fill",
                    // The old copy promised "importer une liste Rebrickable publique" — the real
                    // flow is a CSV file picker, and the file has to be downloaded from
                    // Rebrickable first (#147); this now says what actually happens.
                    description: Text("Ajoutez un set à votre liste cadeaux depuis sa fiche, ou importez le CSV d'une liste Rebrickable avec le bouton en haut.")
                )
            } else if filteredSets.isEmpty {
                ContentUnavailableView {
                    Label("Aucun résultat", systemImage: "magnifyingglass")
                } description: {
                    Text("Essayez de modifier la recherche ou les filtres.")
                } actions: {
                    Button("Réinitialiser les filtres") {
                        filter.resetFilters()
                        filter.searchText = ""
                    }
                }
            } else {
                // No `List(selection:)` binding — its native circle can't be moved off the
                // leading edge (#161), so selection is homemade: the row's own tap either
                // toggles it or navigates, never both (#165).
                List(filteredSets, id: \.setNum) { cached in
                    Button {
                        if isSelecting {
                            toggleSelection(cached.setNum)
                        } else {
                            lookupViewModel.lookupSetNumber(cached.setNum, source: .listReopen)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SetRowView(
                                setNum: cached.setNum,
                                name: cached.name,
                                setImgUrl: cached.setImgUrl,
                                resolvedPrice: resolvedPrice(for: cached),
                                priceLabel: priceLabel(for: cached)
                            ) {
                                if cached.isInCollection {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.green)
                                }
                            }
                            if isSelecting {
                                RowSelectionIndicator(isSelected: selectedSetNums.contains(cached.setNum))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        // Hidden while selecting — the row's own tap is repurposed for selection
                        // (#165); a swipe shouldn't offer a second, unguarded way to mutate state.
                        if !isSelecting {
                            Button(role: .destructive) {
                                remove(cached)
                            } label: {
                                Label("Retirer", systemImage: "trash")
                            }
                        }
                    }
                    // Long-press shortcut for the same actions as the multi-select "Actions" menu
                    // below, applied to this single set (#172). Hidden while selecting — the two
                    // selection modes don't cohabit. Unlike the swipe action above, "Retirer de la
                    // liste cadeaux" here goes through the confirmation alert, matching the bulk
                    // mode's behavior as requested in #172.
                    .contextMenu {
                        if !isSelecting {
                            Button {
                                Task { await refreshPrices(for: [cached]) }
                            } label: {
                                Label("Actualiser les prix", systemImage: "arrow.clockwise")
                            }
                            Button {
                                pendingActionTargets = [cached]
                                showAddToListPicker = true
                            } label: {
                                Label("Ajouter à la collection", systemImage: "shippingbox")
                            }
                            Button(role: .destructive) {
                                pendingActionTargets = [cached]
                                showRemoveConfirmation = true
                            } label: {
                                Label("Retirer de la liste cadeaux", systemImage: "trash")
                            }
                        }
                    }
                }
                .contentMargins(.top, 0, for: .scrollContent)
            }
        }
        .searchable(text: $filter.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nom ou numéro de set")
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: filter.isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filtres")
                .accessibilityValue(filter.isFilterActive ? "Actifs" : "Inactifs")
            }
            // Pinned to the bottom bar rather than the top-trailing spot, matching Collection/
            // History (#141) — kept consistent across all three even though Wishlist has no
            // search bar of its own to fight with.
            if !cachedSets.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    if isSelecting {
                        Button(areAllFilteredSelected ? "Tout désélectionner" : "Tout sélectionner") {
                            toggleSelectAll()
                        }
                        .disabled(filteredSets.isEmpty)
                    }
                    Spacer()
                    if isSelecting {
                        Menu {
                            Button {
                                Task { await refreshPrices(for: selectedCachedSets) }
                            } label: {
                                Label("Actualiser les prix", systemImage: "arrow.clockwise")
                            }
                            Button {
                                pendingActionTargets = selectedCachedSets
                                showAddToListPicker = true
                            } label: {
                                Label("Ajouter à la collection", systemImage: "shippingbox")
                            }
                            // Not `role: .destructive` — SwiftUI previews a destructive Menu item
                            // across the List's selected rows the instant the Menu opens (a red
                            // flash on the selection background), not just on tap. The icon still
                            // renders in the app's red accent color either way.
                            Button {
                                pendingActionTargets = selectedCachedSets
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
                        withAnimation { isSelecting.toggle() }
                    } label: {
                        if isSelecting {
                            Text("Terminé")
                        } else {
                            // `square.and.pencil` (compose/edit) + "Actions" — right next to a
                            // Menu labelled "Actions (N)" once selecting, i.e. two adjacent
                            // "Actions" controls meaning different things (#143/#151).
                            Image(systemName: "checklist")
                        }
                    }
                    // A tap here used to clear the selection and hide the spinner while the bulk
                    // network loop kept running in the background, orphaning it (#151) — now
                    // blocked for the duration of that loop, same as the bulk Menu itself.
                    .disabled(isSelecting && isPerformingBulkAction)
                    .accessibilityLabel(isSelecting ? "Terminé" : "Sélectionner plusieurs sets")
                }
            }
        }
        .onChange(of: isSelecting) { _, newValue in
            if !newValue {
                selectedSetNums.removeAll()
            }
        }
        .sheet(isPresented: $showImportSheet) {
            BricksetWishlistImportSheet()
        }
        .sheet(isPresented: $showFilters) {
            SetFilterSheet(
                filter: filter,
                availableThemeIds: availableThemeIds,
                availableYears: availableYears,
                availableListNames: [],
                showsOwnedFilter: false,
                themeName: { ThemeNameStore.shared.displayName(forThemeId: $0) },
                excludedSortOptions: [.dateAdded]
            )
        }
        .sheet(isPresented: $showAddToListPicker) {
            ListPickerView(repository: rebrickableRepository) { listId, listName in
                Task { await addToCollection(pendingActionTargets, listId: listId, listName: listName) }
            }
        }
        .alert("Retirer de la liste cadeaux ?", isPresented: $showRemoveConfirmation) {
            Button("Retirer", role: .destructive) {
                Task { await removeFromWishlist(pendingActionTargets) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(setsCountSentence(
                pendingActionTargets.count,
                singular: "sera retiré de votre liste cadeaux.",
                plural: "seront retirés de votre liste cadeaux."
            ))
        }
        .task {
            await ThemeNameStore.shared.refreshIfNeeded()
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
                errorMessage = String(localized: "Liez votre compte Brickset dans Réglages pour utiliser la liste cadeaux.")
            } catch let error as APIError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = String(localized: "Une erreur est survenue")
            }
        }
    }
}
