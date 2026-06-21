import SwiftUI
import SwiftData

@main
struct BrickScanApp: App {
    var modelContainer: ModelContainer = {
        let schema = Schema([CachedSet.self, CachedSetList.self])
        let configuration = ModelConfiguration(schema: schema)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    var body: some Scene {
        WindowGroup {
            ScannerView()
                .onReceive(NotificationCenter.default.publisher(for: .didReset)) { _ in
                    let context = modelContainer.mainContext
                    LocalRepository(modelContext: context).clearAll()
                }
        }
        .modelContainer(modelContainer)
    }
}
