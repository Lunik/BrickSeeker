import Foundation

/// Minimal CSV parsing shared by `OfflineCatalogStore` (sets dump) and `ThemeNameStore`
/// (themes dump). Handles exactly what Rebrickable's dumps need — quoted fields containing
/// commas, and RFC 4180 escaped double quotes (`""` inside a quoted field is a literal `"`).
/// Newlines inside quoted fields are NOT supported; neither dump contains any, and supporting
/// them would force whole-file scanning instead of line splitting.
enum CSV {
    /// Decodes UTF-8 `data` into records (one `[String]` of fields per line), dropping the
    /// header row. Throws `APIError.decodingError` if the data isn't valid UTF-8.
    ///
    /// Lines are split with `Character.isNewline`, NOT `split(separator: "\n")`: the real dumps
    /// use CRLF line endings, and Swift's `Character` treats "\r\n" as a single indivisible
    /// grapheme cluster that never equals a lone "\n" — that split found zero line breaks
    /// against a real download (the whole file became "one line"), silently producing 0 parsed
    /// rows with no error.
    static func records(in data: Data) throws -> [[String]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError(CocoaError(.fileReadCorruptFile))
        }
        var records: [[String]] = []
        var lines = text.split(whereSeparator: { $0.isNewline }).makeIterator()
        _ = lines.next() // header
        while let line = lines.next() {
            records.append(splitLine(String(line)))
        }
        return records
    }

    /// Splits one CSV line into fields, un-escaping RFC 4180 doubled quotes: a set name
    /// containing `"` arrives in the dump as `"…""…"` and must come out as `…"…`, not have its
    /// quotes silently dropped.
    static func splitLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\"" {
                let next = line.index(after: index)
                if insideQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = next // consume the second quote of the escaped pair too
                } else {
                    insideQuotes.toggle()
                }
            } else if char == ",", !insideQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }
}
