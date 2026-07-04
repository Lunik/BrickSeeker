import Foundation

/// Parses a Rebrickable "sets" CSV export (the `?format=rbsetscsv` download from a custom list's
/// Sets tab, or any Rebrickable set-list CSV) into a flat list of set numbers.
///
/// The export itself is Cloudflare-gated the same way the rest of the site is, but unlike a page
/// load, a *file download* can't be driven through `HeadlessWebScraper` (WKWebView hands a CSV
/// response to the system download manager instead of rendering it, so there's no DOM to read it
/// back from) — see issue #6. Rather than reimplementing a download-and-intercept pipeline for
/// one file, the user downloads the CSV themselves (already an authenticated browser session) and
/// picks the file in the app; this only ever parses text the user explicitly chose from Files.
enum RebrickableSetsCSVParser {
    /// Matches a bare Rebrickable set number like "10307-1" in a field, tolerating surrounding
    /// quotes — targets the documented column convention ("Set Number,Quantity", see
    /// Rebrickable's own CSV-import help) by content shape rather than a specific header name, so
    /// minor column-order/naming variations between export flavors don't matter.
    private static let setNumRegex = try! NSRegularExpression(pattern: #"^"?(\d{3,7}-\d{1,2})"?$"#)

    /// Returns every distinct set number found in the first column of each row — skips the
    /// header row (it won't match the number pattern) and any other columns.
    static func parse(_ csvText: String) -> [String] {
        var setNums: [String] = []
        for rawLine in csvText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let firstField = line.split(separator: ",").first else { continue }
            let field = firstField.trimmingCharacters(in: .whitespaces)
            let range = NSRange(field.startIndex..., in: field)
            guard let match = setNumRegex.firstMatch(in: field, range: range),
                  let matchRange = Range(match.range(at: 1), in: field) else { continue }
            setNums.append(String(field[matchRange]))
        }
        return Array(Set(setNums)).sorted()
    }
}
