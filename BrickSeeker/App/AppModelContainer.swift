import SwiftData

/// The app's single SwiftData container.
///
/// Pulled out of `BrickSeekerApp` (#230) because `BackgroundPriceRefresher` needs the same store
/// from a `BGAppRefreshTask`, which can run without the `WindowGroup` scene ever being built — and
/// two `ModelContainer`s over one store file is exactly the conflict this avoids. Any new
/// `@Model` type must be added to `schema` here.
enum AppModelContainer {
    static let shared: ModelContainer = {
        let schema = Schema([
            CachedSet.self,
            CachedSetList.self,
            CollectionSyncState.self,
            CachedSetPrice.self,
            PriceHistoryEntry.self,
            SoldListingEntry.self,
            ScanEvent.self,
            SetPurchaseRecord.self,
            PriceAlert.self,
        ])
        let configuration = ModelConfiguration(schema: schema)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()
}
