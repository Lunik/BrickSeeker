import SwiftUI

/// Date-only, French-locale style for the "last updated/downloaded" timestamps in this view —
/// the app's UI text is all French regardless of the device's system locale, so dates shown
/// here shouldn't silently follow it either.
private let frenchDateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "fr_FR"))

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @Bindable private var theme = AppTheme.shared
    @Bindable private var scanLocation = ScanLocationService.shared
    @State private var preferredPPPText: String = ""
    @State private var showPrivacyDetail = false
    @State private var isAPIKeyVisible = false
    @State private var isBricksetAPIKeyVisible = false
    @State private var isBrickLinkCredentialsVisible = false
    @State private var showClearCacheConfirmation = false
    @State private var isClearingCache = false
    @State private var toastMessage: String?
    @State private var showUnlinkConfirmation = false
    @State private var showUnlinkBricksetConfirmation = false
    @State private var pricePerPartFeedback: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                themeSection
                pricePerPartSection

                Section {
                    HStack {
                        Group {
                            if isAPIKeyVisible {
                                TextField("Clé API", text: $viewModel.apiKey)
                            } else {
                                SecureField("Clé API", text: $viewModel.apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            isAPIKeyVisible.toggle()
                        } label: {
                            Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(isAPIKeyVisible ? "Masquer la clé API" : "Afficher la clé API")
                    }

                    if viewModel.isAccountLinked {
                        Label("Compte Rebrickable lié", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        // Used to delete the token with no confirmation at all (#152), unlike
                        // "Vider le cache"/"Purger le catalogue" right below in this same form —
                        // re-linking means re-entering the password, which is never stored.
                        Button("Délier mon compte", role: .destructive) {
                            showUnlinkConfirmation = true
                        }
                    } else {
                        TextField("Nom d'utilisateur ou email", text: $viewModel.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Mot de passe", text: $viewModel.password)

                        if let errorMessage = viewModel.linkAccountErrorMessage {
                            Text(errorMessage)
                                .foregroundStyle(Color.brickDanger)
                                .font(.footnote)
                        }

                        Button {
                            Task { _ = await viewModel.linkAccount() }
                        } label: {
                            if viewModel.isLinkingAccount {
                                ProgressView()
                            } else {
                                Text("Lier mon compte")
                            }
                        }
                        .disabled(!viewModel.canLinkAccount || viewModel.isLinkingAccount)

                        if !viewModel.canLinkAccount {
                            Text("Renseignez la clé API, l'identifiant et le mot de passe pour lier le compte.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Compte Rebrickable")
                } footer: {
                    Text("Générez votre clé sur rebrickable.com/profile, dans la section « API Key ». Nécessaire pour voir et gérer votre collection. Votre mot de passe n'est jamais stocké : il sert une seule fois à obtenir un token de session.")
                }

                Section {
                    HStack {
                        Group {
                            if isBricksetAPIKeyVisible {
                                TextField("Clé API", text: $viewModel.bricksetApiKey)
                            } else {
                                SecureField("Clé API", text: $viewModel.bricksetApiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            isBricksetAPIKeyVisible.toggle()
                        } label: {
                            Image(systemName: isBricksetAPIKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(isBricksetAPIKeyVisible ? "Masquer la clé API Brickset" : "Afficher la clé API Brickset")
                    }

                    if viewModel.isBricksetAccountLinked {
                        Label("Compte Brickset lié", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Délier mon compte", role: .destructive) {
                            showUnlinkBricksetConfirmation = true
                        }
                    } else {
                        TextField("Nom d'utilisateur", text: $viewModel.bricksetUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Mot de passe", text: $viewModel.bricksetPassword)

                        if let errorMessage = viewModel.linkBricksetAccountErrorMessage {
                            Text(errorMessage)
                                .foregroundStyle(Color.brickDanger)
                                .font(.footnote)
                        }

                        Button {
                            Task { _ = await viewModel.linkBricksetAccount() }
                        } label: {
                            if viewModel.isLinkingBricksetAccount {
                                ProgressView()
                            } else {
                                Text("Lier mon compte")
                            }
                        }
                        .disabled(!viewModel.canLinkBricksetAccount || viewModel.isLinkingBricksetAccount)

                        if !viewModel.canLinkBricksetAccount {
                            Text("Renseignez la clé API, l'identifiant et le mot de passe pour lier le compte.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                } header: {
                    Text("Compte Brickset")
                } footer: {
                    Text("Nécessaire pour gérer votre liste cadeaux. Votre mot de passe n'est jamais stocké : il sert une seule fois à obtenir un token de session.")
                }

                Section {
                    Group {
                        if isBrickLinkCredentialsVisible {
                            TextField("Consumer Key", text: $viewModel.bricklinkConsumerKey)
                            TextField("Consumer Secret", text: $viewModel.bricklinkConsumerSecret)
                            TextField("Token Value", text: $viewModel.bricklinkToken)
                            TextField("Token Secret", text: $viewModel.bricklinkTokenSecret)
                        } else {
                            SecureField("Consumer Key", text: $viewModel.bricklinkConsumerKey)
                            SecureField("Consumer Secret", text: $viewModel.bricklinkConsumerSecret)
                            SecureField("Token Value", text: $viewModel.bricklinkToken)
                            SecureField("Token Secret", text: $viewModel.bricklinkTokenSecret)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        isBrickLinkCredentialsVisible.toggle()
                    } label: {
                        Label(
                            isBrickLinkCredentialsVisible ? "Masquer les identifiants" : "Afficher les identifiants",
                            systemImage: isBrickLinkCredentialsVisible ? "eye.slash" : "eye"
                        )
                    }

                    if viewModel.isBrickLinkConfigured {
                        Label("API BrickLink configurée", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if viewModel.hasAnyBrickLinkCredential {
                        Text("Renseignez les 4 valeurs pour activer les prix BrickLink.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("API BrickLink")
                } footer: {
                    Text("Générez ces 4 valeurs sur bricklink.com/v3/api.page (section « Register a Consumer », puis « Manage a Consumer » → générez un jeton) — les noms de champs ci-dessus reprennent ceux du site BrickLink. Utilisé pour afficher les prix neuf/occasion BrickLink officiels ; nécessaire uniquement pour cette fonctionnalité.")
                }

                Section {
                    Toggle("Enregistrer la position des scans", isOn: $scanLocation.isEnabled)
                        .onChange(of: scanLocation.isEnabled) { _, enabled in
                            if enabled {
                                scanLocation.requestPermissionIfNeeded()
                            }
                        }
                    if scanLocation.isPermissionBlocked {
                        Text("L'accès à la position est refusé dans les réglages iOS — aucune position ne sera enregistrée.")
                            .foregroundStyle(Color.brickDanger)
                            .font(.footnote)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Ouvrir les réglages iOS", destination: url)
                                .font(.footnote)
                        }
                    }
                } header: {
                    Text("Localisation des scans")
                } footer: {
                    Text("Capture la position (approximative) au moment d'un scan caméra, pour retrouver le magasin où vous avez vu le meilleur prix. Stockée uniquement sur l'appareil, et supprimée dès que le set rejoint votre collection.")
                }

                Section {
                    if let metadata = viewModel.offlineCatalogMetadata {
                        HStack {
                            Text("\(metadata.setCount) sets")
                            Spacer()
                            Text(metadata.downloadedAt.formatted(frenchDateStyle))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Aucun catalogue téléchargé")
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.isUpdatingOfflineCatalog {
                        ProgressView(value: viewModel.offlineCatalogDownloadProgress)
                    }

                    if let errorMessage = viewModel.offlineCatalogErrorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Color.brickDanger)
                            .font(.footnote)
                    }

                    Button {
                        Task { await viewModel.downloadOfflineCatalog() }
                    } label: {
                        HStack {
                            Text(downloadButtonTitle)
                            Spacer()
                            if viewModel.isUpdatingOfflineCatalog {
                                Text(viewModel.offlineCatalogDownloadProgress, format: .percent.precision(.fractionLength(0)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(viewModel.isUpdatingOfflineCatalog)

                    if viewModel.offlineCatalogMetadata != nil {
                        Button("Purger le catalogue", role: .destructive) {
                            viewModel.purgeOfflineCatalog()
                        }
                        .disabled(viewModel.isUpdatingOfflineCatalog)
                    }
                } header: {
                    Text("Catalogue hors-ligne")
                } footer: {
                    Text("Permet d'identifier un set déjà connu même sans réseau. Téléchargé depuis Rebrickable (~25 000 sets) ; le statut collection et les prix restent toujours en ligne.")
                }

                Section {
                    if let metadata = viewModel.minifigCatalogMetadata {
                        HStack {
                            Text("\(metadata.minifigCount) minifigs")
                            Spacer()
                            Text(metadata.downloadedAt.formatted(frenchDateStyle))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Aucun catalogue téléchargé")
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.isUpdatingMinifigCatalog {
                        ProgressView(value: viewModel.minifigCatalogDownloadProgress)
                    }

                    if let errorMessage = viewModel.minifigCatalogErrorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Color.brickDanger)
                            .font(.footnote)
                    }

                    Button {
                        Task { await viewModel.downloadMinifigCatalog() }
                    } label: {
                        HStack {
                            Text(minifigCatalogDownloadButtonTitle)
                            Spacer()
                            if viewModel.isUpdatingMinifigCatalog {
                                Text(viewModel.minifigCatalogDownloadProgress, format: .percent.precision(.fractionLength(0)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(viewModel.isUpdatingMinifigCatalog)

                    if viewModel.minifigCatalogMetadata != nil {
                        Button("Purger le catalogue", role: .destructive) {
                            viewModel.purgeMinifigCatalog()
                        }
                        .disabled(viewModel.isUpdatingMinifigCatalog)
                    }
                } header: {
                    Text("Catalogue minifigs hors-ligne")
                } footer: {
                    Text("Alimente la galerie « Mes minifigs » de l'accueil (~15 000 minifigs). Téléchargé depuis Rebrickable ; utilise aussi le catalogue de sets ci-dessus pour déterminer année/thème, et le télécharge d'abord si besoin. Les prix restent toujours en cache/en ligne, jamais chargés en masse ici.")
                }

                Section {
                    CollectionPriceUpdateSection()
                } header: {
                    Text("Prix de la collection")
                } footer: {
                    Text("Récupère les prix lego.com/Amazon/BrickLink de tous les sets de votre collection, un par un pour ne pas surcharger ces sites. Peut prendre longtemps sur une grande collection — l'app doit rester ouverte au premier plan ; si vous quittez l'app, la mise à jour se met en pause et reprendra où elle s'est arrêtée. Une notification vous prévient à la fin.")
                }

                Section {
                    PrivacyNoticeView()

                    Button {
                        showPrivacyDetail = true
                    } label: {
                        HStack {
                            Text("Confidentialité & données")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Données fournies par Rebrickable, Brickset et BrickLink.")
                }

                Section {
                    Button(role: .destructive) {
                        showClearCacheConfirmation = true
                    } label: {
                        HStack {
                            Text("Vider le cache")
                            Spacer()
                            if isClearingCache {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isClearingCache)
                } footer: {
                    Text("Supprime les images, prix et listes mis en cache. Ne touche pas à votre clé API ni à votre compte, ni à l'historique des prix ; les données seront re-téléchargées au besoin.")
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
                    .disabled(!viewModel.canSave)
                }
            }
            .sheet(isPresented: $showPrivacyDetail) {
                PrivacyDetailView()
            }
            .alert("Délier votre compte Rebrickable ?", isPresented: $showUnlinkConfirmation) {
                Button("Délier", role: .destructive) {
                    viewModel.unlinkAccount()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Vous devrez ressaisir votre mot de passe pour relier ce compte.")
            }
            .alert("Délier votre compte Brickset ?", isPresented: $showUnlinkBricksetConfirmation) {
                Button("Délier", role: .destructive) {
                    viewModel.unlinkBricksetAccount()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Vous devrez ressaisir votre mot de passe pour relier ce compte.")
            }
            .confirmationDialog(
                "Vider le cache ?",
                isPresented: $showClearCacheConfirmation,
                titleVisibility: .visible
            ) {
                Button("Vider le cache", role: .destructive) {
                    Task { await clearCache() }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Supprime les images, prix et listes mis en cache. Votre clé API, votre compte et l'historique des prix sont conservés.")
            }
            .onChange(of: scenePhase) { _, newPhase in
                viewModel.handleScenePhaseChange(isActive: newPhase == .active)
            }
            .onAppear {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 4
                formatter.decimalSeparator = ","
                preferredPPPText = formatter.string(from: theme.preferredPricePerPart as NSNumber) ?? "0,12"
            }
            .toast($toastMessage)
        }
    }

    /// Pulled out of `body` (#143's `BrandColorSwatch` extraction wasn't enough on its own) —
    /// the whole `Form` as one inline expression was too complex for the type-checker to solve in
    /// reasonable time once this section's accessibility modifiers were added.
    @ViewBuilder
    private var themeSection: some View {
        Section {
            HStack(spacing: 18) {
                ForEach(BrandColor.allCases) { brand in
                    BrandColorSwatch(brand: brand, isSelected: theme.brandColor == brand) {
                        theme.brandColor = brand
                    }
                }
            }
            .padding(.vertical, 4)

            Picker("Apparence", selection: $theme.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Thème")
        } footer: {
            Text("Choisissez la couleur de marque et l'apparence claire/sombre de l'application.")
        }
    }

    /// Pulled out of `body` for the same type-checker reason as `themeSection` — the invalid
    /// -input feedback row (#154) added enough branching to tip the whole `Form` over.
    @ViewBuilder
    private var pricePerPartSection: some View {
        Section {
            HStack {
                Text("Cible €/pièce")
                Spacer()
                TextField("0,12", text: $preferredPPPText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: preferredPPPText) { _, new in
                        let normalised = new.replacingOccurrences(of: ",", with: ".")
                        if let value = Double(normalised), value > 0 {
                            theme.preferredPricePerPart = value
                            pricePerPartFeedback = nil
                        } else {
                            // Used to silently keep the last valid value with zero feedback
                            // (#154) — an empty/0/non-numeric entry now says so and offers a way
                            // back to the default instead of leaving the field looking accepted.
                            pricePerPartFeedback = String(localized: "Valeur invalide — la dernière valeur valide est conservée.")
                        }
                    }
                Text("€")
                    .foregroundStyle(.secondary)
            }
            if let pricePerPartFeedback {
                HStack {
                    InlineErrorLabel(message: pricePerPartFeedback)
                    Spacer()
                    Button("Réinitialiser") {
                        preferredPPPText = "0,12"
                        theme.preferredPricePerPart = AppTheme.defaultPreferredPricePerPart
                        self.pricePerPartFeedback = nil
                    }
                    .font(.footnote)
                }
            }
        } header: {
            Text("Valeur cible")
        } footer: {
            Text("Seuil de €/pièce en dessous duquel un set est considéré comme un bon rapport qualité-prix. Affiché en vert sur la fiche set si le prix lego.com est inférieur à cette valeur, en rouge au-dessus.")
        }
    }

    private var downloadButtonTitle: String {
        if viewModel.isUpdatingOfflineCatalog {
            return "Téléchargement en cours…"
        }
        if viewModel.hasResumableOfflineCatalogDownload {
            return "Reprendre le téléchargement"
        }
        return viewModel.offlineCatalogMetadata == nil ? "Télécharger le catalogue" : "Mettre à jour le catalogue"
    }

    private var minifigCatalogDownloadButtonTitle: String {
        if viewModel.isUpdatingMinifigCatalog {
            return "Téléchargement en cours…"
        }
        return viewModel.minifigCatalogMetadata == nil ? "Télécharger le catalogue" : "Mettre à jour le catalogue"
    }

    private func clearCache() async {
        isClearingCache = true
        LocalRepository(modelContext: modelContext).clearAll()
        await ImageCache.shared.clearAll()
        await BrickLinkMinifigIdStore.shared.clearAll()
        isClearingCache = false
        // A transient toast (#154), not a permanent green checkmark — the checkmark used to never
        // clear itself, so it kept reading "cache vidé" long after the cache had genuinely
        // re-filled from normal use.
        toastMessage = String(localized: "Cache vidé")
    }
}

/// One brand-color swatch. Pulled out of `SettingsView.body` — inlined, the accessibility
/// modifiers on top of the existing conditional overlay made that `ForEach` too complex for the
/// type-checker to solve in reasonable time.
private struct BrandColorSwatch: View {
    let brand: BrandColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(brand.accent)
                .frame(width: 34, height: 34)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(.primary, lineWidth: 2)
                            .padding(-3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(brand.displayName)
        // The label named the color but never said which one was actually selected (#143) —
        // VoiceOver's own "sélectionné(e)" trait plus an explicit value cover both a swipe
        // -through and a direct query.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue(isSelected ? "Sélectionné" : "")
    }
}
