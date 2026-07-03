import SwiftUI

/// On-demand "prix vu en magasin → verdict" sheet, opened from the floating button in
/// `SetDetailView` (issue #94) rather than auto-presented — see #12 for the verdict logic this
/// reuses and #94 for why the entry point had to become a deliberate tap instead of an
/// auto-opening prompt.
///
/// Nothing here triggers a network fetch: `storeAmount`/`quotes` are exactly what's already in
/// `SetDetailViewModel` at the time the sheet opens, so it appears instantly.
struct StorePriceCheckView: View {
    let setNum: String
    let setName: String
    let storeAmount: Double?
    let storeCurrency: String?
    let quotes: [PriceQuote]

    @State private var priceText = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var priceSeen: Decimal? {
        let normalised = priceText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalised), value > 0 else { return nil }
        return Decimal(value)
    }

    private var result: DealVerdictResult? {
        guard let priceSeen else { return nil }
        return DealVerdictCalculator.evaluate(
            priceSeen: priceSeen,
            storeAmount: storeAmount,
            storeCurrency: storeCurrency,
            quotes: quotes
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("0,00", text: $priceText)
                            .keyboardType(.decimalPad)
                            .focused($isInputFocused)
                            .multilineTextAlignment(.trailing)
                        Text("€")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("\(setNum) · \(setName)")
                } footer: {
                    Text("Renseigne le prix affiché en rayon pour comparer aux prix déjà connus.")
                }

                if let result {
                    Section {
                        Label(result.verdict.label, systemImage: "circle.fill")
                            .font(.headline)
                            .foregroundStyle(color(for: result.verdict))
                        ForEach(result.comparisons) { comparison in
                            HStack {
                                Text(comparison.label)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(comparison.percent > 0 ? "+" : "")\(comparison.percent)%")
                                    .foregroundStyle(comparison.percent < 0 ? .green : Color.brickDanger)
                            }
                            .font(.subheadline)
                        }
                    } header: {
                        Text("Verdict")
                    }
                } else if quotes.isEmpty && storeAmount == nil {
                    Section {
                        Text("Aucun prix de référence chargé pour ce set.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Prix vu en magasin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
            }
            .onAppear { isInputFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func color(for verdict: DealVerdict) -> Color {
        switch verdict {
        case .good: return .green
        case .fair: return .yellow
        case .bad: return Color.brickDanger
        }
    }
}
