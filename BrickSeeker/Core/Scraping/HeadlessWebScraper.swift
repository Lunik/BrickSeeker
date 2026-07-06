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
    /// The target page itself returned HTTP 404 (seen via `decidePolicyFor navigationResponse`,
    /// i.e. the *post-challenge* real response) — distinct from a challenge that never cleared.
    /// Only thrown when the caller opts in via `failsOnHTTP404`; the price scrapers keep their
    /// historical "any failure = no quote" behavior.
    case httpNotFound
}

/// Drives hidden `WKWebView`s to scrape sites behind a Cloudflare/bot-detection
/// JS challenge.
///
/// `URLSession` requests to sites like BrickLink or Amazon get a bare `403`
/// because they run a JS challenge before serving the real page. `WKWebView` is
/// a full WebKit engine: it executes that JS and (for the non-interactive
/// challenges these price pages use) clears it on its own, same as Safari would.
///
/// Each `loadAndExtract` call gets its *own* short-lived web view so independent
/// scrapes (BrickLink, Amazon, …) run truly in parallel — a single shared web
/// view could only drive one navigation at a time and forced callers to queue.
/// The web views all share one `WKProcessPool` and the default (persistent)
/// data store, so the `cf_clearance` cookie still persists across calls to the
/// same site, avoiding re-solving the challenge.
@MainActor
final class HeadlessWebScraper: @unchecked Sendable {
    static let shared = HeadlessWebScraper()

    private let processPool = WKProcessPool()

    /// Loads `url`, waits until `readinessScript` evaluates truthy (use this
    /// to detect when a Cloudflare-style challenge has cleared and the real
    /// page is in the DOM), then runs `extractScript` and returns its
    /// (string) result. `extractScript` should end with a `JSON.stringify(...)`
    /// so the caller can decode a known shape.
    ///
    /// `failsOnHTTP404`: when true, a 404 on the page's own response throws
    /// `ScrapeError.httpNotFound` immediately instead of polling to timeout —
    /// used by the lego.com price path, where "removed from the store" (404)
    /// and "retired but page still up" must stay distinguishable (see AGENTS.md).
    func loadAndExtract(
        url: URL,
        readinessScript: String,
        extractScript: String,
        timeout: TimeInterval = 20,
        failsOnHTTP404: Bool = false
    ) async throws -> String {
        let load = WebViewLoad(processPool: processPool)
        return try await load.run(
            url: url,
            readinessScript: readinessScript,
            extractScript: extractScript,
            timeout: timeout,
            failsOnHTTP404: failsOnHTTP404
        )
    }
}

/// One page load on a dedicated `WKWebView`. Owns its own navigation
/// continuation, so any number of these can be in flight at once. The instance
/// is kept alive for the load's duration by the `await` on `run`.
@MainActor
private final class WebViewLoad: NSObject {
    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    /// Status of the page's own HTTP response, captured in `decidePolicyFor navigationResponse`.
    /// Updated on every navigation response, so after a Cloudflare interstitial (403/503) it ends
    /// up holding the real page's status once the challenge clears and the browser reloads.
    private var lastHTTPStatusCode: Int?

    init(processPool: WKProcessPool) {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // A real iOS Safari UA: some anti-bot checks reject WKWebView's
        // default UA (which omits "Safari" in its version suffix).
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    }

    func run(
        url: URL,
        readinessScript: String,
        extractScript: String,
        timeout: TimeInterval,
        failsOnHTTP404: Bool = false
    ) async throws -> String {
        attachToKeyWindowIfNeeded()
        defer { webView.removeFromSuperview() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.load(URLRequest(url: url))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if failsOnHTTP404, lastHTTPStatusCode == 404 {
                throw ScrapeError.httpNotFound
            }
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

    /// The web view must be part of a window for its JS timers (the challenge
    /// page relies on `setTimeout`/`requestAnimationFrame`) to run reliably. It
    /// stays effectively invisible: 1x1 and almost transparent rather than
    /// `isHidden`, since a hidden view can have its rendering (and therefore its
    /// timers) paused by WebKit.
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

extension WebViewLoad: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            Task { @MainActor [weak self] in
                self?.lastHTTPStatusCode = statusCode
            }
        }
        decisionHandler(.allow)
    }

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
