import SwiftUI
import SwiftData

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CollectionViewModel?
    let lookupViewModel: ScannerViewModel

    var body: some View {
        Group {
            if let cachedSets = viewModel?.cachedSets, !cachedSets.isEmpty {
                List(cachedSets, id: \.setNum) { cached in
                    Button {
                        lookupViewModel.lookupSetNumber(cached.setNum)
                    } label: {
                        HStack(spacing: 14) {
                            SetThumbnailView(imageUrl: cached.setImgUrl)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(cached.setNum).font(.headline)
                                Text(cached.name).font(.subheadline).foregroundStyle(.secondary)
                                if let listName = cached.currentListName {
                                    Text(listName).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ContentUnavailableView(
                    "Aucun set possédé",
                    systemImage: "shippingbox",
                    description: Text("Liez votre compte Rebrickable et synchronisez depuis l'accueil.")
                )
            }
        }
        .navigationTitle("Ma collection")
        .onAppear {
            if viewModel == nil {
                viewModel = CollectionViewModel(localRepository: LocalRepository(modelContext: modelContext))
            }
            viewModel?.load()
        }
    }
}
