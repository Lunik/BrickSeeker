import SwiftUI
import SwiftData

@main
struct BrickScanApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var isShowingSplash = true
    @State private var isScanning = false
    // Owned here, not inside HomeView, so it survives Scanner/Home toggling — HomeView is
    // recreated every time the camera is exited, and re-syncing the collection on every single
    // return from the camera was a needless network round-trip. Created once at real app launch.
    @State private var homeViewModel: HomeViewModel?
    @State private var networkMonitor = NetworkMonitor.shared
    @State private var shortcutCenter = ShortcutCenter.shared
    @State private var pendingHomeAction: HomeScreenShortcut?

    var modelContainer: ModelContainer = {
        let schema = Schema([CachedSet.self, CachedSetList.self, CollectionSyncState.self, CachedSetPrice.self, PriceHistoryEntry.self])
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
                        HomeView(
                            viewModel: homeViewModel,
                            onStartScanning: { isScanning = true },
                            pendingAction: $pendingHomeAction
                        )
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .didReset)) { _ in
                    let context = modelContainer.mainContext
                    LocalRepository(modelContext: context).clearAll()
                }
                // Covers the warm-app case (app already running, springboard calls
                // performActionFor): the property changes while this view is already observing.
                .onChange(of: shortcutCenter.pendingShortcut) { _, _ in consumePendingShortcut() }
                // Covers cold launch: AppDelegate sets pendingShortcut in
                // didFinishLaunchingWithOptions before this view tree exists, so onChange's
                // initial baseline already includes it and never reports a "change".
                .onAppear { consumePendingShortcut() }

                if isShowingSplash {
                    SplashView()
                        .transition(.opacity)
                }

                if !networkMonitor.isConnected {
                    OfflineIndicatorView()
                }
            }
            .animation(.easeOut(duration: 0.2), value: networkMonitor.isConnected)
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

    private func consumePendingShortcut() {
        guard let shortcut = shortcutCenter.pendingShortcut else { return }
        shortcutCenter.pendingShortcut = nil
        switch shortcut {
        case .scan:
            isScanning = true
        case .manualEntry, .photo:
            isScanning = false
            pendingHomeAction = shortcut
        }
    }
}
