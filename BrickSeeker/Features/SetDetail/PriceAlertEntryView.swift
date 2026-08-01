import SwiftUI
import SwiftData

/// "Préviens-moi si ce set descend sous X" (#229) — creating or editing one set's price alert.
///
/// Same interaction as `ScanPriceEntryView` ("an amount, **or** a −X % off a reference"), and
/// deliberately the same layout: a segmented mode picker, one focused decimal field, and a footer
/// naming the reference the percentage was applied to. It isn't a reuse of that view because the
/// two capture different things — that one saves a price, this one saves a threshold plus a
/// condition, and shows what the background refresher can actually watch — but the shape a user
/// already knows is kept identical on purpose.
///
/// **The percentage's reference** is the question #229 left open. It's the lego.com retail price:
/// stable, public, and the one number that doesn't move under the user's feet. When it's unknown
/// (a minifig, a set the store dropped) it falls back to the set's current resolved value for the
/// chosen condition. Either way it's **frozen at creation** and the resulting amount is shown live
/// under the field ("−20 % ⇒ alerte sous 47,99 €"), so there is nothing left to guess about.
struct PriceAlertEntryView: View {
    private enum EntryMode: Hashable {
        case amount
        case percentage
    }

    let setNum: String
    let setName: String
    let setImgUrl: String?
    /// lego.com retail price, when known — the preferred percentage reference.
    let storePriceEUR: Double?
    let quotes: [PriceQuote]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var condition: ListCondition = .newSet
    @State private var mode: EntryMode = .amount
    @State private var amountText = ""
    @State private var percentText = ""
    @State private var isAuthorized = true
    @State private var detent: PresentationDetent = .large
    @FocusState private var isInputFocused: Bool

    /// The alert already stored for the *currently selected* condition, if any — switching the
    /// picker re-reads it, so the sheet always edits the alert the user is looking at.
    private var existingAlert: PriceAlert? {
        LocalRepository(modelContext: modelContext).priceAlert(setNum: setNum, condition: condition)
    }

    /// The amount a `−X %` is taken off, and the name of where it came from. Same rule (and same
    /// reason for naming the source) as `ScanPriceEntryView.discountReference`: applying a
    /// percentage to a marketplace quote instead of the retail price is an approximation, and the
    /// footer has to say which one it just did.
    private var reference: (amountEUR: Double, sourceName: String)? {
        if condition == .newSet, let storePriceEUR {
            return (storePriceEUR, String(localized: "lego.com (officiel)"))
        }
        guard let amount = PriceAlertEvaluator.watchedPrice(
            condition: condition,
            storePriceEUR: condition == .newSet ? storePriceEUR : nil,
            quotes: quotes
        ) else { return nil }
        let source = quotes.first { ($0.amount as NSDecimalNumber).doubleValue == amount }?.source
        return (amount, source?.displayName ?? String(localized: "valeur actuelle"))
    }

    private var calculatedThreshold: Double? {
        guard let reference,
              let percent = Double(percentText.replacingOccurrences(of: ",", with: ".")),
              percent > 0, percent <= 100
        else { return nil }
        let raw = reference.amountEUR * (1 - percent / 100)
        return (raw * 100).rounded() / 100
    }

