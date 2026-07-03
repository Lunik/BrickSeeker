import SwiftUI

/// "Quel prix as-tu vu ?" — the in-aisle price reading captured right after a camera scan
/// resolves, feeding the "meilleur prix vu ici" highlight (issue #46). Never auto-presented
/// (issue #94): opened only from the floating button on `SetDetailView`, so it doesn't compete
/// with reading the scan result. A dedicated sheet rather than an alert `TextField`: it focuses
/// the field on appear (keyboard already up, like `ManualSetEntryView`), which an alert can't,
/// and is far more robust than presenting an alert over a sheet that's still animating in.
///
/// Some shelf tags only show a `-X%` discount instead of a recalculated price — entering that
/// requires the user to do mental maths first, defeating the point of an instant verdict (#89).
/// When the lego.com price is known (`referencePriceEUR`), a "Réduction (%)" mode is offered:
/// the equivalent price is computed here and handed to `onSave` exactly like a directly-typed
/// price, so downstream storage/verdict logic stays untouched.
///
/// Below the input, a live 🟢🟡🔴 verdict (`DealVerdictCalculator`, issue #12) compares the typed
/// price against the lego.com price and the scraped `PriceQuote`s already loaded by
/// `SetDetailViewModel` — no new scrape triggered from this sheet.
struct ScanPriceEntryView: View {
    private enum EntryMode: Hashable {
        case price
        case percentage
    }

    let setNum: String
    let setName: String
    let referencePriceEUR: Double?
    let referenceCurrency: String
    let quotes: [PriceQuote]
    @Binding var priceText: String
    let onSave: () -> Void

    @State private var mode: EntryMode = .price
    @State private var percentText = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    /// The price computed from `referencePriceEUR` and the typed percentage, rounded to the
    /// nearest cent like the currency display elsewhere in `SetDetailView`.
    private var calculatedPrice: Double? {
        guard let referencePriceEUR,
              let percent = Double(percentText.replacingOccurrences(of: ",", with: ".")),
              percent >= 0, percent <= 100
        else { return nil }
        let raw = referencePriceEUR * (1 - percent / 100)
        return (raw * 100).rounded() / 100
    }

    /// The price to feed the verdict with — the typed price, or the calculated one while in
    /// percentage mode.
    private var priceForVerdict: Decimal? {
        if mode == .percentage {
            return calculatedPrice.map { Decimal($0) }
        }
        let normalised = priceText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalised), value > 0 else { return nil }
        return Decimal(value)
    }

    private var verdictResult: DealVerdictResult? {
        guard let priceForVerdict else { return nil }
        return DealVerdictCalculator.evaluate(
            priceSeen: priceForVerdict,
            storeAmount: referencePriceEUR,
            storeCurrency: referenceCurrency,
            quotes: quotes,
            currency: referenceCurrency
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if referencePriceEUR != nil {
                    Section {
                        Picker("Mode de saisie", selection: $mode) {
                            Text("Prix").tag(EntryMode.price)
                            Text("Réduction (%)").tag(EntryMode.percentage)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    if mode == .percentage, referencePriceEUR != nil {
                        HStack {
                            TextField("0", text: $percentText)
                                .keyboardType(.decimalPad)
                                .focused($isInputFocused)
                                .multilineTextAlignment(.trailing)
                            Text("%")
                                .foregroundStyle(.secondary)
                        }
                        if let calculatedPrice {
                            HStack {
                                Text("Prix calculé")
                                Spacer()
                                Text(Decimal(calculatedPrice).formatted(.currency(code: "EUR")))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            TextField("0,00", text: $priceText)
                                .keyboardType(.decimalPad)
                                .focused($isInputFocused)
                                .multilineTextAlignment(.trailing)
                            Text("€")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(setNum) · \(setName)")
                } footer: {
                    if mode == .percentage, referencePriceEUR != nil {
                        Text("Le pourcentage est appliqué au prix lego.com déjà connu pour calculer le prix final.")
                    } else {
                        Text("Renseigne le prix affiché en magasin pour ce scan — il sert à repérer le meilleur prix vu, et sur quel lieu.")
                    }
                }

                if let verdictResult {
                    Section {
                        Text("\(verdictResult.verdict.emoji) \(verdictResult.verdict.label)")
                            .font(.headline)
                        ForEach(verdictResult.comparisons) { comparison in
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
                }
            }
            .navigationTitle("Quel prix as-tu vu ?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Passer") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Enregistrer") {
                        if mode == .percentage, let calculatedPrice {
                            priceText = String(format: "%.2f", calculatedPrice).replacingOccurrences(of: ".", with: ",")
                        }
                        onSave()
                        dismiss()
                    }
                    .disabled(mode == .percentage && calculatedPrice == nil)
                }
            }
            .onAppear { isInputFocused = true }
        }
        .presentationDetents([.medium])
    }
}
