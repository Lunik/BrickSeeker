import SwiftUI
import SafariServices

struct PrivacyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showSafari = false
    @State private var showBricksetSafari = false
    @State private var showBrickLinkSafari = false
    @State private var showPrivacyPolicy = false
    @State private var showResetConfirmation = false

    private static let privacyPolicyURL = URL(string: "https://github.com/Lunik/BrickSeeker/blob/master/PRIVACY.md")!
    private static let bricksetRequestKeyURL = URL(string: "https://brickset.com/tools/webservices/requestkey")!
    private static let rebrickableSettingsURL = URL(string: "https://rebrickable.com/api/")!
    private static let bricklinkAPISettingsURL = URL(string: "https://www.bricklink.com/v2/api/register_consumer.page")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Ce qui est stocké", systemImage: "internaldrive")
                        .font(.headline)
                    Text("API Key Rebrickable, clé/identifiants Brickset et identifiants API BrickLink (OAuth) : dans le Keychain iOS")
                    Text("Sets scannés récemment et cache de votre collection : dans la base SwiftData locale, sur l'appareil uniquement")
                    Text("Position des scans (si activée dans les paramètres) : approximative, sur l'appareil uniquement, supprimée dès qu'un set rejoint votre collection ou que l'historique est purgé")
                    Text("Vos mots de passe Rebrickable et Brickset ne sont jamais stockés : ils servent une seule fois à obtenir un jeton de session")
                }

                Section {
                    Label("Services contactés par l'app", systemImage: "network")
                        .font(.headline)
                    Text("Rebrickable : catalogue des sets, votre collection (si vous liez votre compte)")
                    Text("Brickset : votre liste cadeaux, avec vos identifiants Brickset (si vous liez votre compte)")
                    Text("BrickLink (API officielle) : prix neuf/occasion, avec vos identifiants API BrickLink (si vous les renseignez)")
                    Text("lego.com et amazon.fr : consultés pour afficher les prix du marché, sans identifiant transmis")
                    Text("Apple (service de localisation) : conversion de la position en ville approximative, si l'enregistrement de position est activé")
                }

                Section {
                    Label("Vous gardez le contrôle", systemImage: "hand.raised")
                        .font(.headline)
                    Button("Gérer votre API Key sur Rebrickable") {
                        showSafari = true
                    }
                    Button("Gérer votre API Key sur Brickset") {
                        showBricksetSafari = true
                    }
                    Button("Gérer votre api key sur bricklink") {
                        showBrickLinkSafari = true
                    }
                    Button("Lire la politique de confidentialité") {
                        showPrivacyPolicy = true
                    }
                    Button("Réinitialiser BrickSeeker", role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }
            .navigationTitle("Comment BrickSeeker protège vos données")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
            .sheet(isPresented: $showSafari) {
                SafariView(url: Self.rebrickableSettingsURL)
            }
            .sheet(isPresented: $showBricksetSafari) {
                SafariView(url: Self.bricksetRequestKeyURL)
            }
            .sheet(isPresented: $showBrickLinkSafari) {
                SafariView(url: Self.bricklinkAPISettingsURL)
            }
            .sheet(isPresented: $showPrivacyPolicy) {
                SafariView(url: Self.privacyPolicyURL)
            }
            .confirmationDialog(
                "Réinitialiser BrickSeeker ?",
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
    static let didReset = Notification.Name("BrickSeeker.didReset")
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
