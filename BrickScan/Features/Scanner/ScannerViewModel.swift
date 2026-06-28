import Foundation
import AVFoundation
import Observation

enum ScannerState: Equatable {
    case scanning
    case processing
    case found(LegoSet, CollectionStatus)
    case ambiguous([LegoSet])
    case notFound
    case error(String)
    case permissionDenied

    static func == (lhs: ScannerState, rhs: ScannerState) -> Bool {
        switch (lhs, rhs) {
        case (.scanning, .scanning),
             (.processing, .processing),
             (.notFound, .notFound),
             (.permissionDenied, .permissionDenied):
            return true
        case let (.found(a, _), .found(b, _)):
            return a.setNum == b.setNum
        case let (.ambiguous(a), .ambiguous(b)):
            return a.map(\.setNum) == b.map(\.setNum)
        case let (.error(a), .error(b)):
            return a == b
        default:
            return false
        }
    }
}

@Observable
@MainActor
final class ScannerViewModel {
    var state: ScannerState = .scanning
    var torchOn = false
    var candidateDetected = false
    /// True when the current `.found` state was served from the local cache (instant display)
    /// rather than a fresh fetch — lets the presenting view know to silently reconcile it live.
    var lastFoundWasFromCache = false
    /// True when the current `.found` state came from `OfflineCatalogStore` (the bundled catalogue
    /// snapshot) because the live lookup failed for lack of network — collection status and prices
    /// are not in that snapshot, so the presenting view should flag them as needing a refresh.
    var lastFoundWasOffline = false

    /// "Mode lot": while true, a resolved candidate is added to `batchSession` instead of opening
    /// the blocking detail sheet, so the camera keeps running across several sets — see issue #13.
    var isBatchModeEnabled = false
    let batchSession = BatchScanSession()
    /// Set by `lookupSetForDetail` to bypass batch capture for one resolution — used when the
    /// user taps a row in the batch summary screen and wants the normal detail sheet, even though
    /// batch mode is still on.
    private var forceDetailNextResolution = false

    var localRepository: LocalRepository?
    /// HomeView reuses this class for its non-camera lookup flows (History tap, manual entry,
    /// photo import) via a second instance that never starts the camera. The detection sound only
    /// makes sense as live feedback while actually looking at the camera screen — Home sets this
    /// false on its instance so picking a result there doesn't unexpectedly play it.
    var playsFeedbackSounds = true

    let cameraController = CameraController()
    private let barcodeScanner = BarcodeScanner()
    private let ocrScanner = OCRScanner()
    private let repository: RebrickableRepositoryProtocol

    private var lastIdentifiedSetNum: String?
    private var lastIdentifiedAt: Date?
    private var debounceTask: Task<Void, Never>?
    private var isPaused = false

    private var lastFrameProcessedAt: Date?
    private let frameProcessingInterval: TimeInterval = 0.8

    init(repository: RebrickableRepositoryProtocol = RebrickableRepository()) {
        self.repository = repository
    }

