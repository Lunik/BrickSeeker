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
                    ContentUnavailableView(
                        "Aucun scan localisé",
                        systemImage: "mappin.slash",
                        description: Text("Active la localisation des scans dans les paramètres, puis scanne un set en magasin.")
                    )
                } else {
                    Map(selection: $selectedEventID) {
                        ForEach(events) { event in
                            if let latitude = event.latitude, let longitude = event.longitude {
                                Marker(
                                    nameBySetNum[event.setNum] ?? event.setNum,
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
        }
    }

    private func selectedEventCard(_ event: ScanEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(nameBySetNum[event.setNum].map { "\(event.setNum) · \($0)" } ?? event.setNum)
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
                }
            }
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
