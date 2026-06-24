import SwiftUI
import SwiftData

@main
struct BrickScanApp: App {
    @State private var isShowingSplash = true
    @State private var isScanning = false
    // Owned here, not inside HomeView, so it survives Scanner/Home toggling — HomeView is
    // recreated every time the camera is exited, and re-syncing the collection on every single
    // return from the camera was a needless network round-trip. Created once at real app launch.
    @State private var homeViewModel: HomeViewModel?

    var modelContainer: ModelContainer = {
        let schema = Schema([CachedSet.self, CachedSetList.self, CollectionSyncState.self, CachedSetPrice.self])
        let configuration = ModelConfiguration(schema: schema)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                Group {
                    if isScanning {
                        ScannerView(onStopScanning: { isScanning = false })
                    } else if let homeViewModel {
                        HomeView(viewModel: homeViewModel, onStartScanning: { isScanning = true })
                    }
                }
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
                if homeViewModel == nil {
                    let vm = HomeViewModel(localRepository: LocalRepository(modelContext: modelContainer.mainContext))
                    homeViewModel = vm
                    await vm.syncCollection()
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
