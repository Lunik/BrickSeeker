import Vision
import CoreImage

final class OCRScanner {
    /// Each box is in Vision's normalized, bottom-left-origin coordinate space relative to
    /// whatever image was actually handed to this call (e.g. an already-cropped reticle frame).
    func recognizeText(
        in pixelBuffer: CVPixelBuffer,
        completion: @escaping ([(text: String, boundingBox: CGRect)]) -> Void
    ) {
        perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]), completion: completion)
    }

    func recognizeTextWithBoundingBoxes(
        in cgImage: CGImage,
        completion: @escaping ([(text: String, boundingBox: CGRect)]) -> Void
    ) {
        perform(VNImageRequestHandler(cgImage: cgImage, options: [:]), completion: completion)
    }

    func recognizeText(in cgImage: CGImage, completion: @escaping ([String]) -> Void) {
        recognizeTextWithBoundingBoxes(in: cgImage) { observations in
            completion(observations.map(\.text))
        }
    }

    private func perform(
        _ handler: VNImageRequestHandler,
        completion: @escaping ([(text: String, boundingBox: CGRect)]) -> Void
    ) {
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let results = request.results as? [VNRecognizedTextObservation] else {
                completion([])
                return
            }
            let candidates = results.compactMap { observation -> (text: String, boundingBox: CGRect)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (text, observation.boundingBox)
            }
            completion(candidates)
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "fr-FR"]
        request.usesLanguageCorrection = false

        do {
            try handler.perform([request])
        } catch {
            completion([])
        }
    }
}
