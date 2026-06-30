import SwiftUI

/// Date-only, French-locale style for the "last updated/downloaded" timestamps in this view —
/// the app's UI text is all French regardless of the device's system locale, so dates shown
/// here shouldn't silently follow it either.
private let frenchDateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "fr_FR"))

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @Bindable private var theme = AppTheme.shared
    @State private var preferredPPPText: String = ""
    @State private var showPrivacyDetail = false
    @State private var isAPIKeyVisible = false
    @State private var showClearCacheConfirmation = false
    @State private var isClearingCache = false
    @State private var cacheCleared = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 18) {
                        ForEach(BrandColor.allCases) { brand in
                            Button {
                                theme.brandColor = brand
                            } label: {
                                Circle()
                                    .fill(brand.accent)
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if theme.brandColor == brand {
                                            Circle()
                                                .strokeBorder(.primary, lineWidth: 2)
                                                .padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(brand.displayName)
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
                                }
                            }
                        Text("€")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Valeur cible")
                } footer: {
                    Text("Seuil de €/pièce en dessous duquel un set est considéré comme un bon rapport qualité-prix. Affiché en vert sur la fiche set si le prix lego.com est inférieur à cette valeur, en rouge au-dessus.")
                }

                Section {
                    HStack {
                        Group {
                            if isAPIKeyVisible {
                                TextField("API Key", text: $viewModel.apiKey)
                            } else {
                                SecureField("API Key", text: $viewModel.apiKey)
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
                    }
                } header: {
                    Text("API Key Rebrickable")
                } footer: {
                    Text("Génère ta clé sur rebrickable.com/profile, dans la section API Key.")
                }

                Section {
                    if viewModel.isAccountLinked {
                        Label("Compte Rebrickable lié", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Délier mon compte", role: .destructive) {
                            viewModel.unlinkAccount()
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

                        if !viewModel.username.isEmpty && !viewModel.password.isEmpty {
                            Button {
                                Task { _ = await viewModel.linkAccount() }
                            } label: {
                                if viewModel.isLinkingAccount {
                                    ProgressView()
                                } else {
                                    Text("Lier mon compte")
                                }
                            }
                            .disabled(viewModel.apiKey.isEmpty || viewModel.isLinkingAccount)
                        }
                    }
                } header: {
                    Text("Compte Rebrickable")
                } footer: {
                    Text("Nécessaire pour voir et gérer votre collection. Votre mot de passe n'est jamais stocké : il sert une seule fois à obtenir un token de session.")
                }

                Section {
                    PrivacyNoticeView()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
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
                    if let lastCompletedAt = viewModel.priceUpdateLastCompletedAt {
                        Text("Dernière actualisation : \(lastCompletedAt.formatted(frenchDateStyle))")
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.isUpdatingAllPrices {
                        ProgressView(value: Double(viewModel.priceUpdateDone), total: Double(max(viewModel.priceUpdateTotal, 1)))
                    }

                    if viewModel.isUpdatingAllPrices || viewModel.hasResumablePriceUpdate {
                        Text("\(viewModel.priceUpdateDone) / \(viewModel.priceUpdateTotal) sets")
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage = viewModel.priceUpdateErrorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Color.brickDanger)
                            .font(.footnote)
                    }

                    Button(priceUpdateButtonTitle) {
                        Task { await viewModel.updateAllPrices(modelContext: modelContext) }
                    }
                    .disabled(viewModel.isUpdatingAllPrices)
                } header: {
                    Text("Prix de la collection")
                } footer: {
                    Text("Récupère les prix lego.com/Amazon/BrickLink de tous les sets de votre collection, un par un pour ne pas surcharger ces sites. Peut prendre longtemps sur une grande collection — l'app doit rester ouverte au premier plan ; si vous quittez l'app, la mise à jour se met en pause et reprendra où elle s'est arrêtée. Une notification vous prévient à la fin.")
                }

                Section {
                    Button("Confidentialité & données") {
                        showPrivacyDetail = true
                    }
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
                            } else if cacheCleared {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
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
                    .disabled(viewModel.apiKey.isEmpty)
                }
            }
            .sheet(isPresented: $showPrivacyDetail) {
                PrivacyDetailView()
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

    private var priceUpdateButtonTitle: String {
        if viewModel.isUpdatingAllPrices {
            return "Mise à jour en cours…"
        }
        if viewModel.hasResumablePriceUpdate {
            return "Reprendre (\(viewModel.priceUpdateTotal - viewModel.priceUpdateDone) restants)"
        }
        return "Actualiser les prix de la collection"
    }

    private func clearCache() async {
        isClearingCache = true
        cacheCleared = false
        LocalRepository(modelContext: modelContext).clearAll()
        await ImageCache.shared.clearAll()
        isClearingCache = false
        cacheCleared = true
    }
}
