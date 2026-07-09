import SwiftUI
import SwiftData

@main
struct BrickSeekerApp: App {
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
    @Environment(\.scenePhase) private var scenePhase
    // UserDefaults-backed (not `@State`), so "seen the onboarding" survives HomeView/homeViewModel
    // being recreated and process relaunches — only a fresh install or an explicit reset (see the
    // `.didReset` handler below) should ever show it again. Writing this flag is the only thing
    // the onboarding does with persistence; already covered by the required-reason API disclosure
    // (CA92.1) declared for the rest of the app's `UserDefaults` use — no new privacy disclosure
    // needed (#158).
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    var modelContainer: ModelContainer = {
        let schema = Schema([CachedSet.self, CachedSetList.self, CollectionSyncState.self, CachedSetPrice.self, PriceHistoryEntry.self, ScanEvent.self])
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
                    // The reset wipes SwiftData + Keychain but not UserDefaults — re-arm the
                    // onboarding too so a reset genuinely looks like a fresh install (#158).
                    hasSeenOnboarding = false
                }
                // Covers the warm-app case (app already running, springboard calls
                // performActionFor): the property changes while this view is already observing.
                .onChange(of: shortcutCenter.pendingShortcut) { _, _ in consumePendingShortcut() }
                // Covers cold launch: AppDelegate sets pendingShortcut in
                // didFinishLaunchingWithOptions before this view tree exists, so onChange's
                // initial baseline already includes it and never reports a "change".
                .onAppear { consumePendingShortcut() }
                // Auto-resumes a collection price update paused by backgrounding (see
                // `CollectionPriceUpdater`/`SettingsViewModel.handleScenePhaseChange`) the moment
                // the app is reopened — the user shouldn't have to go back into Settings and tap
                // "Reprendre" themselves just to continue a job they already started.
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task { await CollectionPriceUpdater.shared.resumeIfNeeded(modelContext: modelContainer.mainContext) }
                }

                if isShowingSplash {
                    SplashView()
                        .transition(.opacity)
                }

                if !networkMonitor.isConnected {
                    OfflineIndicatorView()
                }
            }
            .animation(.easeOut(duration: 0.2), value: networkMonitor.isConnected)
            .tint(AppTheme.shared.accent)
            .preferredColorScheme(AppTheme.shared.colorScheme)
            .task {
                // Start decoding the offline-catalogue snapshot in the background now, so the
                // first offline lookup doesn't have to wait for a ~27k-set JSON decode (#69).
                OfflineCatalogStore.shared.warmUp()
                if homeViewModel == nil {
                    let vm = HomeViewModel(localRepository: LocalRepository(modelContext: modelContainer.mainContext))
                    homeViewModel = vm
                    // The initial sync keeps the splash up only briefly (#148: so Home/Collection/
                    // Statistics don't show a misleadingly-empty state while it's still in flight)
                    // but is otherwise independent of the splash — created outside the task group
                    // below so `cancelAll()` only cancels the two waiters, never `sync` itself. A
                    // sync slower than the 3s cap just keeps running in the background afterwards;
                    // `syncCollection()` already tolerates `CancellationError`.
                    let sync = Task { await vm.syncCollection() }
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { _ = await sync.value }
                        group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) } // cap MAX
                        await group.next()
                        group.cancelAll()
                    }
                }
                withAnimation(.easeOut(duration: 0.3)) {
                    isShowingSplash = false
                }
                if !hasSeenOnboarding {
                    showOnboarding = true
                }
            }
            .fullScreenCover(isPresented: $showOnboarding, onDismiss: {
                hasSeenOnboarding = true
                // Mirrors HomeView's Settings `onDismiss`: the user may have just linked an
                // account from the onboarding's "Lier mon compte" CTA, so re-sync now rather than
                // waiting for the next launch/pull-to-refresh to notice.
                if let homeViewModel {
                    Task { await homeViewModel.syncCollection() }
                }
            }) {
                OnboardingView()
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
