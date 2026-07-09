import SwiftUI

/// First-launch modal (#158), presented once at the app root — see `BrickSeekerApp` — right
/// after the splash. Pitches the scan → identify → compare flow and offers two friction-free next
/// steps: download the offline catalogue (works with no account/API key at all) or jump straight
/// to linking a Rebrickable/Brickset/BrickLink account from Settings. Deliberately brand-neutral
/// (app-store-compliance): never renders the word "LEGO" or any set/box/minifig artwork — only SF
/// Symbols and the app's own theme accent, same as the rest of the app's chrome.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var isDownloadingCatalog = false
    @State private var downloadProgress: Double = 0
    @State private var downloadErrorMessage: String?
    @State private var catalogMetadata: OfflineCatalogStore.Metadata? = OfflineCatalogStore.shared.metadata

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    pitchText
                    stepsSection
                    offlineCatalogSection
                    linkAccountSection
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Passer") { dismiss() }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.shared.accent)
            Text("Bienvenue dans BrickSeeker")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var pitchText: some View {
        Text("Scannez la boîte d'un set pour l'identifier, puis comparez les prix neuf/occasion en un instant.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepRow(icon: "camera", text: "Scannez la boîte")
            stepRow(icon: "checkmark.circle", text: "On identifie le set")
            stepRow(icon: "eurosign.circle", text: "Comparez les prix")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // `minHeight`, not a fixed height, so Dynamic Type XXL doesn't clip the label.
    private func stepRow(icon: String, text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.shared.accent)
        }
        .frame(minHeight: 24, alignment: .leading)
    }

    private var offlineCatalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Télécharger le catalogue hors-ligne").font(.headline)
            Text("Recherche de sets sans compte ni clé API.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let catalogMetadata {
                Label("Catalogue téléchargé (\(catalogMetadata.setCount) sets)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.footnote)
            }

            if isDownloadingCatalog {
                ProgressView(value: downloadProgress)
            }

            if let downloadErrorMessage {
                Text(downloadErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.brickDanger)
            }

            Button {
                Task { await downloadOfflineCatalog() }
            } label: {
                HStack {
                    Text(downloadButtonTitle)
                    Spacer()
                    if isDownloadingCatalog {
                        Text(downloadProgress, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDownloadingCatalog)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var linkAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Déjà un compte ?").font(.headline)
            Text("Liez votre compte Rebrickable, Brickset ou BrickLink pour voir votre collection et des prix personnalisés.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Lier mon compte") { showSettings = true }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var downloadButtonTitle: String {
        if isDownloadingCatalog { return "Téléchargement en cours…" }
        return catalogMetadata == nil ? "Télécharger le catalogue hors-ligne" : "Mettre à jour le catalogue"
    }

    private func downloadOfflineCatalog() async {
        isDownloadingCatalog = true
        downloadProgress = 0
        downloadErrorMessage = nil
        defer { isDownloadingCatalog = false }
        do {
            try await OfflineCatalogStore.shared.download { value in
                downloadProgress = value
            }
            catalogMetadata = OfflineCatalogStore.shared.metadata
        } catch {
            // Never blocks continuing the onboarding — the offline catalogue is a convenience,
            // not a requirement, and the user can always retry later from Réglages.
            downloadErrorMessage = String(localized: "Téléchargement impossible. Vous pourrez réessayer plus tard depuis Réglages.")
        }
    }
}
