import SwiftUI
import SwiftData

struct SetDetailView: View {
    @State private var viewModel: SetDetailViewModel
    @State private var showListPicker = false
    @State private var showRemoveConfirmation = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let onScanAgain: () -> Void
    private let reconcileOnAppear: Bool

    init(
        legoSet: LegoSet,
        collectionStatus: CollectionStatus,
        initialListName: String? = nil,
        initialStorePrice: StorePrice? = nil,
        initialStorePriceFetchedAt: Date? = nil,
        reconcileOnAppear: Bool = false,
        onScanAgain: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: SetDetailViewModel(
            legoSet: legoSet,
            collectionStatus: collectionStatus,
            initialListName: initialListName,
            initialStorePrice: initialStorePrice,
            initialStorePriceFetchedAt: initialStorePriceFetchedAt
        ))
        self.reconcileOnAppear = reconcileOnAppear
        self.onScanAgain = onScanAgain
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CachedRemoteImage(url: URL(string: viewModel.legoSet.setImgUrl ?? ""), refreshesLive: true) {
                        AnyView(
                            Image(systemName: "shippingbox")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.secondary)
                                .padding(40)
                        )
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

                    storePriceSection

                    priceSection

                    if viewModel.isLoading {
                        ProgressView()
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Color(hex: "E3000B"))
                            .font(.footnote)
                    }

                    actionButtons

                    HStack(spacing: 16) {
                        if let setUrl = viewModel.legoSet.setUrl, let url = URL(string: setUrl) {
                            Link("Voir sur Rebrickable", destination: url)
                                .font(.footnote)
                        }
                        if viewModel.storePrice?.amount != nil,
                           let url = LegoStoreRepository.storeUrl(setNum: viewModel.legoSet.setNum) {
                            Link("Voir sur lego.com", destination: url)
                                .font(.footnote)
                        }
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
        .onChange(of: viewModel.storePriceFetchedAt) { _, _ in syncStorePriceCache() }
        .task {
            if reconcileOnAppear {
                await viewModel.silentlyReconcileCollectionStatus()
            }
        }
        .task {
            await viewModel.loadStorePriceIfNeeded()
        }
        .task {
            let setNum = viewModel.legoSet.setNum
            viewModel.setCachedPrices(LocalRepository(modelContext: modelContext).cachedPrices(setNum: setNum))
            if viewModel.priceQuotes.isEmpty {
                await refreshPrices()
            }
        }
    }

    private func syncStorePriceCache() {
        guard let storePrice = viewModel.storePrice, viewModel.storePriceFetchedAt != nil else { return }
        LocalRepository(modelContext: modelContext).cacheStorePrice(setNum: viewModel.legoSet.setNum, price: storePrice)
    }

    private func refreshPrices() async {
        await viewModel.loadPrices()
        LocalRepository(modelContext: modelContext).cachePrices(viewModel.priceQuotes, setNum: viewModel.legoSet.setNum)
    }

    @ViewBuilder
    private var priceSection: some View {
        if !viewModel.priceQuotes.isEmpty || viewModel.pricesLoading {
            VStack(spacing: 8) {
                ForEach(PriceSource.allCases, id: \.self) { source in
                    if let quote = viewModel.priceQuotes.first(where: { $0.source == source }) {
                        priceRow(label: source.displayName, quote: quote)
                    }
                }

                if viewModel.pricesLoading {
                    ProgressView().padding(.vertical, 4)
                } else {
                    Button("Rafraîchir les prix") {
                        Task { await refreshPrices() }
                    }
                    .font(.footnote)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func priceRow(label: String, quote: PriceQuote) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let sourceURL = quote.sourceURL {
                Link(formattedAmount(quote), destination: sourceURL)
            } else {
                Text(formattedAmount(quote))
            }
        }
        .font(.subheadline)
    }

    private func formattedAmount(_ quote: PriceQuote) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = quote.currency
        return formatter.string(from: quote.amount as NSDecimalNumber) ?? "\(quote.amount) \(quote.currency)"
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
    private var storePriceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prix officiel lego.com")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    Task { await viewModel.refreshStorePrice() }
                } label: {
                    if viewModel.isLoadingStorePrice {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoadingStorePrice)
            }

            if let amount = viewModel.storePrice?.amount {
                Text(amount, format: .currency(code: viewModel.storePrice?.currency ?? "EUR"))
                    .font(.title3.bold())
            } else if viewModel.isLoadingStorePrice {
                Text("Vérification du prix…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let errorMessage = viewModel.storePriceErrorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if viewModel.storePriceFetchedAt != nil {
                Text("Retiré de la vente / prix non disponible")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Pas encore vérifié")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
