import Foundation
import AVFoundation
import Vision
import Observation

/// What to show in the live overlay for the CMF box code currently under the
/// camera. Resolution is purely local (bundled catalog lookup) while name and
/// photo require a network fetch of the figure's Rebrickable set.
enum MinifigOverlayResolution: Equatable {
    case loading
    case resolved(name: String, imgUrl: String?)
    case unresolved
}

struct MinifigOverlayState: Equatable {
    let boxCode: String
    var boundingBox: CGRect
    var resolution: MinifigOverlayResolution
}

/// Fired once per newly-detected (not merely re-tracked) minifig box code so
/// the view can persist it to history without re-writing on every frame.
struct DetectedMinifigRecord: Equatable {
    let boxCode: String
    let legoSet: LegoSet
    let collectionStatus: CollectionStatus
    let detectedAt: Date
}

struct UnresolvedBoxCodeEvent: Equatable {
    let boxCode: String
    let detectedAt: Date
}

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

    /// Live tracking overlay for a CMF box code currently under the camera.
    /// Updated every processed frame while a Data Matrix code is visible.
    var minifigOverlay: MinifigOverlayState?
    var lastDetectedMinifig: DetectedMinifigRecord?
    var lastUnresolvedBoxCode: UnresolvedBoxCodeEvent?

    let cameraController = CameraController()
    private let barcodeScanner = BarcodeScanner()
    private let ocrScanner = OCRScanner()
    private let repository: RebrickableRepositoryProtocol
    private let minifigCatalog: MinifigBoxCodeCatalog

    private var lastIdentifiedSetNum: String?
    private var lastIdentifiedAt: Date?
    private var debounceTask: Task<Void, Never>?
    private var isPaused = false

    private var lastFrameProcessedAt: Date?
    private let frameProcessingInterval: TimeInterval = 0.8

    /// The box code currently being tracked across consecutive frames. A new
    /// haptic + history entry only fires when this changes, so holding one
    /// box steady under the camera doesn't spam either.
    private var trackedBoxCode: String?
    private var framesSinceMinifigSeen = 0
    private var resolvedMinifigCache: [String: (legoSet: LegoSet, collectionStatus: CollectionStatus)] = [:]

    init(
        repository: RebrickableRepositoryProtocol = RebrickableRepository(),
        minifigCatalog: MinifigBoxCodeCatalog = .shared
    ) {
        self.repository = repository
        self.minifigCatalog = minifigCatalog
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
        state = .processing
        Task {
            await resolveSet(setNum)
        }
    }

    func selectAmbiguousSet(_ legoSet: LegoSet) {
        state = .processing
        Task {
            state = .found(legoSet, await fetchCollectionStatus(for: legoSet.setNum))
        }
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

        barcodeScanner.detectCodes(in: pixelBuffer) { [weak self] codes in
            guard let self else { return }

            if let minifigCode = codes.first(where: { $0.symbology == .dataMatrix }) {
                self.handleMinifigCode(minifigCode)
            } else {
                self.handleMinifigCodeMissing()
            }

            guard let setCode = codes.first(where: { $0.symbology != .dataMatrix }) else {
                self.ocrScanner.recognizeText(in: pixelBuffer) { texts in
                    let candidates = SetNumberExtractor.extractFromOCR(texts)
                    if let first = candidates.first {
                        self.scheduleResolution(for: first)
                    }
                }
                return
            }
            let candidate = SetNumberExtractor.extractFromBarcode(setCode.value)
            self.scheduleResolution(for: candidate)
        }
    }

    // MARK: - CMF minifig box code overlay

    private func handleMinifigCode(_ code: DetectedCode) {
        framesSinceMinifigSeen = 0
        let boxCode = code.value
        let previewRect = cameraController.convertToPreviewRect(code.boundingBox)

        if boxCode != trackedBoxCode {
            trackedBoxCode = boxCode
            minifigOverlay = MinifigOverlayState(
                boxCode: boxCode,
                boundingBox: previewRect ?? minifigOverlay?.boundingBox ?? .zero,
                resolution: .loading
            )
            ScanFeedback.playMinifigDetectedHaptic()
            resolveMinifig(boxCode: boxCode)
        } else if let previewRect {
            minifigOverlay?.boundingBox = previewRect
        }
    }

    private func handleMinifigCodeMissing() {
        guard trackedBoxCode != nil else { return }
        framesSinceMinifigSeen += 1
        // Tolerate one missed frame (motion blur, brief occlusion) before
        // dropping the overlay, so it doesn't flicker.
        if framesSinceMinifigSeen > 1 {
            trackedBoxCode = nil
            minifigOverlay = nil
            framesSinceMinifigSeen = 0
        }
    }

    private func resolveMinifig(boxCode: String) {
        guard let match = minifigCatalog.match(decodedValue: boxCode) else {
            minifigOverlay?.resolution = .unresolved
            lastUnresolvedBoxCode = UnresolvedBoxCodeEvent(boxCode: boxCode, detectedAt: Date())
            return
        }

        if let cached = resolvedMinifigCache[match.setNum] {
            applyResolvedMinifig(boxCode: boxCode, setNum: match.setNum, legoSet: cached.legoSet, collectionStatus: cached.collectionStatus)
            return
        }

        Task { @MainActor in
            do {
                let legoSet = try await repository.fetchSet(setNum: match.setNum)
                let collectionStatus = await fetchCollectionStatus(for: match.setNum)
                resolvedMinifigCache[match.setNum] = (legoSet, collectionStatus)
                applyResolvedMinifig(boxCode: boxCode, setNum: match.setNum, legoSet: legoSet, collectionStatus: collectionStatus)
            } catch {
                guard trackedBoxCode == boxCode else { return }
                minifigOverlay?.resolution = .unresolved
            }
        }
    }

    private func applyResolvedMinifig(boxCode: String, setNum: String, legoSet: LegoSet, collectionStatus: CollectionStatus) {
        // The user may have already moved on to a different box by the time
        // this network fetch completes.
        guard trackedBoxCode == boxCode else { return }
        minifigOverlay?.resolution = .resolved(name: legoSet.name, imgUrl: legoSet.setImgUrl)
        lastDetectedMinifig = DetectedMinifigRecord(boxCode: boxCode, legoSet: legoSet, collectionStatus: collectionStatus, detectedAt: Date())
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
        lastIdentifiedSetNum = setNum
        lastIdentifiedAt = Date()
        isPaused = true
        candidateDetected = false
        state = .processing
        ScanFeedback.playCandidateDetectedSound()

        do {
            let resolution = try await repository.resolveSet(setNum: setNum)
            switch resolution {
            case .found(let legoSet):
                state = .found(legoSet, await fetchCollectionStatus(for: legoSet.setNum))
            case .ambiguous(let sets):
                state = .ambiguous(sets)
            case .notFound:
                state = .notFound
                isPaused = false
            }
        } catch {
            state = .error((error as? APIError)?.errorDescription ?? "Erreur inconnue")
            isPaused = false
        }
    }

    private func fetchCollectionStatus(for setNum: String) async -> CollectionStatus {
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
