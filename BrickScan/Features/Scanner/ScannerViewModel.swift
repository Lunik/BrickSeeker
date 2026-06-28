import Foundation
import AVFoundation
import Observation
import UIKit

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
    /// A crop of the reticle region captured the moment a candidate is detected — lets the
    /// overlay show "this is what got scanned" before the network result comes back. Captured
    /// once per candidate (see `scheduleResolution`), cleared on `resumeScanning` — see #32.
    var candidateThumbnail: UIImage?
    /// The on-screen reticle size, shared with `ScanOverlayView` and the Vision region of
    /// interest / thumbnail crop, so "what's aimed at" and "what's detected" always agree.
    static let reticleSize = CGSize(width: 280, height: 180)
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
    private let ocrScanner = OCRScanner()
    private let repository: RebrickableRepositoryProtocol

    /// When each set number was last resolved, for the 30s anti-repeat lock. Keyed per set number
    /// (not a single scalar) so identifying box A doesn't reset the clock that's protecting box B
    /// — see `scheduleResolution`.
    private var recentlyIdentifiedAt: [String: Date] = [:]
    /// One pending debounce per set number currently in frame, keyed the same way — a single
    /// shared task would mean pointing the camera at a second box within the 1.5s debounce window
    /// cancels the first box's pending resolution, which made batch mode unusable for scanning
    /// several boxes in quick succession (see issue #13 follow-up).
    private var debounceTasks: [String: Task<Void, Never>] = [:]
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
        candidateThumbnail = nil
    }

    func lookupSetNumber(_ setNum: String) {
        cancelAllDebounceTasks()
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
    ///
    /// `wasFromCache`/`wasOffline` are only written to the published `lastFoundWas...` flags on the
    /// non-batch branch: while batch-capturing, several resolutions can be in flight concurrently
    /// (see `resolveSet`), and those flags are only meaningful right before a detail sheet reads
    /// them — writing them here for every batch item would let an unrelated in-flight scan's value
    /// win the race and corrupt the one sheet that's actually about to open.
    private func presentFound(
        _ legoSet: LegoSet,
        _ collectionStatus: CollectionStatus,
        bypassBatch: Bool,
        wasFromCache: Bool = false,
        wasOffline: Bool = false
    ) {
        guard isBatchModeEnabled, !bypassBatch else {
            lastFoundWasFromCache = wasFromCache
            lastFoundWasOffline = wasOffline
            state = .found(legoSet, collectionStatus)
            return
        }
        // `resolveSet` already plays the "candidate detected" sound once at the start of this
        // resolution — don't play it again here just because the set landed in the batch session.
        batchSession.add(legoSet, collectionStatus: collectionStatus)
        resumeScanning()
    }

    func importImage(_ cgImage: CGImage) {
        cancelAllDebounceTasks()
        isPaused = true
        state = .processing

        ocrScanner.recognizeText(in: cgImage) { [weak self] texts in
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

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !isPaused else { return }

        if let lastFrameProcessedAt,
           Date().timeIntervalSince(lastFrameProcessedAt) < frameProcessingInterval {
            return
        }
        lastFrameProcessedAt = Date()

        // Detect on a crop of just the reticle, rather than the full frame with a Vision
        // `regionOfInterest` — restricts "what's detected" to "what's aimed at", and any
        // resulting bounding box is then unambiguously relative to this same small image (see
        // `CameraController.croppedReticleImage`).
        guard let reticleImage = cameraController.croppedReticleImage(from: pixelBuffer, reticleSize: Self.reticleSize) else {
            return
        }

        ocrScanner.recognizeTextWithBoundingBoxes(in: reticleImage) { observations in
            let candidates = SetNumberExtractor.extractFromOCR(observations)
            if let first = candidates.first {
                self.scheduleResolution(for: first.setNum, reticleImage: reticleImage, detectionBox: first.boundingBox)
            }
        }
    }

    private func scheduleResolution(for setNum: String, reticleImage: CGImage, detectionBox: CGRect?) {
        if let lastDate = recentlyIdentifiedAt[setNum], Date().timeIntervalSince(lastDate) < 30 {
            return
        }

        // Capture the thumbnail once per candidate, not on every throttled frame while its
        // debounce is pending.
        if !candidateDetected {
            candidateThumbnail = cameraController.zoomedThumbnail(in: reticleImage, detectionBox: detectionBox)
        }
        candidateDetected = true
        debounceTasks[setNum]?.cancel()
        // Offline, there's no network round-trip to debounce against — resolving immediately
        // avoids flashing a misleading "Vérification..." label for 1.5s before falling back to
        // the offline catalogue/cache.
        guard NetworkMonitor.shared.isConnected else {
            debounceTasks[setNum] = nil
            Task { [weak self] in await self?.resolveSet(setNum) }
            return
        }
        debounceTasks[setNum] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.debounceTasks[setNum] = nil
            await self?.resolveSet(setNum)
        }
    }

    private func cancelAllDebounceTasks() {
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
    }

    /// Lifts the 30s anti-repeat lock set at the start of `resolveSet` — only called on a
    /// terminal failure (not found / error), where there's nothing on screen worth protecting
    /// from being immediately re-triggered, unlike a successful `.found`/offline match.
    private func clearIdentificationLock(for setNum: String) {
        recentlyIdentifiedAt[setNum] = nil
    }

    @MainActor
    private func resolveSet(_ setNum: String) async {
        let bypassBatch = forceDetailNextResolution
        forceDetailNextResolution = false
        // While batch-capturing, identification of one box must not hold up the next: don't pause
        // frame processing for it, so several boxes can resolve concurrently in the background.
        // Outside batch mode (or when explicitly opening a detail sheet) the camera still pauses
        // exactly as before, since there's only ever one in-flight resolution to wait on then.
        let isBatchCapturing = isBatchModeEnabled && !bypassBatch

        recentlyIdentifiedAt[setNum] = Date()
        if !isBatchCapturing {
            isPaused = true
        }
        candidateDetected = false
        ScanStatsStore.shared.recordScan()

        // Local to this resolution — not written to the published `lastFoundWas...` flags until
        // `presentFound` decides this is the one opening a detail sheet (see its doc comment).
        var foundWasFromCache = false
        var foundWasOffline = false

        if let cached = localRepository?.cachedSet(setNum: setNum) {
            foundWasFromCache = true
            presentFound(cached.asLegoSet(), cached.asCollectionStatus(), bypassBatch: bypassBatch, wasFromCache: true)
        } else if !isBatchCapturing {
            state = .processing
        }
        if playsFeedbackSounds {
            ScanFeedback.playCandidateDetectedSound()
        }

        // Skip the network round-trip (and its timeout) entirely when the device is known
        // offline — fall straight to the same offline-catalogue path the `catch` block below uses
        // for an actual `APIError.networkUnavailable`, instead of waiting to fail first.
        guard NetworkMonitor.shared.isConnected else {
            if !foundWasFromCache {
                if let offlineSet = OfflineCatalogStore.shared.lookup(setNum: setNum) {
                    foundWasOffline = true
                    presentFound(
                        offlineSet,
                        .unknown("Hors-ligne — statut collection et prix à rafraîchir une fois reconnecté"),
                        bypassBatch: bypassBatch,
                        wasOffline: true
                    )
                } else if !isBatchCapturing {
                    state = .error(APIError.networkUnavailable.errorDescription ?? "Erreur inconnue")
                    clearIdentificationLock(for: setNum)
                }
                if !isBatchCapturing {
                    isPaused = false
                }
            }
            return
        }

        do {
            let resolution = try await repository.resolveSet(setNum: setNum)
            switch resolution {
            case .found(let legoSet):
                presentFound(
                    legoSet,
                    await fetchCollectionStatus(for: legoSet.setNum),
                    bypassBatch: bypassBatch,
                    wasFromCache: foundWasFromCache,
                    wasOffline: foundWasOffline
                )
            case .ambiguous(let sets):
                state = .ambiguous(sets)
            case .notFound:
                // Some cached numbers (e.g. minifigs, "fig-…") can't be re-resolved through the
                // sets endpoint at all — don't let a live reconcile failure close a detail view
                // that was already showing valid cached data; just keep it as-is.
                if !foundWasFromCache, !isBatchCapturing {
                    state = .notFound
                    isPaused = false
                    // "Set non trouvé" isn't a reason to lock this set number out for 30s like a
                    // successful identification — the user is told to rescan right away, so let
                    // them, including rescanning the exact same box (e.g. after repositioning it).
                    clearIdentificationLock(for: setNum)
                }
            }
        } catch {
            if !foundWasFromCache {
                if case .networkUnavailable = error as? APIError,
                   let offlineSet = OfflineCatalogStore.shared.lookup(setNum: setNum) {
                    presentFound(
                        offlineSet,
                        .unknown("Hors-ligne — statut collection et prix à rafraîchir une fois reconnecté"),
                        bypassBatch: bypassBatch,
                        wasOffline: true
                    )
                } else if !isBatchCapturing {
                    state = .error((error as? APIError)?.errorDescription ?? "Erreur inconnue")
                    clearIdentificationLock(for: setNum)
                }
                if !isBatchCapturing {
                    isPaused = false
                }
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
