import Vision
import CoreImage

/// A barcode/Data Matrix observation with its normalized bounding box, in
/// Vision's coordinate space (origin bottom-left, 0...1).
struct DetectedCode {
    let value: String
    let symbology: VNBarcodeSymbology
    let boundingBox: CGRect
}

final class BarcodeScanner {
    private let symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .code128, .qr, .dataMatrix]

    func detectBarcode(in pixelBuffer: CVPixelBuffer, completion: @escaping (String?) -> Void) {
        detectCodes(in: pixelBuffer) { completion($0.first?.value) }
    }

    func detectBarcode(in cgImage: CGImage, completion: @escaping (String?) -> Void) {
        detectCodes(in: cgImage) { completion($0.first?.value) }
    }

    func detectCodes(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .right,
        completion: @escaping ([DetectedCode]) -> Void
    ) {
        perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]), completion: completion)
    }

    func detectCodes(in cgImage: CGImage, completion: @escaping ([DetectedCode]) -> Void) {
        perform(VNImageRequestHandler(cgImage: cgImage, options: [:]), completion: completion)
    }

    private func perform(_ handler: VNImageRequestHandler, completion: @escaping ([DetectedCode]) -> Void) {
        let request = VNDetectBarcodesRequest { request, error in
            guard error == nil, let results = request.results as? [VNBarcodeObservation] else {
                completion([])
                return
            }
            let codes = results.compactMap { observation -> DetectedCode? in
                guard let value = observation.payloadStringValue else { return nil }
                return DetectedCode(value: value, symbology: observation.symbology, boundingBox: observation.boundingBox)
            }
            completion(codes)
        }
        request.symbologies = symbologies

        do {
            try handler.perform([request])
        } catch {
            completion([])
        }
    }
}
