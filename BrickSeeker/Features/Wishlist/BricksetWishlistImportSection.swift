import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The "Importer depuis un fichier CSV" row in Réglages — issue #6's mass-import path. Rebrickable
/// gates its sets-CSV export behind the same Cloudflare challenge as the rest of the site, and
/// unlike a page load, a file *download* can't be driven through `HeadlessWebScraper` (there's no
/// DOM to read it back from — WKWebView hands it to the system download manager instead). Rather
/// than reimplementing a download-and-intercept pipeline for one file, the user downloads the CSV
/// themselves (already an authenticated browser session) and picks it here — see
/// `RebrickableSetsCSVParser`. Observes `BricksetWishlistImporter.shared` directly, same
/// convention as `CollectionPriceUpdateSection`/`CollectionPriceUpdater` — the singleton owns the
/// actual job, so progress survives Settings being dismissed and reopened mid-run.
struct BricksetWishlistImportSection: View {
    @Environment(\.modelContext) private var modelContext
    var bricksetRepository: BricksetRepositoryProtocol = BricksetRepository()
    var rebrickableRepository: RebrickableRepositoryProtocol = RebrickableRepository()

    @State private var showFileImporter = false
    @State private var errorMessage: String?
    @State private var summary: BricksetWishlistImporter.Summary?

    var body: some View {
        let importer = BricksetWishlistImporter.shared

        if importer.isRunning {
            ProgressView(value: Double(importer.done), total: Double(max(importer.total, 1)))
        }

        if importer.isRunning || importer.hasResumableImport {
            Text("\(importer.done) / \(importer.total) sets")
                .foregroundStyle(.secondary)
        }

        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(Color.brickDanger)
                .font(.footnote)
        }

        if let summary {
            summaryView(summary)
        }

        Button(buttonTitle) {
            if importer.hasResumableImport {
                Task { await runImport(setNums: []) }
            } else {
                guard KeychainService.shared.hasBricksetUserHash else {
                    errorMessage = String(localized: "Liez d'abord votre compte Brickset ci-dessus.")
                    return
                }
                errorMessage = nil
                showFileImporter = true
            }
        }
        .disabled(importer.isRunning)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            handlePickedFile(result)
        }
    }

    private var buttonTitle: String {
        let importer = BricksetWishlistImporter.shared
        if importer.isRunning {
            return String(localized: "Import en cours…")
        }
        if importer.hasResumableImport {
            return String(localized: "Reprendre l'import (\(importer.total - importer.done) restants)")
        }
        return String(localized: "Choisir un fichier CSV")
    }

    @ViewBuilder
    private func summaryView(_ summary: BricksetWishlistImporter.Summary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(summary.added) ajouté\(summary.added > 1 ? "s" : ""), \(summary.alreadyWanted) déjà dans la liste cadeaux")
            if !summary.notFoundOnBrickset.isEmpty {
                Text("Introuvables sur Brickset : \(summary.notFoundOnBrickset.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        errorMessage = nil
        summary = nil

        guard case .success(let url) = result else {
            errorMessage = String(localized: "Impossible de lire le fichier.")
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            errorMessage = String(localized: "Impossible de lire le fichier.")
            return
        }

        let setNums = RebrickableSetsCSVParser.parse(text)
        guard !setNums.isEmpty else {
            errorMessage = String(localized: "Aucun numéro de set trouvé dans ce fichier.")
            return
        }

        Task { await runImport(setNums: setNums) }
    }

    @MainActor
    private func runImport(setNums: [String]) async {
        errorMessage = nil
        summary = nil

        guard NetworkMonitor.shared.isConnected else {
            errorMessage = String(localized: "Connexion impossible. Vérifiez votre réseau.")
            return
        }

        do {
            let result = try await BricksetWishlistImporter.shared.start(
                setNums: setNums,
                repository: bricksetRepository
            )
            summary = result
            // Refreshes the per-set badges immediately instead of waiting for the next
            // launch/pull-to-refresh sync (`HomeViewModel.syncCollection`) to pick up the sets
            // just imported.
            if let wanted = try? await bricksetRepository.fetchWishlistSetNumbers() {
                await WishlistSync.apply(
                    wantedSetNums: wanted,
                    localRepository: LocalRepository(modelContext: modelContext),
                    rebrickableRepository: rebrickableRepository
                )
            }
        } catch is CancellationError {
            // View dismissed mid-import — not a real failure.
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = String(localized: "Import impossible. Vérifiez votre réseau.")
        }
    }
}
