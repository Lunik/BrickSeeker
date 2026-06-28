import SwiftUI
import AVFoundation
import CoreImage

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.brickscan.camera.session")
    private var captureDevice: AVCaptureDevice?
    /// Set by `CameraPreviewView` once the preview layer exists — used to map the on-screen
    /// reticle into the pixel buffer's own coordinate space for both the Vision region of
    /// interest and the candidate thumbnail crop, so "what's detected" and "what's shown" agree.
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private let ciContext = CIContext()

    var onFrame: ((CVPixelBuffer) -> Void)?

    func configure() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                self.session.commitConfiguration()
                return
            }
            self.captureDevice = device

            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }

            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            self.session.commitConfiguration()
        }
    }

    func start() {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func toggleTorch(on: Bool) {
        guard let device = captureDevice, device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
    }

    /// Crops the current frame down to the on-screen reticle, mapped through the preview layer's
    /// aspect-fill geometry into the pixel buffer's own coordinate space. Detection then runs on
    /// this small image directly (see `ScannerViewModel.handleFrame`) instead of passing the full
    /// frame with a Vision `regionOfInterest` — Vision's documented contract is that observation
    /// bounding boxes stay relative to the *whole* input image regardless of `regionOfInterest`,
    /// but that didn't hold up in practice (a detected text box came back pointing at the wrong
    /// spot in the full frame). Feeding Vision an already-cropped image sidesteps the
    /// ambiguity entirely: whatever bounding box it returns is unambiguously relative to this
    /// same small image, used as-is by `zoomedThumbnail`.
    func croppedReticleImage(from pixelBuffer: CVPixelBuffer, reticleSize: CGSize) -> CGImage? {
        guard let previewLayer, previewLayer.bounds.width > 0, previewLayer.bounds.height > 0 else { return nil }
        let bounds = previewLayer.bounds
        let reticleRect = CGRect(
            x: (bounds.width - reticleSize.width) / 2,
            y: (bounds.height - reticleSize.height) / 2,
            width: reticleSize.width,
            height: reticleSize.height
        )
        // Top-left-origin normalized rect in the buffer's own coordinate space.
        let topLeftROI = previewLayer.metadataOutputRectConverted(fromLayerRect: reticleRect)

        let imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let cropRect = CGRect(
            x: topLeftROI.minX * imageWidth,
            y: topLeftROI.minY * imageHeight,
            width: topLeftROI.width * imageWidth,
            height: topLeftROI.height * imageHeight
        ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard !cropRect.isEmpty else { return nil }

        // Vision/CGImage expect pixel data starting at (0,0); translate the crop back to origin.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        return ciContext.createCGImage(ciImage, from: CGRect(origin: .zero, size: cropRect.size))
    }

    /// Zooms `reticleImage` (the output of `croppedReticleImage`) to the exact text region
    /// Vision detected within it, padded a little since a tight bounding box often clips
    /// its own edges. Falls back to the unzoomed reticle image when there's no detection box yet.
    func zoomedThumbnail(in reticleImage: CGImage, detectionBox: CGRect?) -> UIImage {
        // The pixel buffer is delivered in the camera sensor's native landscape orientation — we
        // never rotate it via the capture connection — so it needs a quarter turn to read upright
        // against the portrait preview. `.right` tells UIImage to rotate the raw data 90° CW.
        guard let detectionBox else { return UIImage(cgImage: reticleImage, scale: 1, orientation: .right) }

        let width = CGFloat(reticleImage.width)
        let height = CGFloat(reticleImage.height)
        // Vision uses a bottom-left origin; CGImage cropping uses top-left — flip the y axis.
        let topLeftBox = CGRect(
            x: detectionBox.minX,
            y: 1 - detectionBox.minY - detectionBox.height,
            width: detectionBox.width,
            height: detectionBox.height
        ).insetBy(dx: -detectionBox.width * 0.25, dy: -detectionBox.height * 0.25)

        let pixelRect = CGRect(
            x: topLeftBox.minX * width,
            y: topLeftBox.minY * height,
            width: topLeftBox.width * width,
            height: topLeftBox.height * height
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))

        guard !pixelRect.isEmpty, let cropped = reticleImage.cropping(to: pixelRect) else {
            return UIImage(cgImage: reticleImage, scale: 1, orientation: .right)
        }
        return UIImage(cgImage: cropped, scale: 1, orientation: .right)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = controller.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        controller.attachPreviewLayer(view.videoPreviewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
}
