import Vision
import CoreImage

final class OCRScanner {
    /// Each box is in Vision's normalized, bottom-left-origin coordinate space relative to the
    /// *whole* image — even when `regionOfInterest` restricts where recognition looks.
    func recognizeText(
        in pixelBuffer: CVPixelBuffer,
        regionOfInterest: CGRect? = nil,
        completion: @escaping ([(text: String, boundingBox: CGRect)]) -> Void
    ) {
        perform(
            VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]),
            regionOfInterest: regionOfInterest,
            completion: completion
        )
    }

    func recognizeText(in cgImage: CGImage, completion: @escaping ([String]) -> Void) {
        perform(VNImageRequestHandler(cgImage: cgImage, options: [:]), regionOfInterest: nil) { observations in
            completion(observations.map(\.text))
        }
    }

    private func perform(
        _ handler: VNImageRequestHandler,
        regionOfInterest: CGRect?,
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
        if let regionOfInterest {
            request.regionOfInterest = regionOfInterest
        }

        do {
            try handler.perform([request])
        } catch {
            completion([])
        }
    }
}
