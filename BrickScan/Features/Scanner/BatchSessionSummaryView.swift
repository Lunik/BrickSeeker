import SwiftUI

/// End-of-session screen for "mode lot" — lists every set scanned this session, best deal first
/// (largest discount vs lego.com), reusing the same thumbnail/price-row style as `HistoryView`.
/// Tapping a row opens the normal `SetDetailView` via `lookupViewModel.lookupSetForDetail`, the
/// same entry point `HistoryView` uses for `lookupViewModel.lookupSetNumber`.
struct BatchSessionSummaryView: View {
    let session: BatchScanSession
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void
    let onClearSession: () -> Void

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
                    List(session.sortedByDeal) { item in
                        Button {
                            onSelect(item.id)
                        } label: {
                            row(for: item)
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
            }
        }
    }

    private func row(for item: BatchScanItem) -> some View {
        HStack(spacing: 14) {
            SetThumbnailView(imageUrl: item.legoSet.setImgUrl)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.legoSet.setNum)
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
                    Text("\(dealPercent > 0 ? "+" : "")\(dealPercent)%")
                        .font(.caption2.bold())
                        .foregroundStyle(dealPercent < 0 ? .green : .red)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
