import Vision
import CoreImage

final class OCRScanner {
    func recognizeText(in pixelBuffer: CVPixelBuffer, completion: @escaping ([String]) -> Void) {
        perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]), completion: completion)
    }

    func recognizeText(in cgImage: CGImage, completion: @escaping ([String]) -> Void) {
        perform(VNImageRequestHandler(cgImage: cgImage, options: [:]), completion: completion)
    }

    private func perform(_ handler: VNImageRequestHandler, completion: @escaping ([String]) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let results = request.results as? [VNRecognizedTextObservation] else {
                completion([])
                return
            }
            let candidates = results.compactMap { $0.topCandidates(1).first?.string }
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
