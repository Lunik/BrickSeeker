import Vision
import CoreImage

final class BarcodeScanner {
    private let symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .code128, .qr]

    /// `boundingBox` is in Vision's normalized, bottom-left-origin coordinate space relative to
    /// whatever image was actually handed to this call (e.g. an already-cropped reticle frame).
    func detectBarcode(in pixelBuffer: CVPixelBuffer, completion: @escaping (String?, CGRect?) -> Void) {
        perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]), completion: completion)
    }

    func detectBarcode(in cgImage: CGImage, completion: @escaping (String?, CGRect?) -> Void) {
        perform(VNImageRequestHandler(cgImage: cgImage, options: [:]), completion: completion)
    }

    private func perform(_ handler: VNImageRequestHandler, completion: @escaping (String?, CGRect?) -> Void) {
        let request = VNDetectBarcodesRequest { request, error in
            guard error == nil,
                  let results = request.results as? [VNBarcodeObservation],
                  let first = results.first(where: { $0.payloadStringValue != nil }) else {
                completion(nil, nil)
                return
            }
            completion(first.payloadStringValue, first.boundingBox)
        }
        request.symbologies = symbologies

        do {
            try handler.perform([request])
        } catch {
            completion(nil, nil)
        }
    }
}
