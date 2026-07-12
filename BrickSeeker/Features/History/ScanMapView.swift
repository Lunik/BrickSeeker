import SwiftUI
import SwiftData
import MapKit

/// Map of located scan events (issue #46) — "where did I see that deal". Presented from
/// History for every located scan, and from SetDetail's "Tes scans" section filtered to one
/// set. Tapping a marker shows the scan's details; `onSelect` (History only) additionally
/// offers opening the set's detail sheet.
struct ScanMapView: View {
    @Query private var events: [ScanEvent]
    @Query private var cachedSets: [CachedSet]
    @State private var selectedEventID: PersistentIdentifier?
    @State private var showSettings = false
    @Environment(\.dismiss) private var dismiss

    /// Only meaningful for the global (History) map: re-looks up the tapped scan's set.
    let onSelect: ((String) -> Void)?

    /// French-locale date+time for scan rows — the app's UI is French-only, dates shouldn't
    /// silently follow the device locale.
    static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: "fr_FR"))

    init(setNum: String? = nil, onSelect: ((String) -> Void)? = nil) {
        self.onSelect = onSelect
        if let setNum {
            _events = Query(filter: #Predicate<ScanEvent> { $0.latitude != nil && $0.setNum == setNum })
        } else {
            _events = Query(filter: #Predicate<ScanEvent> { $0.latitude != nil })
        }
    }

    private var nameBySetNum: [String: String] {
        Dictionary(cachedSets.map { ($0.setNum, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private var selectedEvent: ScanEvent? {
        events.first { $0.persistentModelID == selectedEventID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    // Named a setting that doesn't exist ("localisation des scans" — the real
                    // toggle is "Enregistrer la position des scans") and gave no way to actually
                    // reach it (#147).
                    ContentUnavailableView {
                        Label("Aucun scan localisé", systemImage: "mappin.slash")
                    } description: {
                        Text("Activez « Enregistrer la position des scans » dans les Réglages, puis scannez un set en magasin.")
                    } actions: {
                        Button("Ouvrir les Réglages") {
                            showSettings = true
                        }
                    }
                } else {
                    Map(selection: $selectedEventID) {
                        ForEach(events) { event in
                            if let latitude = event.latitude, let longitude = event.longitude {
                                Marker(
                                    nameBySetNum[event.setNum] ?? event.setNum.baseSetNum,
                                    systemImage: "shippingbox.fill",
                                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                                )
                                .tint(AppTheme.shared.accent)
                                .tag(event.persistentModelID)
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if let event = selectedEvent {
                            selectedEventCard(event)
                        }
                    }
                }
            }
            .navigationTitle("Carte des scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private func selectedEventCard(_ event: ScanEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Combined into one VoiceOver stop instead of 4 separate ones (name, place, date,
            // price) — matches `StatCard`'s `.combine` convention (#143). Scoped to just this
            // inner group (not the whole card) so the "Voir le set" button below stays its own,
            // independently actionable stop rather than being swallowed into the combine too.
            VStack(alignment: .leading, spacing: 6) {
                Text(nameBySetNum[event.setNum].map { "\(event.setNum.baseSetNum) · \($0)" } ?? event.setNum.baseSetNum)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if let placeName = event.placeName {
                    Label(placeName, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(event.scannedAt.formatted(Self.dateStyle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let price = event.priceSeenEUR {
                        Text(Decimal(price).formatted(.currency(code: "EUR")))
                            .font(.footnote.bold())
                            .accessibilityLabel("Prix vu : \(Decimal(price).formatted(.currency(code: "EUR")))")
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if let onSelect {
                Button("Voir le set") {
                    onSelect(event.setNum)
                }
                .font(.footnote.bold())
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.shared.accent)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
