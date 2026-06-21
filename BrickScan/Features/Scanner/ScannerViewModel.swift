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
        ScanFeedback.playCandidateDetectedSound()
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
