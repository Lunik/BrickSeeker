import Compression
import Foundation

/// Manages the offline catalogue snapshot (`set_num → name/year/theme_id/num_parts/set_img_url`)
/// used so basic set identification still works with zero network — the typical "scanning in a
/// store with bad reception" case. Unlike the rest of the app's live data, this snapshot is
/// downloaded and refreshed by the user from Settings, not fetched per-request: it's a deliberate,
/// explicit "sync the offline fallback now" action, not something that happens silently in the
/// background. Storage is a single JSON file in Application Support (downloaded, not bundled —
/// there's nothing in the app bundle to fall back to until the user downloads it at least once).
///
/// Source is Rebrickable's public, unauthenticated `sets.csv.gz` dump (see
/// `Self.downloadURL`/`rebrickable.com/downloads/` — no API key needed, unlike the v3 API used
/// elsewhere in this app). Only static catalogue facts are stored — collection status and prices
/// are deliberately NOT part of this snapshot and stay live-only, same as everywhere else in the
/// app (see AGENTS.md).
///
/// `@unchecked Sendable` because `setsByNum`/`metadata` are only mutated from `@MainActor` call
/// sites (`download()`/`purge()`) and read-only elsewhere; there's no concurrent mutation.
final class OfflineCatalogStore: @unchecked Sendable {
    static let shared = OfflineCatalogStore()

    static let downloadURL = URL(string: "https://cdn.rebrickable.com/media/downloads/sets.csv.gz")!

    struct Metadata: Codable, Sendable {
        let setCount: Int
        let downloadedAt: Date
    }

    private let snapshotURL: URL
    private let metadataURL: URL
    private let resumeDataURL: URL

    /// Holds the in-flight download's `URLSession`/task/delegate alive for the duration of the
    /// download (a `URLSession` doesn't keep its own delegate or tasks alive on its own) and lets
    /// `cancelActiveDownloadPreservingProgress()` reach the right task to cancel.
    private var activeDownload: ActiveDownload?

    private(set) var setsByNum: [String: LegoSet]
    private(set) var metadata: Metadata?

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.snapshotURL = directory.appendingPathComponent("OfflineCatalogSnapshot.json")
        self.metadataURL = directory.appendingPathComponent("OfflineCatalogMetadata.json")
        self.resumeDataURL = directory.appendingPathComponent("OfflineCatalogResumeData")

