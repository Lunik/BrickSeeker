import SwiftUI
import SwiftData

struct SetDetailView: View {
    @State private var viewModel: SetDetailViewModel
    @State private var showListPicker = false
    @State private var showRemoveConfirmation = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let onScanAgain: () -> Void

    init(legoSet: LegoSet, collectionStatus: CollectionStatus, onScanAgain: @escaping () -> Void) {
        _viewModel = State(initialValue: SetDetailViewModel(legoSet: legoSet, collectionStatus: collectionStatus))
        self.onScanAgain = onScanAgain
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    AsyncImage(url: URL(string: viewModel.legoSet.setImgUrl ?? "")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            Image(systemName: "shippingbox")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.secondary)
                                .padding(40)
                        }
                    }
                    .frame(height: 220)

                    VStack(spacing: 4) {
                        Text(viewModel.legoSet.setNum)
                            .font(.title2.bold())
                        Text(viewModel.legoSet.name)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                        Text("\(viewModel.legoSet.year) · \(viewModel.legoSet.numParts) pièces")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    statusBadge

                    if viewModel.isLoading {
                        ProgressView()
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Color(hex: "E3000B"))
                            .font(.footnote)
                    }

                    actionButtons

                    if let setUrl = viewModel.legoSet.setUrl, let url = URL(string: setUrl) {
                        Link("Voir sur Rebrickable", destination: url)
                            .font(.footnote)
                    }
                }
                .padding(16)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") {
                        dismiss()
                        onScanAgain()
                    }
                }
            }
            .sheet(isPresented: $showListPicker) {
                ListPickerView { listId, listName in
                    Task { await viewModel.addToList(listId: listId, listName: listName) }
                }
            }
            .alert("Retirer de la collection ?", isPresented: $showRemoveConfirmation) {
                Button("Retirer", role: .destructive) {
                    Task { await viewModel.removeFromCollection() }
                }
                Button("Annuler", role: .cancel) {}
            }
            .overlay(alignment: .bottom) {
                if let toast = viewModel.toastMessage {
                    Text(toast)
                        .padding(12)
                        .background(.black.opacity(0.8))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 24)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            viewModel.toastMessage = nil
                        }
                }
            }
        }
        .onChange(of: viewModel.collectionStatus) { _, _ in syncCache() }
        .onChange(of: viewModel.collectionListName) { _, _ in syncCache() }
    }

    private func syncCache() {
        let listId: Int?
        if case .inCollection(let userSet) = viewModel.collectionStatus {
            listId = userSet.listId
        } else {
            listId = nil
        }
        LocalRepository(modelContext: modelContext).cacheSet(
            viewModel.legoSet,
            isInCollection: viewModel.isInCollection,
            listId: listId,
            listName: viewModel.collectionListName
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.collectionStatus {
        case .inCollection:
            Label(
                viewModel.collectionListName.map { "Dans votre liste « \($0) »" } ?? "Dans votre collection",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .notInCollection:
            Label("Pas dans votre collection", systemImage: "xmark.circle.fill")
                .foregroundStyle(Color(hex: "E3000B"))
        case .unknown(let message):
            VStack(spacing: 8) {
                Label("Statut inconnu : \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Réessayer") {
                    Task { await viewModel.retryCollectionStatus() }
                }
                .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if viewModel.statusIsUnknown {
            EmptyView()
        } else if viewModel.isInCollection {
            Button("Retirer de la collection", role: .destructive) {
                showRemoveConfirmation = true
            }
        } else {
            Button("Ajouter à une liste") {
                showListPicker = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "E3000B"))
        }
    }
}
