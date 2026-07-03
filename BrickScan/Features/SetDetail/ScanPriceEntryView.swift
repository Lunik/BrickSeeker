import SwiftUI

/// "Quel prix as-tu vu ?" — the in-aisle price reading captured right after a camera scan
/// resolves, feeding the "meilleur prix vu ici" highlight (issue #46). A dedicated sheet rather
/// than an alert `TextField`: it focuses the field on appear (keyboard already up, like
/// `ManualSetEntryView`), which an alert can't, is far more robust than presenting an alert over a
/// sheet that's still animating in, and leaves room for a richer in-store entry later (#12).
struct ScanPriceEntryView: View {
    let setNum: String
    let setName: String
    @Binding var priceText: String
    let onSave: () -> Void

    @FocusState private var isInputFocused: Bool
    @Environment(\.dismiss) private var dismiss

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
                    Text("Renseigne le prix affiché en magasin pour ce scan — il sert à repérer le meilleur prix vu, et sur quel lieu.")
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
                        onSave()
                        dismiss()
                    }
                }
            }
            .onAppear { isInputFocused = true }
        }
        .presentationDetents([.medium])
    }
}
