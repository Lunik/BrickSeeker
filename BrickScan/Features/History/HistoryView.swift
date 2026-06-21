import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \CachedSet.lastScannedAt, order: .reverse) private var cachedSets: [CachedSet]
    @Query private var pendingBoxCodes: [CachedUnresolvedBoxCode]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let onSelect: (String) -> Void
    var repository: RebrickableRepositoryProtocol = RebrickableRepository()

    var body: some View {
        NavigationStack {
            Group {
                if cachedSets.isEmpty && pendingBoxCodes.isEmpty {
                    ContentUnavailableView(
                        "Aucun set scanné",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Les sets que tu scannes apparaîtront ici.")
                    )
                } else {
                    List {
                        ForEach(cachedSets) { cached in
                            Button {
                                onSelect(cached.setNum)
                                dismiss()
                            } label: {
                                row(for: cached)
                            }
                        }

                        if !pendingBoxCodes.isEmpty {
                            Section {
                                ForEach(pendingBoxCodes) { pending in
                                    pendingRow(for: pending)
                                }
                            } header: {
                                Text("Figurines non identifiées")
                            } footer: {
                                Text("Ces codes seront reconnus automatiquement dès qu'une mise à jour de l'app couvrira cette série.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Historique")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .task {
            await LocalRepository(modelContext: modelContext).resolvePendingMinifigBoxCodes(repository: repository)
        }
    }

    private func row(for cached: CachedSet) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: cached.setImgUrl ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    Image(systemName: cached.isMinifig ? "person.fill" : "shippingbox")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(cached.setNum)
                    .font(.headline)
                Text(cached.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if cached.isMinifig {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
            }
            if cached.isInCollection {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .foregroundStyle(.primary)
    }

    private func pendingRow(for pending: CachedUnresolvedBoxCode) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.diamond.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.orange)
                .padding(12)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(pending.boxCode)
                    .font(.headline)
                Text("Code non reconnu")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .foregroundStyle(.secondary)
    }
}
