import Foundation

/// Best-effort parsing of a price string scraped from a web page (e.g.
/// `"EUR 22.50"`, `"€22,50"`, `"$22.50"`) into an amount and a currency code.
enum PriceParsing {
    static func amount(from raw: String) -> Decimal? {
        let cleaned = raw.replacingOccurrences(of: "\u{a0}", with: " ")
        guard let range = cleaned.range(of: #"[0-9]+(?:[.,][0-9]+)?"#, options: .regularExpression) else {
            return nil
        }
        var numberString = String(cleaned[range])
        if numberString.contains(",") && !numberString.contains(".") {
            numberString = numberString.replacingOccurrences(of: ",", with: ".")
        } else {
            numberString = numberString.replacingOccurrences(of: ",", with: "")
        }
        return Decimal(string: numberString)
    }

    static func currency(from raw: String) -> String {
        if raw.contains("€") { return "EUR" }
        if raw.contains("$") { return "USD" }
        if raw.contains("£") { return "GBP" }
        if let match = raw.range(of: "[A-Z]{3}", options: .regularExpression) {
            return String(raw[match])
        }
        return "EUR"
    }
}
