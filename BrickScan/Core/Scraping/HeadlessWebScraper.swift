import Foundation
import WebKit
import UIKit

/// Errors raised while loading a page or extracting data from it through
/// `HeadlessWebScraper`. Callers treat every case as a non-fatal, best-effort
/// failure: a price source that throws simply doesn't contribute a quote.
enum ScrapeError: Error {
    case navigationFailed(Error)
    case challengeUnsolved
    case notFound
    case parsingFailed
}

/// A single hidden `WKWebView` shared across price scrapers.
///
/// `URLSession` requests to sites like BrickLink or Amazon get a bare `403`
/// because they run a Cloudflare/bot-detection JS challenge before serving
/// the real page. `WKWebView` is a full WebKit engine: it executes that JS
/// and (for the non-interactive challenges these price pages use) clears it
/// on its own, same as Safari would. Reusing one instance lets the
/// `cf_clearance` cookie persist across calls in the same app session,
/// avoiding the challenge on subsequent requests to the same site.
@MainActor
// @unchecked: mutable state (`navigationContinuation`, `isBusy`, `waiters`)
// is only ever touched on the main actor, so cross-actor passing of the
// reference itself (e.g. as a struct's stored property) is safe.
final class HeadlessWebScraper: NSObject, @unchecked Sendable {
    static let shared = HeadlessWebScraper()

    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    // All scrapers share this one WKWebView, so only one `loadAndExtract`
    // call may drive it at a time — a second concurrent call would overwrite
    // `navigationContinuation` before the first one resumes and hang it
    // forever. Concurrent callers queue here instead of running interleaved.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        super.init()
        webView.navigationDelegate = self
        // A real iOS Safari UA: some anti-bot checks reject WKWebView's
        // default UA (which omits "Safari" in its version suffix).
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    }

    /// Loads `url`, waits until `readinessScript` evaluates truthy (use this
    /// to detect when a Cloudflare-style challenge has cleared and the real
    /// page is in the DOM), then runs `extractScript` and returns its
    /// (string) result. `extractScript` should end with a `JSON.stringify(...)`
    /// so the caller can decode a known shape.
    func loadAndExtract(
        url: URL,
        readinessScript: String,
        extractScript: String,
        timeout: TimeInterval = 20
    ) async throws -> String {
        await acquire()
        defer { release() }

        attachToKeyWindowIfNeeded()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.load(URLRequest(url: url))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let readyResult = try? await webView.evaluateJavaScript(readinessScript)
            if let ready = readyResult as? Bool, ready {
                let extracted = try await webView.evaluateJavaScript(extractScript)
                guard let json = extracted as? String, !json.isEmpty, json != "null" else {
                    throw ScrapeError.notFound
                }
                return json
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw ScrapeError.challengeUnsolved
    }

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isBusy = false
        }
    }

    /// The webview must be part of a window for its JS timers (the
    /// challenge page relies on `setTimeout`/`requestAnimationFrame`) to run
    /// reliably. It stays effectively invisible: 1x1 and almost transparent
    /// rather than `isHidden`, since a hidden view can have its rendering
    /// (and therefore its timers) paused by WebKit.
    private func attachToKeyWindowIfNeeded() {
        guard webView.superview == nil,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) else { return }
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        window.insertSubview(webView, at: 0)
    }
}

extension HeadlessWebScraper: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.navigationContinuation?.resume()
            self?.navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.navigationContinuation?.resume(throwing: ScrapeError.navigationFailed(error))
            self?.navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.navigationContinuation?.resume(throwing: ScrapeError.navigationFailed(error))
            self?.navigationContinuation = nil
        }
    }
}
