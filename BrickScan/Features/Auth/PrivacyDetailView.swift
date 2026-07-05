import SwiftUI
import SafariServices

struct PrivacyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showSafari = false
    @State private var showBricksetSafari = false
    @State private var showPrivacyPolicy = false
    @State private var showResetConfirmation = false

    private static let privacyPolicyURL = URL(string: "https://github.com/Lunik/brickscan/blob/master/PRIVACY.md")!
    private static let bricksetRequestKeyURL = URL(string: "https://brickset.com/tools/webservices/requestkey")!

    /// The Rebrickable settings page is per-username (`/users/<username>/settings/#api`) — fall
    /// back to the generic profile page when no account is linked, rather than building a URL
    /// with an empty/placeholder username segment.
    private var rebrickableSettingsURL: URL {
        if let username = KeychainService.shared.load(key: .username), !username.isEmpty,
           let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return URL(string: "https://rebrickable.com/users/\(encoded)/settings/#api")!
        }
        return URL(string: "https://rebrickable.com/profile")!
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Ce qui est stocké", systemImage: "internaldrive")
                        .font(.headline)
                    Text("API Key Rebrickable et clé/identifiants Brickset : dans le Keychain iOS")
                    Text("Sets scannés récemment et cache de votre collection : dans la base SwiftData locale, sur l'appareil uniquement")
                    Text("Position des scans (si activée dans les paramètres) : approximative, sur l'appareil uniquement, supprimée dès qu'un set rejoint votre collection ou que l'historique est purgé")
                    Text("Vos mots de passe Rebrickable et Brickset ne sont jamais stockés : ils servent une seule fois à obtenir un jeton de session")
                }

                Section {
                    Label("Services contactés par l'app", systemImage: "network")
                        .font(.headline)
                    Text("Rebrickable : catalogue des sets, votre collection (si vous liez votre compte)")
                    Text("Brickset : votre liste cadeaux, avec vos identifiants Brickset (si vous liez votre compte)")
                    Text("lego.com, BrickLink et amazon.fr : consultés pour afficher les prix du marché, sans identifiant transmis")
                    Text("Apple (service de localisation) : conversion de la position en ville approximative, si l'enregistrement de position est activé")
                }

                Section {
                    Label("Vous gardez le contrôle", systemImage: "hand.raised")
                        .font(.headline)
                    Button("Gérer votre API Key sur Rebrickable") {
                        showSafari = true
                    }
                    Button("Obtenir une API Key sur Brickset") {
                        showBricksetSafari = true
                    }
                    Button("Lire la politique de confidentialité") {
                        showPrivacyPolicy = true
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
                SafariView(url: rebrickableSettingsURL)
            }
            .sheet(isPresented: $showBricksetSafari) {
                SafariView(url: Self.bricksetRequestKeyURL)
            }
            .sheet(isPresented: $showPrivacyPolicy) {
                SafariView(url: Self.privacyPolicyURL)
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