    private var typedAmount: Double? {
        let normalised = amountText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalised), value > 0 else { return nil }
        return value
    }

    private var canSave: Bool {
        mode == .amount ? typedAmount != nil : calculatedThreshold != nil
    }

    /// Today's price for the selected condition, shown next to the field so a threshold can be
    /// typed against something rather than from memory.
    private var currentPrice: Double? {
        PriceAlertEvaluator.watchedPrice(
            condition: condition,
            storePriceEUR: condition == .newSet ? storePriceEUR : nil,
            quotes: quotes
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Condition", selection: $condition) {
                        ForEach(ListCondition.allCases) { condition in
                            Text(condition.displayName).tag(condition)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    // #230's structural limit, stated where it actually matters. Without this the
                    // feature reads as capricious: a neuf alert genuinely is served less often than
                    // an occasion one when the app isn't opened.
                    Text(condition == .used
                         ? "Le prix occasion vient de l'API BrickLink, la seule source que l'app peut interroger en tâche de fond : cette alerte est surveillée même sans ouvrir l'app."
                         : "Le prix neuf vient de lego.com, Amazon/Cdiscount puis BrickLink. Seul BrickLink peut être interrogé en tâche de fond : les autres sources ne sont actualisées qu'à l'ouverture de l'app.")
                    // Creating an alert is the *only* thing that puts a set under surveillance
                    // (the gift list no longer is) — worth stating here, where the user is doing it.
                    Text("Créer une alerte est ce qui met ce set sous surveillance : lui seul sera réactualisé en tâche de fond.")
                }

                Section {
                    Picker("Type de seuil", selection: $mode) {
                        Text("Montant").tag(EntryMode.amount)
                        Text("Réduction (%)").tag(EntryMode.percentage)
                    }
                    .pickerStyle(.segmented)
                    .disabled(reference == nil)

                    if mode == .percentage, reference != nil {
                        HStack {
                            TextField("0", text: $percentText)
                                .keyboardType(.decimalPad)
                                .focused($isInputFocused)
                                .multilineTextAlignment(.trailing)
                            Text("%")
                                .foregroundStyle(.secondary)
                        }
                        if let calculatedThreshold {
                            HStack {
                                Text("Alerte sous")
                                Spacer()
                                Text(Decimal(calculatedThreshold).formatted(.currency(code: "EUR")))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            TextField("0,00", text: $amountText)
                                .keyboardType(.decimalPad)
                                .focused($isInputFocused)
                                .multilineTextAlignment(.trailing)
                            Text("€")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let currentPrice {
                        HStack {
                            Text("Prix actuel")
                            Spacer()
                            Text(Decimal(currentPrice).formatted(.currency(code: "EUR")))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(setNum.baseSetNum) · \(setName)")
                } footer: {
                    if mode == .percentage, let reference {
                        Text("Le pourcentage est appliqué au prix « \(reference.sourceName) » (\(Decimal(reference.amountEUR).formatted(.currency(code: "EUR")))), figé à la création de l'alerte.")
                    } else if reference == nil {
                        Text("Aucun prix de référence connu pour cette condition : seul un montant peut être saisi.")
                    } else {
                        Text("Vous serez prévenu dès que le prix passe sous ce montant, une seule fois par franchissement.")
                    }
                }

                if !isAuthorized {
                    Section {
                        Label("Les notifications sont désactivées pour BrickSeeker — l'alerte sera enregistrée mais ne pourra pas vous prévenir.", systemImage: "bell.slash")
                            .font(.footnote)
                            .foregroundStyle(Color.brickDanger)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Ouvrir les réglages iOS", destination: url)
                                .font(.footnote)
                        }
                    }
                }

                if existingAlert != nil {
                    Section {
                        Button("Supprimer l'alerte", role: .destructive) {
                            deleteAlert()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Alerte de prix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Enregistrer") {
                        saveAlert()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                loadExistingAlert()
                isInputFocused = true
            }
            .onChange(of: condition) { _, _ in loadExistingAlert() }
            .task {
                // Asked here rather than at app launch: the permission prompt should come with the
                // action that needs it. Declining leaves the alert saveable, with the banner above
                // saying what that costs.
                await PriceUpdateNotifier.requestAuthorizationIfNeeded()
                isAuthorized = await PriceUpdateNotifier.isAuthorized()
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    /// Repopulates the fields from the alert stored for the selected condition — on appear, and
    /// again whenever the condition picker moves, since the two conditions hold two distinct alerts.
    private func loadExistingAlert() {
        guard let existing = existingAlert else {
            amountText = ""
            percentText = ""
            mode = .amount
            return
        }
        if let percent = existing.discountPercent {
            mode = reference == nil ? .amount : .percentage
            percentText = trimmedNumber(percent)
            amountText = existing.effectiveThresholdEUR.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
        } else {
            mode = .amount
            percentText = ""
            amountText = existing.thresholdEUR.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
        }
    }

    private func trimmedNumber(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private func saveAlert() {
        let repository = LocalRepository(modelContext: modelContext)
        let percent = Double(percentText.replacingOccurrences(of: ",", with: "."))
        repository.upsertPriceAlert(
            setNum: setNum,
            condition: condition,
            setName: setName,
            setImgUrl: setImgUrl,
            thresholdEUR: mode == .amount ? typedAmount : nil,
            discountPercent: mode == .percentage ? percent : nil,
            referencePriceEUR: mode == .percentage ? reference?.amountEUR : nil,
            referenceSourceName: mode == .percentage ? reference?.sourceName : nil
        )
        // A brand-new alert makes this set watched (#230); if it's the first one, there may be no
        // pending wake-up request at all yet.
        BackgroundPriceRefresher.shared.scheduleIfNeeded(modelContext: modelContext)
    }

    private func deleteAlert() {
        guard let existing = existingAlert else { return }
        let repository = LocalRepository(modelContext: modelContext)
        repository.deletePriceAlert(existing)
        BackgroundPriceRefresher.shared.scheduleIfNeeded(modelContext: modelContext)
    }
}
