import SwiftUI
import AVFoundation

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.brickscan.camera.session")
    private var captureDevice: AVCaptureDevice?

    var onFrame: ((CVPixelBuffer) -> Void)?
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    /// Converts a Vision-space normalized bounding box (origin bottom-left,
    /// 0...1) into points within the preview layer, accounting for the
    /// `.resizeAspectFill` crop. Must be called on the main thread.
    func convertToPreviewRect(_ visionBoundingBox: CGRect) -> CGRect? {
        guard let previewLayer else { return nil }
        let topLeftNormalized = CGRect(
            x: visionBoundingBox.minX,
            y: 1 - visionBoundingBox.maxY,
            width: visionBoundingBox.width,
            height: visionBoundingBox.height
        )
        return previewLayer.layerRectConverted(fromMetadataOutputRect: topLeftNormalized)
    }

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
}

struct CameraPreviewView: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = controller.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        controller.previewLayer = view.videoPreviewLayer
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
