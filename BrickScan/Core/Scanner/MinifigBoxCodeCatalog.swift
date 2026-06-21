import Foundation

/// A single entry decoded from a CMF box's Data Matrix code.
struct MinifigBoxCodeMatch: Equatable, Sendable {
    let setNum: String
    let name: String
}

/// Looks up the bundled community-sourced box code table (see
/// `scripts/generate_minifig_box_codes.py`). The code printed under a CMF box
/// is reported to end in a short numeric suffix that selects the figure from
/// a table that differs by packing region; since the region isn't encoded
/// anywhere we can read, ambiguous suffixes (shared by two regions) are
/// resolved by preferring the EU table.
struct MinifigBoxCodeCatalog: Sendable {
    static let shared = MinifigBoxCodeCatalog()

    private struct SeriesEntry: Decodable, Sendable {
        let name: String
        let regions: [String: [String: FigureEntry]]
    }

    private struct FigureEntry: Decodable, Sendable {
        let setNum: String
        let name: String
    }

    private static let regionPreferenceOrder = ["EU", "NA", "DK"]

    private let seriesByPrefix: [String: SeriesEntry]

    private init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "MinifigBoxCodes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: SeriesEntry].self, from: data) else {
            seriesByPrefix = [:]
            return
        }
        seriesByPrefix = decoded
    }

    /// Extracts the trailing suffix from a decoded Data Matrix payload and
    /// matches it against every known series/region table. Most regions use
    /// a two-digit suffix, but some (e.g. Denmark) carry on past 99 into a
    /// three-digit range, so the two-digit suffix is tried first and the
    /// three-digit one is tried as a fallback.
    func match(decodedValue: String) -> MinifigBoxCodeMatch? {
        for suffix in Self.candidateSuffixes(of: decodedValue) {
            for series in seriesByPrefix.values {
                for region in Self.regionPreferenceOrder {
                    if let entry = series.regions[region]?[suffix] {
                        return MinifigBoxCodeMatch(setNum: entry.setNum, name: entry.name)
                    }
                }
            }
        }
        return nil
    }

    private static func candidateSuffixes(of value: String) -> [String] {
        let trailingDigits = String(value.reversed().prefix(while: \.isNumber).reversed())
        guard trailingDigits.count >= 2 else { return [] }
        var suffixes = [String(trailingDigits.suffix(2))]
        if trailingDigits.count >= 3 {
            suffixes.append(String(trailingDigits.suffix(3)))
        }
        return suffixes
    }
}
