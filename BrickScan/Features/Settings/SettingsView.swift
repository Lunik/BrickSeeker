import SwiftUI
import UIKit

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var showPrivacyDetail = false
    @State private var isAPIKeyVisible = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if isAPIKeyVisible {
                                TextField("Rebrickable API Key", text: $viewModel.apiKey)
                            } else {
                                SecureField("Rebrickable API Key", text: $viewModel.apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)

                        Button {
                            isAPIKeyVisible.toggle()
                        } label: {
                            Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button {
                            if let pasted = UIPasteboard.general.string {
                                viewModel.apiKey = pasted
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("API Key Rebrickable")
                } footer: {
                    Text("Génère ta clé sur rebrickable.com/profile, dans la section API Key.")
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
                        dismiss()
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