        if let data = try? Data(contentsOf: snapshotURL),
           let sets = try? JSONDecoder().decode([LegoSet].self, from: data) {
            // `uniquingKeysWith`, not `uniqueKeysWithValues`: a duplicate set_num in the dump (or
            // a corrupted snapshot) must not crash at launch — first occurrence wins, matching
            // syncCollection's dedup rule.
            self.setsByNum = Dictionary(sets.map { ($0.setNum, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            self.setsByNum = [:]
        }
        if let data = try? Data(contentsOf: metadataURL) {
            self.metadata = try? JSONDecoder(dateDecodingStrategy: .iso8601).decode(Metadata.self, from: data)
        } else {
            self.metadata = nil
        }
    }

    /// Mirrors `RebrickableRepository.resolveSet`'s two-suffix lookup order: most set numbers
    /// encountered while scanning omit the "-1" variant suffix that Rebrickable's catalogue
    /// actually keys on, so the exact variant is tried first.
    func lookup(setNum: String) -> LegoSet? {
        setsByNum["\(setNum)-1"] ?? setsByNum[setNum]
    }

    var isEmpty: Bool { setsByNum.isEmpty }

    /// True once a download has stopped (network loss, or the app backgrounding mid-download via
    /// `cancelActiveDownloadPreservingProgress()`) and left resumable data on disk — the next
    /// `download()` call picks up from there instead of restarting from byte zero.
    var hasResumableDownload: Bool {
        FileManager.default.fileExists(atPath: resumeDataURL.path)
    }

    /// Downloads, decompresses and parses the latest `sets.csv.gz` dump, then replaces both the
    /// in-memory lookup table and the on-disk snapshot. Resumes from `resumeDataURL` if a previous
    /// attempt left resume data there (network loss or `cancelActiveDownloadPreservingProgress()`).
    /// `progress` is called repeatedly with `0...1` on the main actor. Throws
    /// `APIError.networkUnavailable` on connectivity failure or cancellation (mirroring
    /// `NetworkClient`'s error so callers can show the same messaging) — resume data for a
    /// retry is preserved on disk in that case, not cleared.
    ///
    /// Decompressing/parsing/encoding ~25k sets is genuine CPU work (seconds, not milliseconds, on
    /// a simulator) — it used to run directly in this `@MainActor` function and froze the UI for
    /// that whole stretch right after the progress bar hit 100%. `Task.detached` below moves it
    /// off the main actor entirely; only the final, already-built `sets`/`newMetadata` cross back.
    @MainActor
    func download(progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async throws {
        let downloadedFileURL = try await runDownloadTask(progress: progress)
        defer { try? FileManager.default.removeItem(at: downloadedFileURL) }

        let snapshotURL = self.snapshotURL
        let metadataURL = self.metadataURL
        let (sets, newMetadata) = try await Task.detached(priority: .userInitiated) {
            let compressedData = try Data(contentsOf: downloadedFileURL)
            let csv = try Self.gunzip(compressedData)
            let sets = try Self.parseCSV(csv)

            let snapshotData = try JSONEncoder().encode(sets)
            try snapshotData.write(to: snapshotURL, options: .atomic)

            let newMetadata = Metadata(setCount: sets.count, downloadedAt: Date())
            let metadataData = try JSONEncoder(dateEncodingStrategy: .iso8601).encode(newMetadata)
            try metadataData.write(to: metadataURL, options: .atomic)

            return (sets, newMetadata)
        }.value

        setsByNum = Dictionary(sets.map { ($0.setNum, $0) }, uniquingKeysWith: { first, _ in first })
        metadata = newMetadata
    }

    /// Stops the in-flight download without losing progress: `URLSessionTask.cancel(byProducingResumeData:)`
    /// hands back resume data (same mechanism as a network drop) that's persisted to
    /// `resumeDataURL`, so the next `download()` call — even after the app was fully relaunched —
    /// picks up roughly where this one stopped instead of starting over. Call this when the app is
    /// about to background/terminate mid-download (see `SettingsView`'s `scenePhase` observer);
    /// there's no way to react to a hard kill from the task switcher, only to backgrounding.
    @MainActor
    func cancelActiveDownloadPreservingProgress() {
        guard let activeDownload else { return }
        self.activeDownload = nil
        activeDownload.task.cancel { [weak self] resumeData in
            guard let resumeData else { return }
            Task { @MainActor in self?.persistResumeData(resumeData) }
        }
    }

    /// Deletes the downloaded snapshot and any in-progress resume data, reverting to "no offline
    /// fallback available" until the user downloads it again.
    @MainActor
    func purge() {
        cancelActiveDownloadPreservingProgress()
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: metadataURL)
        clearResumeData()
        setsByNum = [:]
        metadata = nil
    }

    // MARK: - Download task plumbing

    private struct ActiveDownload {
        let session: URLSession
        let task: URLSessionDownloadTask
        let delegate: DownloadDelegate
    }

    /// Errors surfaced by `DownloadDelegate`; `resumeData` (when present) is persisted by the
    /// caller before translating this into the public `APIError.networkUnavailable`.
    private enum DownloadTaskError: Error, Sendable {
        case failed(resumeData: Data?)
    }

    private func runDownloadTask(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let delegate = DownloadDelegate(
                    progressHandler: progress,
                    completionHandler: { [weak self] result in
                        Task { @MainActor in
                            self?.activeDownload = nil
                            switch result {
                            case .success(let url):
                                self?.clearResumeData()
                                continuation.resume(returning: url)
                            case .failure(let error):
                                if case .failed(let resumeData) = error, let resumeData {
                                    self?.persistResumeData(resumeData)
                                }
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                )
                let urlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task: URLSessionDownloadTask
                if let resumeData = loadResumeData() {
                    task = urlSession.downloadTask(withResumeData: resumeData)
                } else {
                    task = urlSession.downloadTask(with: Self.downloadURL)
                }
                self.activeDownload = ActiveDownload(session: urlSession, task: task, delegate: delegate)
                task.resume()
            }
        } catch is DownloadTaskError {
            throw APIError.networkUnavailable
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkUnavailable
        }
    }

    private func persistResumeData(_ data: Data) {
        try? data.write(to: resumeDataURL, options: .atomic)
    }

    private func loadResumeData() -> Data? {
        try? Data(contentsOf: resumeDataURL)
    }

    private func clearResumeData() {
        try? FileManager.default.removeItem(at: resumeDataURL)
    }

    /// Bridges `URLSessionDownloadTask`'s delegate-callback API (progress + completion) to the
    /// continuation in `runDownloadTask`. A plain `NSObject` delegate, not an actor — its
    /// callbacks land on an arbitrary `URLSession` delegate-queue thread, so every callback hops
    /// back to the main actor itself before touching anything (see call sites above).
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let progressHandler: @MainActor @Sendable (Double) -> Void
        private let completionHandler: @Sendable (Result<URL, DownloadTaskError>) -> Void
        private var didComplete = false
        /// `didWriteData` can fire hundreds of times a second on a fast connection — without this,
        /// every single call spawned its own `Task { @MainActor in ... }`, flooding the main
        /// actor's task queue badly enough to make the whole app appear frozen for the download's
        /// duration. Only hopping to the main actor when the reported percentage actually moves
        /// keeps that down to ~100 hops total regardless of chunk count. Mutated only from this
        /// delegate's callback methods, which `URLSession` always serializes onto its (single,
        /// non-concurrent) delegate queue — never read/written concurrently despite no lock.
        private var lastReportedFraction: Double = -1

        init(
            progressHandler: @escaping @MainActor @Sendable (Double) -> Void,
            completionHandler: @escaping @Sendable (Result<URL, DownloadTaskError>) -> Void
        ) {
            self.progressHandler = progressHandler
            self.completionHandler = completionHandler
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            guard value - lastReportedFraction >= 0.01 || value >= 1 else { return }
            lastReportedFraction = value
            let handler = progressHandler
            Task { @MainActor in handler(value) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            didComplete = true
            // `location` is deleted as soon as this method returns — move it out first.
            let movedURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gz")
            do {
                try FileManager.default.moveItem(at: location, to: movedURL)
                completionHandler(.success(movedURL))
            } catch {
                completionHandler(.failure(.failed(resumeData: nil)))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !didComplete, let error else { return }
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            completionHandler(.failure(.failed(resumeData: resumeData)))
        }
    }

    // MARK: - gzip / CSV parsing

    /// Strips the gzip container (10-byte fixed header plus optional FEXTRA/FNAME/FCOMMENT/FHCRC
    /// fields, then an 8-byte CRC32+size trailer) and inflates the raw deflate payload via
    /// Apple's `Compression` framework's one-shot `compression_decode_buffer`. `COMPRESSION_ZLIB`
    /// in that framework is, despite the name, the raw deflate algorithm with no zlib/gzip framing
    /// of its own — exactly what's left once the gzip wrapper is removed.
    ///
    /// Deliberately NOT using the streaming `compression_stream_process` API here — verified by
    /// hand against a real `sets.csv.gz` download that it returns `COMPRESSION_STATUS_ERROR`
    /// immediately when fed the whole buffer in one call (even with `COMPRESSION_STREAM_FINALIZE`
    /// passed on every iteration, which is the standard "I have the entire input already" idiom).
    /// The one-shot buffer API decodes the exact same bytes correctly, so stick with it — there's
    /// no streaming need anyway since the whole compressed file is already in memory.
    static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else {
            throw APIError.decodingError(CocoaError(.fileReadCorruptFile))
        }
        let flags = data[data.startIndex + 3]
        var offset = 10
        // Every header read below is bounds-checked against `limit` before touching the byte:
        // `Data`'s subscript traps (not throws) past `endIndex`, and a truncated/corrupt download
        // must surface as a thrown decoding error the UI can show — never a crash (same
        // philosophy as the unaligned-ISIZE fix documented below). The last 8 bytes are the
        // CRC32+ISIZE trailer, so no header field may reach into them.
        let limit = data.count - 8

        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= limit else {
                throw APIError.decodingError(CocoaError(.fileReadCorruptFile))
            }
            let xlen = Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < limit, data[data.startIndex + offset] != 0 { offset += 1 }
            guard offset < limit else { // no NUL terminator before the trailer
                throw APIError.decodingError(CocoaError(.fileReadCorruptFile))
            }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < limit, data[data.startIndex + offset] != 0 { offset += 1 }
            guard offset < limit else {
                throw APIError.decodingError(CocoaError(.fileReadCorruptFile))
            }
            offset += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }
        guard offset <= limit else {
            throw APIError.decodingError(CocoaError(.fileReadCorruptFile))
        }

        let payload = data.subdata(in: (data.startIndex + offset)..<(data.endIndex - 8))

        // The gzip trailer's last 4 bytes are ISIZE: the uncompressed size mod 2^32 (RFC 1952),
        // little-endian — an exact, reliable buffer size for a single-shot decode, no
        // growable-buffer loop needed. Built byte-by-byte rather than via `load(as: UInt32.self)`:
        // `data.suffix(4)`'s offset into the underlying buffer isn't guaranteed 4-byte aligned,
        // and `UnsafeRawBufferPointer.load` traps (not throws) on unaligned access — confirmed by
        // crashing exactly here against a real download (`EXC_BREAKPOINT` at this line).
        let isizeBytes = Array(data.suffix(4))
        let uncompressedSize =
            UInt32(isizeBytes[0]) | (UInt32(isizeBytes[1]) << 8) | (UInt32(isizeBytes[2]) << 16) | (UInt32(isizeBytes[3]) << 24)
        let dstCapacity = Int(uncompressedSize)
        guard dstCapacity > 0 else {
            throw APIError.decodingError(CocoaError(.fileReadCorruptFile))
        }
        var dstBuffer = [UInt8](repeating: 0, count: dstCapacity)

        let written = payload.withUnsafeBytes { srcRaw -> Int in
            guard let srcPointer = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dstBuffer.withUnsafeMutableBufferPointer { dstPointer -> Int in
                compression_decode_buffer(
                    dstPointer.baseAddress!, dstCapacity,
                    srcPointer, payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written == dstCapacity else {
            throw APIError.decodingError(CocoaError(.fileReadCorruptFile))
        }
        return Data(dstBuffer)
    }

    /// Parses the `set_num,name,year,theme_id,num_parts,img_url` columns Rebrickable's dump
    /// publishes into `LegoSet` (`set_img_url` here is renamed from the dump's `img_url`).
    /// Line splitting and RFC 4180 quote handling live in the shared `CSV` helper (also used by
    /// `ThemeNameStore`) — see its doc comments for the CRLF gotcha found against a real dump.
    static func parseCSV(_ data: Data) throws -> [LegoSet] {
        var sets: [LegoSet] = []
        for fields in try CSV.records(in: data) {
            guard fields.count >= 6,
                  let year = Int(fields[2]),
                  let themeId = Int(fields[3]),
                  let numParts = Int(fields[4])
            else { continue }

            let imgURL = fields[5].isEmpty ? nil : fields[5]
            sets.append(
                LegoSet(
                    setNum: fields[0],
                    name: fields[1],
                    year: year,
                    themeId: themeId,
                    numParts: numParts,
                    setImgUrl: imgURL,
                    setUrl: nil
                )
            )
        }
        return sets
    }
}

private extension JSONDecoder {
    convenience init(dateDecodingStrategy: JSONDecoder.DateDecodingStrategy) {
        self.init()
        self.dateDecodingStrategy = dateDecodingStrategy
    }
}

private extension JSONEncoder {
    convenience init(dateEncodingStrategy: JSONEncoder.DateEncodingStrategy) {
        self.init()
        self.dateEncodingStrategy = dateEncodingStrategy
    }
}
