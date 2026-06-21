import Foundation

enum SetNumberExtractor {

    /// EAN-13/EAN-8 barcodes don't directly encode the LEGO set number.
    /// The caller should use the raw barcode value as a search key against
    /// the Rebrickable catalog (search, then try as a literal set_num).
    static func extractFromBarcode(_ value: String) -> String {
        value
    }

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
