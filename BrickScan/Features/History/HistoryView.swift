import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \CachedSet.lastScannedAt, order: .reverse) private var cachedSets: [CachedSet]
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if cachedSets.isEmpty {
                    ContentUnavailableView(
                        "Aucun set scanné",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Les sets que tu scannes apparaîtront ici.")
                    )
                } else {
                    List(cachedSets) { cached in
                        Button {
                            onSelect(cached.setNum)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: cached.setImgUrl ?? "")) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFit()
                                    default:
                                        Image(systemName: "shippingbox")
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

                                if cached.isInCollection {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            .foregroundStyle(.primary)
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
    }
}
