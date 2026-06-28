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

    /// The reticle's frame, in the buffer's own top-left-origin normalized coordinate space —
    /// shared by `visionRegionOfInterest` (which flips it to Vision's bottom-left convention)
    /// and `croppedReticleImage` (which scales it to pixel coordinates), so both stay in sync
    /// with whatever the preview layer's aspect-fill geometry is doing.
    private func normalizedReticleRect(forReticleSize reticleSize: CGSize) -> CGRect? {
        guard let previewLayer, previewLayer.bounds.width > 0, previewLayer.bounds.height > 0 else { return nil }
        let bounds = previewLayer.bounds
        let reticleRect = CGRect(
            x: (bounds.width - reticleSize.width) / 2,
            y: (bounds.height - reticleSize.height) / 2,
            width: reticleSize.width,
            height: reticleSize.height
        )
        return previewLayer.metadataOutputRectConverted(fromLayerRect: reticleRect)
    }

    /// Normalized region of interest for `VNDetectBarcodesRequest`/`VNRecognizeTextRequest`,
    /// restricting detection to the on-screen reticle so "what's aimed at" matches "what's
    /// detected" — see issue #32. Vision uses a bottom-left origin, unlike the top-left origin
    /// `metadataOutputRectConverted` returns, so the y axis is flipped here.
    func visionRegionOfInterest(forReticleSize reticleSize: CGSize) -> CGRect? {
        guard let topLeftROI = normalizedReticleRect(forReticleSize: reticleSize) else { return nil }
        let visionROI = CGRect(
            x: topLeftROI.minX,
            y: 1 - topLeftROI.minY - topLeftROI.height,
            width: topLeftROI.width,
            height: topLeftROI.height
        )
        let clamped = visionROI.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clamped.isNull || clamped.isEmpty ? nil : clamped
    }

    /// Crops the current frame to the "what was just detected" thumbnail shown in
    /// `ScanOverlayView`. When `detectionBox` is given (the barcode/text observation's own
    /// bounding box, in Vision's normalized bottom-left-origin full-image space), it zooms to
    /// that exact region — padded a little since a tight box often clips its own edges — instead
    /// of the whole reticle, so the thumbnail matches what was actually read rather than
    /// everything around it.
    func croppedReticleImage(
        from pixelBuffer: CVPixelBuffer,
        reticleSize: CGSize,
        detectionBox: CGRect? = nil
    ) -> UIImage? {
        guard let topLeftROI = normalizedReticleRect(forReticleSize: reticleSize) else { return nil }

        let topLeftCropNormalized: CGRect
        if let detectionBox {
            let flipped = CGRect(
                x: detectionBox.minX,
                y: 1 - detectionBox.minY - detectionBox.height,
                width: detectionBox.width,
                height: detectionBox.height
            )
            topLeftCropNormalized = flipped.insetBy(dx: -flipped.width * 0.25, dy: -flipped.height * 0.25)
        } else {
            topLeftCropNormalized = topLeftROI
        }

        let imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let cropRect = CGRect(
            x: topLeftCropNormalized.minX * imageWidth,
            y: topLeftCropNormalized.minY * imageHeight,
            width: topLeftCropNormalized.width * imageWidth,
            height: topLeftCropNormalized.height * imageHeight
        ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard !cropRect.isEmpty else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: cropRect)
        guard let cgImage = ciContext.createCGImage(ciImage, from: cropRect) else { return nil }
        return UIImage(cgImage: cgImage)
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
