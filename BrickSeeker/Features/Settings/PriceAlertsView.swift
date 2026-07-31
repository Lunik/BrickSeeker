import SwiftUI
import SwiftData

/// Every price alert the user has configured (#229), reachable from Réglages.
///
/// Follows the list-screen pattern of `AGENTS.md` as far as it applies: `SetRowView` rows,
/// `ContentUnavailableView` empty state, swipe-to-delete, `.contextMenu` mirroring the row's own
/// actions. It deliberately skips the parts of that pattern built for browsing a *catalog* — the
/// `.searchable` bar, `SetFilterState` and multi-select — because this list is a handful of
/// hand-made entries, not hundreds of synced sets; adding a search field and a filter sheet over
/// three rows would be chrome without a purpose.
///
/// Presented as a sheet from Réglages (which is itself a sheet) rather than pushed from Home, since
/// that's where #229 asks for it and where the alert's own "how often is this actually checked?"
/// context lives.
struct PriceAlertsView: View {
    @Query(sort: \PriceAlert.createdAt, order: .reverse) private var alerts: [PriceAlert]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var alertPendingDeletion: PriceAlert?
    @State private var isAuthorized = true

    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "fr_FR"))

    var body: some View {
        NavigationStack {
            Group {
                if alerts.isEmpty {
                    ContentUnavailableView(
                        "Aucune alerte de prix",
                        systemImage: "bell.slash",
                        description: Text("Ouvrez la fiche d'un set et touchez « Alerte de prix » pour être prévenu quand il descend sous un seuil.")
                    )
                } else {
                    List {
                        if !isAuthorized {
                            Section {
                                Label("Les notifications sont désactivées pour BrickSeeker — aucune alerte ne peut vous prévenir.", systemImage: "bell.slash")
                                    .font(.footnote)
                                    .foregroundStyle(Color.brickDanger)
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    Link("Ouvrir les réglages iOS", destination: url)
                                        .font(.footnote)
                                }
                            }
                        }

                        Section {
                            ForEach(alerts) { alert in
                                row(for: alert)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            delete(alert)
                                        } label: {
                                            Label("Supprimer", systemImage: "trash")
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            setEnabled(alert, isEnabled: !alert.isEnabled)
                                        } label: {
                                            Label(
                                                alert.isEnabled ? "Désactiver" : "Activer",
                                                systemImage: alert.isEnabled ? "bell.slash" : "bell"
                                            )
                                        }
                                        Button(role: .destructive) {
                                            alertPendingDeletion = alert
                                        } label: {
                                            Label("Supprimer l'alerte", systemImage: "trash")
                                        }
                                    }
                            }
                        } footer: {
                            Text("Les prix des sets sous alerte et de la liste cadeaux sont actualisés en tâche de fond, quand iOS l'autorise, puis au lancement de l'app. Seuls les prix BrickLink peuvent être récupérés en tâche de fond.")
                        }
                    }
                }
            }
            .navigationTitle("Alertes de prix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
            .alert(
                "Supprimer cette alerte ?",
                isPresented: Binding(
                    get: { alertPendingDeletion != nil },
                    set: { if !$0 { alertPendingDeletion = nil } }
                )
            ) {
                Button("Supprimer", role: .destructive) {
                    if let alertPendingDeletion { delete(alertPendingDeletion) }
                }
                Button("Annuler", role: .cancel) {}
            }
            .task {
                isAuthorized = await PriceUpdateNotifier.isAuthorized()
            }
        }
    }

    /// The row is not tappable-to-open: an alert can outlive its `CachedSet` (see `PriceAlert`), so
    /// "open the set" isn't always an action this screen can honestly offer. Editing happens from
    /// the set's own detail screen, which is where the alert was created.
    private func row(for alert: PriceAlert) -> some View {
        SetRowView(
            setNum: alert.setNum,
            name: alert.setName,
            setImgUrl: alert.setImgUrl,
            subtitle: subtitle(for: alert),
            resolvedPrice: alert.lastObservedPriceEUR,
            priceLabel: alert.lastObservedPriceEUR == nil ? nil : String(localized: "Dernier prix vu")
        ) {
            Toggle("", isOn: Binding(
                get: { alert.isEnabled },
                set: { setEnabled(alert, isEnabled: $0) }
            ))
            .labelsHidden()
            .accessibilityLabel(alert.isEnabled ? "Alerte active" : "Alerte désactivée")
        }
        .opacity(alert.isEnabled ? 1 : 0.5)
    }

    /// "Sous 47,99 € · Occasion", plus the percentage it came from when there was one — a stored
    /// "−20 %" is meaningless on its own once the reference is frozen, so both are shown.
    private func subtitle(for alert: PriceAlert) -> String {
        var parts: [String] = []
        if let threshold = alert.effectiveThresholdEUR {
            parts.append(String(localized: "Sous \(Decimal(threshold).formatted(.currency(code: "EUR")))"))
        }
        if let percent = alert.discountPercent {
            parts.append(String(localized: "−\(percent.formatted(.number.precision(.fractionLength(0...1)))) %"))
        }
        parts.append(alert.condition.displayName)
        if let lastNotifiedAt = alert.lastNotifiedAt {
            parts.append(String(localized: "prévenu le \(lastNotifiedAt.formatted(Self.dateStyle))"))
        }
        return parts.joined(separator: " · ")
    }

    private func setEnabled(_ alert: PriceAlert, isEnabled: Bool) {
        LocalRepository(modelContext: modelContext).setPriceAlertEnabled(alert, isEnabled: isEnabled)
        BackgroundPriceRefresher.shared.scheduleIfNeeded(modelContext: modelContext)
    }

    private func delete(_ alert: PriceAlert) {
        LocalRepository(modelContext: modelContext).deletePriceAlert(alert)
        BackgroundPriceRefresher.shared.scheduleIfNeeded(modelContext: modelContext)
    }
}
