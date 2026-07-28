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
///
/// The same sheet also captures the **paid price** of a set already owned (`Purpose.paidPrice`),
/// which is the reference the header's valuation card measures growth against. It's the identical
/// interaction ("an amount, or a -X% off a reference"), so it reuses this view rather than forking
/// a near-copy; only the wording and the verdict differ.
struct ScanPriceEntryView: View {
    private enum EntryMode: Hashable {
        case price
        case percentage
    }

    /// Which number this sheet is capturing. The layout is identical — the same "type an amount, or
    /// a -X% off a reference" problem — but the wording and the verdict differ:
    /// - `.scanSeen`: a shelf price on a set you don't own yet, judged by the 🟢🟡🔴 verdict.
    /// - `.paidPrice`: what you actually paid for a set you own. No verdict here: the header's
    ///   valuation card already answers "was that a good price?" against this very number, so
    ///   showing a verdict too would just restate the same arithmetic twice.
    enum Purpose {
        case scanSeen
        case paidPrice
    }

    let setNum: String
    let setName: String
    let referencePriceEUR: Double?
    let referenceCurrency: String
    let quotes: [PriceQuote]
    @Binding var priceText: String
    var purpose: Purpose = .scanSeen
    let onSave: () -> Void

    @State private var mode: EntryMode = .price
    @State private var percentText = ""
    /// Starts compact; forced to `.large` the moment a verdict appears so the 🟢🟡🔴 section — the
    /// whole point of this sheet — can't end up below the fold under the keyboard (issue #157).
    /// Only ever grows, never auto-shrinks, so it doesn't fight a manual drag back down afterward.
    @State private var detent: PresentationDetent = .medium
    @FocusState private var isInputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    /// The reference a `-X%` is applied to. `referencePriceEUR` is the lego.com retail price, which
    /// is absent for every minifig and every set the store no longer carries — that used to kill
    /// percentage mode entirely on exactly the items most likely to be discounted (issue #210), so
    /// it falls back to the same new-price chain the rest of the app uses.
    private var discountReferenceEUR: Double? {
        referencePriceEUR ?? resolveNewPrice(storePriceEUR: nil, quotes: quotes)
    }

    /// The price computed from `discountReferenceEUR` and the typed percentage, rounded to the
    /// nearest cent like the currency display elsewhere in `SetDetailView`.
    private var calculatedPrice: Double? {
        guard let referencePriceEUR = discountReferenceEUR,
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
                if discountReferenceEUR != nil {
                    Section {
                        Picker("Mode de saisie", selection: $mode) {
                            Text("Prix").tag(EntryMode.price)
                            Text("Réduction (%)").tag(EntryMode.percentage)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    if mode == .percentage, discountReferenceEUR != nil {
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
                    Text("\(setNum.baseSetNum) · \(setName)")
                } footer: {
                    if mode == .percentage, let reference = discountReferenceEUR {
                        Text("Le pourcentage est appliqué au prix de référence connu (\(Decimal(reference).formatted(.currency(code: referenceCurrency)))) pour calculer le prix final.")
                    } else if purpose == .paidPrice {
                        Text("Renseigne ce que tu as réellement payé ce set — il sert de référence pour calculer son évolution de valeur.")
                    } else {
                        Text("Renseigne le prix affiché en magasin pour ce scan — il sert à repérer le meilleur prix vu, et sur quel lieu.")
                    }
                }

                if purpose == .scanSeen, let verdictResult {
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
            .navigationTitle(purpose == .paidPrice ? "Prix payé" : "Quel prix as-tu vu ?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(purpose == .paidPrice ? "Annuler" : "Passer") { dismiss() }
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
            // Watches the verdict's nil-ness (always `Equatable`, unlike `DealVerdictResult`
            // itself) rather than `priceForVerdict` — that would also re-fire on every keystroke
            // once a verdict already exists, and would wrongly expand even when there's a typed
            // price but zero reference data to compare it against (no Verdict section to show).
            .onChange(of: verdictResult != nil) { _, hasVerdict in
                if hasVerdict, purpose == .scanSeen { detent = .large }
            }
        }
        // The app's other multi-detent sheets (`SetFilterSheet`/`MinifigFilterSheet`) leave the
        // detent entirely to the user; this is deliberately the first sheet that drives it
        // programmatically, to guarantee the verdict's visibility rather than merely allow it.
        .presentationDetents([.medium, .large], selection: $detent)
    }
}
