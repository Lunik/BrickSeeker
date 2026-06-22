import SwiftUI
import SwiftData

@main
struct BrickScanApp: App {
    @State private var isShowingSplash = true

    var modelContainer: ModelContainer = {
        let schema = Schema([CachedSet.self, CachedSetList.self, CachedUnresolvedBoxCode.self])
        let configuration = ModelConfiguration(schema: schema)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                ScannerView()
                    .onReceive(NotificationCenter.default.publisher(for: .didReset)) { _ in
                        let context = modelContainer.mainContext
                        LocalRepository(modelContext: context).clearAll()
                    }

                if isShowingSplash {
                    SplashView()
                        .transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    isShowingSplash = false
                }
            }
        }
        .modelContainer(modelContainer)
    }
}