    func onAppear() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.cameraController.configure()
                    self.cameraController.onFrame = { [weak self] buffer in
                        Task { @MainActor in
                            self?.handleFrame(buffer)
                        }
                    }
                    self.cameraController.start()
                } else {
                    self.state = .permissionDenied
                }
            }
        }
    }

    func onDisappear() {
        cameraController.stop()
    }

    func toggleTorch() {
        torchOn.toggle()
        cameraController.toggleTorch(on: torchOn)
    }

    func resumeScanning() {
        state = .scanning
        isPaused = false
        candidateDetected = false
    }

    func lookupSetNumber(_ setNum: String) {
        debounceTask?.cancel()
        isPaused = true
        Task {
            await resolveSet(setNum)
        }
    }

    /// Same as `lookupSetNumber`, but always opens the detail sheet even if batch mode is on —
    /// used by the batch summary screen, where tapping a row should show the usual detail view
    /// rather than re-add the set to the session.
    func lookupSetForDetail(_ setNum: String) {
        forceDetailNextResolution = true
        lookupSetNumber(setNum)
    }

    func selectAmbiguousSet(_ legoSet: LegoSet) {
        let bypassBatch = forceDetailNextResolution
        forceDetailNextResolution = false
        state = .processing
        Task {
            presentFound(legoSet, await fetchCollectionStatus(for: legoSet.setNum), bypassBatch: bypassBatch)
        }
    }

    /// Routes a resolved candidate either to the batch session (camera keeps running) or to the
    /// normal `.found` state (opens the blocking detail sheet), depending on `isBatchModeEnabled`.
    /// `bypassBatch` is captured once per `resolveSet`/`selectAmbiguousSet` call (not re-read from
    /// `forceDetailNextResolution` on every call) so a live reconcile after a cache-instant display
    /// doesn't flip back to batch-capture mid-flow and yank the just-opened detail sheet away.
    private func presentFound(_ legoSet: LegoSet, _ collectionStatus: CollectionStatus, bypassBatch: Bool) {
        guard isBatchModeEnabled, !bypassBatch else {
            state = .found(legoSet, collectionStatus)
            return
        }
        // `resolveSet` already plays the "candidate detected" sound once at the start of this
        // resolution — don't play it again here just because the set landed in the batch session.
        batchSession.add(legoSet, collectionStatus: collectionStatus)
        resumeScanning()
    }

    func importImage(_ cgImage: CGImage) {
        debounceTask?.cancel()
        isPaused = true
        state = .processing

        barcodeScanner.detectBarcode(in: cgImage) { [weak self] barcodeValue in
            Task { @MainActor in
                if let barcodeValue {
                    let candidate = SetNumberExtractor.extractFromBarcode(barcodeValue)
                    await self?.resolveSet(candidate)
                    return
                }

                self?.ocrScanner.recognizeText(in: cgImage) { texts in
                    Task { @MainActor in
                        let candidates = SetNumberExtractor.extractFromOCR(texts)
                        if let first = candidates.first {
                            await self?.resolveSet(first)
                        } else {
                            self?.state = .notFound
                            self?.isPaused = false
                        }
                    }
                }
            }
        }
    }

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !isPaused else { return }

        if let lastFrameProcessedAt,
           Date().timeIntervalSince(lastFrameProcessedAt) < frameProcessingInterval {
            return
        }
        lastFrameProcessedAt = Date()

        barcodeScanner.detectBarcode(in: pixelBuffer) { [weak self] barcodeValue in
            if let barcodeValue {
                let candidate = SetNumberExtractor.extractFromBarcode(barcodeValue)
                self?.scheduleResolution(for: candidate)
                return
            }

            self?.ocrScanner.recognizeText(in: pixelBuffer) { texts in
                let candidates = SetNumberExtractor.extractFromOCR(texts)
                if let first = candidates.first {
                    self?.scheduleResolution(for: first)
                }
            }
        }
    }

    private func scheduleResolution(for setNum: String) {
        if setNum == lastIdentifiedSetNum,
           let lastDate = lastIdentifiedAt,
           Date().timeIntervalSince(lastDate) < 30 {
            return
        }

        candidateDetected = true
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.resolveSet(setNum)
        }
    }

    @MainActor
    private func resolveSet(_ setNum: String) async {
        let bypassBatch = forceDetailNextResolution
        forceDetailNextResolution = false

        lastIdentifiedSetNum = setNum
        lastIdentifiedAt = Date()
        isPaused = true
        candidateDetected = false
        ScanStatsStore.shared.recordScan()

        if let cached = localRepository?.cachedSet(setNum: setNum) {
            lastFoundWasFromCache = true
            lastFoundWasOffline = false
            presentFound(cached.asLegoSet(), cached.asCollectionStatus(), bypassBatch: bypassBatch)
        } else {
            lastFoundWasFromCache = false
            lastFoundWasOffline = false
            state = .processing
        }
        if playsFeedbackSounds {
            ScanFeedback.playCandidateDetectedSound()
        }

        // Skip the network round-trip (and its timeout) entirely when the device is known
        // offline — fall straight to the same offline-catalogue path the `catch` block below uses
        // for an actual `APIError.networkUnavailable`, instead of waiting to fail first.
        guard NetworkMonitor.shared.isConnected else {
            if !lastFoundWasFromCache {
                if let offlineSet = OfflineCatalogStore.shared.lookup(setNum: setNum) {
                    lastFoundWasOffline = true
                    presentFound(
                        offlineSet,
                        .unknown("Hors-ligne — statut collection et prix à rafraîchir une fois reconnecté"),
                        bypassBatch: bypassBatch
                    )
                } else {
                    state = .error(APIError.networkUnavailable.errorDescription ?? "Erreur inconnue")
                }
                isPaused = false
            }
            return
        }

        do {
            let resolution = try await repository.resolveSet(setNum: setNum)
            switch resolution {
            case .found(let legoSet):
                presentFound(legoSet, await fetchCollectionStatus(for: legoSet.setNum), bypassBatch: bypassBatch)
            case .ambiguous(let sets):
                state = .ambiguous(sets)
            case .notFound:
                // Some cached numbers (e.g. minifigs, "fig-…") can't be re-resolved through the
                // sets endpoint at all — don't let a live reconcile failure close a detail view
                // that was already showing valid cached data; just keep it as-is.
                if !lastFoundWasFromCache {
                    state = .notFound
                    isPaused = false
                }
            }
        } catch {
            if !lastFoundWasFromCache {
                if case .networkUnavailable = error as? APIError,
                   let offlineSet = OfflineCatalogStore.shared.lookup(setNum: setNum) {
                    lastFoundWasOffline = true
                    presentFound(
                        offlineSet,
                        .unknown("Hors-ligne — statut collection et prix à rafraîchir une fois reconnecté"),
                        bypassBatch: bypassBatch
                    )
                } else {
                    state = .error((error as? APIError)?.errorDescription ?? "Erreur inconnue")
                }
                isPaused = false
            }
        }
    }

    private func fetchCollectionStatus(for setNum: String) async -> CollectionStatus {
        guard NetworkMonitor.shared.isConnected else {
            return .unknown("Hors-ligne — statut collection à rafraîchir une fois reconnecté")
        }
        do {
            let userSet = try await repository.fetchUserSet(setNum: setNum)
            return userSet.map(CollectionStatus.inCollection) ?? .notInCollection
        } catch let error as APIError {
            return .unknown(error.errorDescription ?? "Statut de collection inconnu")
        } catch {
            return .unknown("Statut de collection inconnu")
        }
    }
}
