import SwiftUI
import SafariServices

struct PrivacyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showSafari = false
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Ce qui est stocké", systemImage: "internaldrive")
                        .font(.headline)
                    Text("API Key Rebrickable : dans le Keychain iOS")
                    Text("Sets scannés récemment : dans la base SwiftData locale, sur l'appareil uniquement")
                }

                Section {
                    Label("Ce qui n'est jamais stocké", systemImage: "xmark.shield")
                        .font(.headline)
                    Text("Aucune donnée n'est envoyée à un serveur tiers autre que Rebrickable")
                }

                Section {
                    Label("Vous gardez le contrôle", systemImage: "hand.raised")
                        .font(.headline)
                    Button("Gérer votre API Key sur Rebrickable") {
                        showSafari = true
                    }
                    Button("Réinitialiser BrickScan", role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }
            .navigationTitle("Comment BrickScan protège vos données")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
            .sheet(isPresented: $showSafari) {
                SafariView(url: URL(string: "https://rebrickable.com/settings/")!)
            }
            .confirmationDialog(
                "Réinitialiser BrickScan ?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Réinitialiser", role: .destructive) {
                    reset()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Supprime l'API Key enregistrée et l'historique des sets scannés.")
            }
        }
    }

    private func reset() {
        KeychainService.shared.clearAll()
        NotificationCenter.default.post(name: .didReset, object: nil)
        dismiss()
    }
}

extension Notification.Name {
    static let didReset = Notification.Name("BrickScan.didReset")
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
