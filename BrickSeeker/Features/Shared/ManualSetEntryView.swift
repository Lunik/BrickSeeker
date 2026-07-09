import SwiftUI

/// Manual set-number entry sheet, reused by `HomeView` (satellite keyboard button) and
/// `ScannerView` (fallback when the camera is refused/blocked, see #145). Moved out of
/// `HomeView.swift` (was `private`) so both can present it without duplicating the view.
struct ManualSetEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var setNum = ""
    @FocusState private var isInputFocused: Bool
    let lookupViewModel: ScannerViewModel
    let onSubmit: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Numéro de set, ex. 42143", text: $setNum)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isInputFocused)
                    .onSubmit(submit)
            }
            .navigationTitle("Ajouter un set")
            .onAppear { isInputFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rechercher", action: submit)
                        .disabled(setNum.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            // Nested rather than a sibling sheet on the presenter — when a typed set resolves
            // straight from cache, the result is ready in the same frame this view dismisses,
            // and SwiftUI can't cleanly close one sheet while opening another from the same
            // parent at once (see the presenter's gated lookupResultSheets). Nesting here, like
            // HistoryView already does, avoids that race entirely. Closing the result reveals
            // this view again, not the presenter behind it.
            .lookupResultSheets(for: lookupViewModel)
        }
    }

    private func submit() {
        let trimmed = setNum.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}
