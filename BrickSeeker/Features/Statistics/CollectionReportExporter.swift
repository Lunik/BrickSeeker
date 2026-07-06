import Foundation
import UIKit

/// Generates a CSV/PDF inventory report from the cached collection — pure, offline, no
/// network calls (#15). Writes to a temp file since `ShareLink(item:)` needs a `URL`.
enum CollectionReportExporter {
    private static let frenchDateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "fr_FR"))

    /// `priceEUR` is the same lego.com → Amazon → BrickLink-used fallback chain used for the
    /// collection's total value (`StatisticsViewModel.effectivePriceEUR`) — passed in rather than
    /// reading `CachedSet.storePriceEUR` directly, so a set the LEGO store no longer carries
    /// still shows a price here if Amazon/BrickLink has one cached.
    static func csv(for sets: [CachedSet], priceEUR: (CachedSet) -> Double?) -> String {
        var lines = ["Numéro de set;Nom;Année;Pièces;Quantité;Prix (EUR)"]
        for set in sets {
            let price = priceEUR(set).map { String(format: "%.2f", $0) } ?? ""
            let name = set.name.replacingOccurrences(of: ";", with: ",")
            lines.append("\(set.setNum);\(name);\(set.year);\(set.numParts);\(set.quantity);\(price)")
        }
        return lines.joined(separator: "\n")
    }

    static func writeCSVToTempFile(sets: [CachedSet], priceEUR: (CachedSet) -> Double?) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("collection-brickseeker.csv")
        do {
            try csv(for: sets, priceEUR: priceEUR).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func writePDFToTempFile(
        sets: [CachedSet],
        stats: CollectionStats,
        priceEUR: (CachedSet) -> Double?,
        lastSyncedAt: Date?,
        lastPriceUpdateAt: Date?
    ) -> URL? {
        let data = pdf(for: sets, stats: stats, priceEUR: priceEUR, lastSyncedAt: lastSyncedAt, lastPriceUpdateAt: lastPriceUpdateAt)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("collection-brickseeker.pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func pdf(for sets: [CachedSet], stats: CollectionStats, priceEUR: (CachedSet) -> Double?, lastSyncedAt: Date?, lastPriceUpdateAt: Date?) -> Data {
        let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 @ 72dpi
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)

        return renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = 36
            let margin: CGFloat = 36
            let contentWidth = pageBounds.width - margin * 2

            func draw(_ text: String, font: UIFont, color: UIColor = .black, spacingAfter: CGFloat = 4) {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let rect = CGRect(x: margin, y: y, width: contentWidth, height: 1000)
                let bounding = (text as NSString).boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: .usesLineFragmentOrigin,
                    attributes: attributes,
                    context: nil
                )
                (text as NSString).draw(in: CGRect(x: rect.minX, y: rect.minY, width: contentWidth, height: bounding.height), withAttributes: attributes)
                y += bounding.height + spacingAfter
            }

            draw("Inventaire de collection BrickSeeker", font: .boldSystemFont(ofSize: 20), spacingAfter: 12)
            draw("Relevé du \(Date().formatted(frenchDateStyle))", font: .systemFont(ofSize: 11), color: .darkGray)
            if let lastSyncedAt {
                draw("Dernière synchronisation collection : \(lastSyncedAt.formatted(frenchDateStyle))", font: .systemFont(ofSize: 11), color: .darkGray)
            }
            if let lastPriceUpdateAt {
                draw("Dernière actualisation des prix : \(lastPriceUpdateAt.formatted(frenchDateStyle))", font: .systemFont(ofSize: 11), color: .darkGray)
            }
            y += 8

            draw("Totaux", font: .boldSystemFont(ofSize: 14), spacingAfter: 8)
            draw("\(stats.setCount) sets · \(stats.partCount) pièces · \(stats.themeCount) thèmes", font: .systemFont(ofSize: 12))
            let valueText = String(format: "Valeur estimée : %.2f € (basée sur %d / %d sets dont le prix est connu)", stats.totalValueEUR, stats.setsWithKnownPrice, stats.setCount)
            draw(valueText, font: .systemFont(ofSize: 12), spacingAfter: 16)

            draw("Détail des sets", font: .boldSystemFont(ofSize: 14), spacingAfter: 8)
            for set in sets {
                let priceText = priceEUR(set).map { String(format: "%.2f €", $0) } ?? "—"
                let line = "\(set.setNum) — \(set.name) (\(set.year)) — \(set.numParts) pièces × \(set.quantity) — \(priceText)"
                draw(line, font: .systemFont(ofSize: 10), spacingAfter: 3)
                if y > pageBounds.height - 60 {
                    context.beginPage()
                    y = 36
                }
            }

            y += 12
            draw(
                "Valeurs estimées à titre indicatif (prix lego.com, ou Amazon/BrickLink occasion si indisponible chez LEGO). BrickSeeker n'est pas affilié au LEGO Group.",
                font: .italicSystemFont(ofSize: 9),
                color: .gray
            )
        }
    }
}
