import SwiftUI

/// End-of-session screen for "mode lot" — lists every set scanned this session, best deal first
/// (largest discount vs lego.com), reusing the same thumbnail/price-row style as `HistoryView`.
/// Tapping a row opens the normal `SetDetailView` via `lookupViewModel.lookupSetForDetail`, the
/// same entry point `HistoryView` uses for `lookupViewModel.lookupSetNumber`.
struct BatchSessionSummaryView: View {
    let session: BatchScanSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var rebrickableRepository: RebrickableRepositoryProtocol = RebrickableRepository()
    var bricksetRepository: BricksetRepositoryProtocol = BricksetRepository()
    let onSelect: (String) -> Void
    let onClearSession: () -> Void

    @State private var isSelecting = false
    @State private var selectedSetNums: Set<String> = []
    @State private var isPerformingBulkAction = false
    @State private var selectionActionError: String?
    @State private var showAddToListPicker = false

    private var areAllSelected: Bool {
        !session.items.isEmpty && session.items.allSatisfy { selectedSetNums.contains($0.id) }
    }

    private func toggleSelection(_ setNum: String) {
        if selectedSetNums.contains(setNum) {
            selectedSetNums.remove(setNum)
        } else {
            selectedSetNums.insert(setNum)
        }
    }

    private func toggleSelectAll() {
        if areAllSelected {
            selectedSetNums.subtract(session.items.map(\.id))
        } else {
            selectedSetNums.formUnion(session.items.map(\.id))
        }
    }

    /// Adds every selected set to `listId` on Rebrickable — same mechanic as `HistoryView
    /// .addSelectedToCollection(listId:listName:)` (#167).
    private func addSelectedToList(listId: Int, listName: String) async {
        selectionActionError = nil
        let selected = session.items.filter { selectedSetNums.contains($0.id) }
        guard !selected.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for item in selected {
            do {
                try await rebrickableRepository.addSetToList(setNum: item.id, listId: listId)
                localRepository.setCollectionStatus(setNum: item.id, isInCollection: true, listId: listId, listName: listName)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = String(localized: "\(failureCount) set(s) n'ont pas pu être ajoutés à la liste. Vérifiez votre connexion.")
        } else {
            isSelecting = false
        }
    }

    /// Adds every selected set to the Brickset wishlist — same mechanic as `SetDetailViewModel
    /// .toggleWishlist()`'s add branch, looped over the selection (#167).
    private func addSelectedToWishlist() async {
        selectionActionError = nil
        guard NetworkMonitor.shared.isConnected else {
            selectionActionError = UserMessage.offlineStatus
            return
        }
        let selected = session.items.filter { selectedSetNums.contains($0.id) }
        guard !selected.isEmpty else { return }

        isPerformingBulkAction = true
        defer { isPerformingBulkAction = false }

        let localRepository = LocalRepository(modelContext: modelContext)
        var failureCount = 0
        for item in selected {
            do {
                try await bricksetRepository.addToWishlist(setNum: item.id)
                localRepository.setWishlistStatus(setNum: item.id, isInWishlist: true)
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            selectionActionError = String(localized: "\(failureCount) set(s) n'ont pas pu être ajoutés à la liste cadeaux. Vérifiez votre connexion.")
        } else {
            isSelecting = false
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.items.isEmpty {
                    ContentUnavailableView(
                        "Aucun set scanné",
                        systemImage: "square.stack.3d.up",
                        description: Text("Scanne plusieurs sets en mode lot pour les comparer ici.")
                    )
                } else {
                    // No `List(selection:)` binding — its native circle can't be moved off the
                    // leading edge (#161), so selection is homemade: the row's own tap either
                    // toggles it or opens the set's detail, never both (#165).
                    List(session.sortedByDeal) { item in
                        Button {
                            if isSelecting {
                                toggleSelection(item.id)
                            } else {
                                onSelect(item.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                row(for: item)
                                if isSelecting {
                                    RowSelectionIndicator(isSelected: selectedSetNums.contains(item.id))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Session de scan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !session.items.isEmpty {
                        Button("Vider", role: .destructive) {
                            onClearSession()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
                if !session.items.isEmpty {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if isSelecting {
                            Button(areAllSelected ? "Tout désélectionner" : "Tout sélectionner") {
                                toggleSelectAll()
                            }
                        }
                        Spacer()
                        if isSelecting {
                            Menu {
                                Button {
                                    showAddToListPicker = true
                                } label: {
                                    Label("Ajouter à une liste", systemImage: "shippingbox")
                                }
                                Button {
                                    Task { await addSelectedToWishlist() }
                                } label: {
                                    Label("Ajouter à la liste cadeau", systemImage: "heart")
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
                                Image(systemName: "square.and.pencil")
                            }
                        }
                        .accessibilityLabel(isSelecting ? "Terminé" : "Actions")
                    }
                }
            }
            .onChange(of: isSelecting) { _, newValue in
                if !newValue {
                    selectedSetNums.removeAll()
                }
            }
            .sheet(isPresented: $showAddToListPicker) {
                ListPickerView(repository: rebrickableRepository) { listId, listName in
                    Task { await addSelectedToList(listId: listId, listName: listName) }
                }
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
    }

    private func row(for item: BatchScanItem) -> some View {
        HStack(spacing: 14) {
            SetThumbnailView(imageUrl: item.legoSet.setImgUrl)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.legoSet.setNum.baseSetNum)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(item.legoSet.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let amount = item.storePrice?.amount {
                    Text(amount, format: .currency(code: item.storePrice?.currency ?? "EUR"))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                } else if item.isLoadingPrice {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Prix indisponible")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let dealPercent = item.dealPercent {
                    // Green/red alone used to be the only signal for "good deal" vs "not" (#143)
                    // — an arrow adds a shape-based channel next to the sign already in the text.
                    Label {
                        Text("\(dealPercent > 0 ? "+" : "")\(dealPercent)%")
                    } icon: {
                        Image(systemName: dealPercent < 0 ? "arrow.down.right" : "arrow.up.right")
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(dealPercent < 0 ? .green : .red)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
