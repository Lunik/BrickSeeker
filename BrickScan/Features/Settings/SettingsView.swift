import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var showPrivacyDetail = false
    @State private var showSavedConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Rebrickable API Key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API Key Rebrickable")
                } footer: {
                    Text("Génère ta clé sur rebrickable.com/profile, dans la section API Key.")
                }

                if showSavedConfirmation {
                    Text("Clé enregistrée")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }

                Section {
                    PrivacyNoticeView()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    Button("Confidentialité & données") {
                        showPrivacyDetail = true
                    }
                }
            }
            .navigationTitle("Paramètres")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Enregistrer") {
                        viewModel.save()
                        showSavedConfirmation = true
                    }
                    .disabled(viewModel.apiKey.isEmpty)
                }
            }
            .sheet(isPresented: $showPrivacyDetail) {
                PrivacyDetailView()
            }
        }
    }
}
