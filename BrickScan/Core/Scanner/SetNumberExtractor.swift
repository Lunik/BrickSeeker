import Foundation
import CoreGraphics

enum SetNumberExtractor {

    private static let setNumberRegex = try! NSRegularExpression(
        pattern: #"\b(\d{4,6})(-\d{1,2})?\b"#
    )
    private static let labeledRegex = try! NSRegularExpression(
        pattern: #"(?:Set No\.?|Art\.?\s?Nr\.?)\s*(\d{4,6})"#,
        options: .caseInsensitive
    )

    private static let phoneNumberRegex = try! NSRegularExpression(
        pattern: #"\b\d{1,3}-\d{3}-\d{3}-\d{4}\b"#
    )

    static func extractFromOCR(_ candidates: [String]) -> [String] {
        var results: [String] = []

        for text in candidates {
            if phoneNumberRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                continue
            }

            if let labeled = firstMatch(labeledRegex, in: text, group: 1) {
                if isPlausibleSetNumber(labeled) {
                    results.append(labeled)
                }
            }

            let matches = setNumberRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let numberRange = Range(match.range(at: 1), in: text) else { continue }
                let number = String(text[numberRange])
                guard isPlausibleSetNumber(number) else { continue }

                if match.range(at: 2).location != NSNotFound,
                   let suffixRange = Range(match.range(at: 2), in: text) {
                    results.append(number + String(text[suffixRange]))
                } else {
                    results.append(number)
                }
            }
        }

        return Array(orderedUnique(results))
    }

    /// Same extraction as `extractFromOCR(_:)`, but keeps each match paired with the bounding
    /// box of the text observation it came from — lets the caller zoom the candidate thumbnail
    /// to the actual text region instead of the whole reticle (see #32).
    static func extractFromOCR(
        _ observations: [(text: String, boundingBox: CGRect)]
    ) -> [(setNum: String, boundingBox: CGRect)] {
        var results: [(setNum: String, boundingBox: CGRect)] = []
        var seen = Set<String>()

        for observation in observations {
            for setNum in extractFromOCR([observation.text]) where seen.insert(setNum).inserted {
                results.append((setNum, observation.boundingBox))
            }
        }

        return results
    }

    private static func isPlausibleSetNumber(_ number: String) -> Bool {
        guard let value = Int(number) else { return false }

        // Exclude years (covers historical and near-future LEGO releases).
        if number.count == 4, (1949...2035).contains(value) {
            return false
        }
        // Exclude full EAN-13 barcodes accidentally captured as text.
        if number.count >= 12 {
            return false
        }
        return true
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String, group: Int) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
