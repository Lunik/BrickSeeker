import Foundation
import WebKit
import UIKit

struct StorePrice: Equatable, Sendable {
    let amount: Double?
    let currency: String?
    let availability: String?
}

enum LegoStoreError: Error, LocalizedError {
    case timedOut
    case pageUnavailable
    case setNotOnStore

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Prix indisponible (lego.com n'a pas répondu)"
        case .pageUnavailable:
            return "Page lego.com indisponible"
        case .setNotOnStore:
            return "Ce set n'est plus sur lego.com"
        }
    }
}

protocol LegoStoreRepositoryProtocol: Sendable {
    func fetchStorePrice(setNum: String) async throws -> StorePrice
}

/// lego.com sits behind a Cloudflare Managed Challenge (confirmed via the `cf-mitigated: challenge`
/// response header and a "Just a moment..." interstitial) — no plain HTTP client (URLSession,
/// curl, httpx) can pass it regardless of headers/UA, since it requires executing the page's JS
/// like a real browser does. A hidden WKWebView is the workaround: it's a genuine WebKit engine,
/// so it solves the challenge the same way Safari would. See AGENTS.md before touching this.
/// `@unchecked Sendable` because WKWebView/UIApplication access is confined to the @MainActor
/// methods below — there's no other shared mutable state on this stateless utility class.
final class LegoStoreRepository: NSObject, LegoStoreRepositoryProtocol, @unchecked Sendable {
    private let pollInterval: UInt64 = 700_000_000
    private let timeout: TimeInterval = 25

    /// The product page URL shown to the user once a price has been confirmed — same path the
    /// scraper itself loads, so this never drifts from what was actually fetched.
    static func storeUrl(setNum: String) -> URL? {
        let productId = setNum.split(separator: "-").first.map(String.init) ?? setNum
        return URL(string: "https://www.lego.com/fr-fr/product/\(productId)")
    }

    @MainActor
    func fetchStorePrice(setNum: String) async throws -> StorePrice {
        guard let url = LegoStoreRepository.storeUrl(setNum: setNum) else {
            throw LegoStoreError.pageUnavailable
        }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        // Tracks the real HTTP status of the page once Cloudflare's challenge resolves and the
        // browser reloads — distinguishes "this set was removed from lego.com entirely" (404)
        // from "retired but the page still exists without a price" (handled in extractStorePrice).
        let statusObserver = StatusCodeObserver()
        webView.navigationDelegate = statusObserver

        // WKWebView has no real "headless" mode on iOS — content reliably loads/executes JS only
        // when the view is actually part of a window. Near-zero alpha keeps it invisible to the
        // user while staying "on screen" enough for the Cloudflare challenge to run normally.
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        window?.insertSubview(webView, at: 0)
        webView.alpha = 0.01
        defer { webView.removeFromSuperview() }

        webView.load(URLRequest(url: url))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: pollInterval)
            if webView.isLoading { continue }
            if statusObserver.lastStatusCode == 404 {
                throw LegoStoreError.setNotOnStore
            }
            if let price = try await extractStorePrice(from: webView) {
                return price
            }
        }
        throw LegoStoreError.timedOut
    }

    @MainActor
    private final class StatusCodeObserver: NSObject, WKNavigationDelegate {
        var lastStatusCode: Int?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let httpResponse = navigationResponse.response as? HTTPURLResponse {
                lastStatusCode = httpResponse.statusCode
            }
            decisionHandler(.allow)
        }
    }

    /// Returns nil while the page hasn't finished rendering real content yet (mid-challenge or
    /// mid-redirect) — callers should keep polling. `og:title` is used as the "page is ready"
    /// signal since it's present on every real product page regardless of retail status; a set
    /// with no `product:price:amount` once the title is present is a genuinely retired set.
    @MainActor
    private func extractStorePrice(from webView: WKWebView) async throws -> StorePrice? {
        let js = """
        (function() {
            const get = (prop) => {
                const el = document.querySelector(`meta[property="${prop}"]`);
                return el ? el.getAttribute('content') : null;
            };
            return JSON.stringify({
                title: get('og:title'),
                amount: get('product:price:amount'),
                currency: get('product:price:currency'),
                availability: get('product:availability')
            });
        })();
        """
        guard let jsonString = try await webView.evaluateJavaScript(js) as? String,
              let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MetaTagsPayload.self, from: data),
              payload.title != nil
        else {
            return nil
        }
        return StorePrice(
            amount: payload.amount.flatMap(Double.init),
            currency: payload.currency,
            availability: payload.availability
        )
    }

    private struct MetaTagsPayload: Decodable {
        let title: String?
        let amount: String?
        let currency: String?
        let availability: String?
    }
}
