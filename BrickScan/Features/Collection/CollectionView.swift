import SwiftUI
import SwiftData

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CollectionViewModel?

    var body: some View {
        List(viewModel?.cachedSets ?? [], id: \.setNum) { cached in
            VStack(alignment: .leading) {
                Text(cached.setNum).font(.headline)
                Text(cached.name).font(.subheadline)
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
