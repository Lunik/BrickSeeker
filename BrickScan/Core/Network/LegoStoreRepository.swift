import Foundation

struct StorePrice: Equatable, Sendable {
    let amount: Double?
    let currency: String?
    let availability: String?

    var status: StoreAvailabilityStatus {
        StoreAvailabilityStatus(rawValue: availability)
    }
}

/// Typed view of `StorePrice.availability`, the raw `product:availability` OpenGraph value.
/// Mapping confirmed against real lego.com pages (see #64): a `product:price:amount` can be
/// present alongside *any* of these statuses, including `.retired` — a retired set keeps
/// showing its last price, so the amount is never conditioned on this status (see AGENTS.md).
enum StoreAvailabilityStatus: Equatable, Sendable {
    case available
    case outOfStock
    case retired
    /// A value other than the three confirmed strings, or no value at all — shown neutrally
    /// rather than guessed at, since only "in stock"/"out of stock"/"retired" have been observed.
    case unknown

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "in stock": self = .available
        case "out of stock": self = .outOfStock
        case "retired": self = .retired
        default: self = .unknown
        }
    }
}

enum LegoStoreError: Error, LocalizedError {
    case timedOut
    case pageUnavailable
    case setNotOnStore
    case offline

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return String(localized: "Prix indisponible (lego.com n'a pas répondu)")
        case .pageUnavailable:
            return String(localized: "Page lego.com indisponible")
        case .setNotOnStore:
            return String(localized: "Ce set n'est plus sur lego.com")
        case .offline:
            return String(localized: "Hors-ligne")
        }
    }
}

protocol LegoStoreRepositoryProtocol: Sendable {
    func fetchStorePrice(setNum: String) async throws -> StorePrice
}

/// lego.com sits behind a Cloudflare Managed Challenge (confirmed via the `cf-mitigated: challenge`
/// response header and a "Just a moment..." interstitial) — no plain HTTP client (URLSession,
/// curl, httpx) can pass it regardless of headers/UA, since it requires executing the page's JS
/// like a real browser does. The page is driven through `HeadlessWebScraper` (the same hidden
/// WKWebView pipeline as the BrickLink/Amazon scrapers — one WKWebView code path in the app, #82):
/// readiness = the `og:title` meta present (absent on the challenge interstitial), extraction =
/// the OpenGraph price/availability metas. See AGENTS.md before touching this.
///
/// End-state semantics, all deliberately distinct (see AGENTS.md):
/// - price present → `StorePrice` with an amount;
/// - retired set (real page, no `product:price:amount`) → `StorePrice(amount: nil, …)`;
/// - removed from the store entirely (HTTP 404, e.g. 75019-1) → `.setNotOnStore`;
/// - challenge never cleared / page never became ready → `.timedOut`.
final class LegoStoreRepository: LegoStoreRepositoryProtocol, Sendable {
    private static let timeout: TimeInterval = 25

    /// The product page URL shown to the user once a price has been confirmed — same path the
    /// scraper itself loads, so this never drifts from what was actually fetched.
    static func storeUrl(setNum: String) -> URL? {
        let productId = setNum.split(separator: "-").first.map(String.init) ?? setNum
        return URL(string: "https://www.lego.com/fr-fr/product/\(productId)")
    }

    /// Building instructions page for a set, by product id (same id `storeUrl` derives). The page
    /// is a client-rendered SPA shell that returns HTTP 200 regardless of whether the set actually
    /// has instructions, so there's no way to check availability without a full web view — the
    /// link is always shown and lego.com handles the "no instructions" case itself.
    static func instructionsUrl(setNum: String) -> URL? {
        let productId = setNum.split(separator: "-").first.map(String.init) ?? setNum
        return URL(string: "https://www.lego.com/fr-fr/service/building-instructions/\(productId)")
    }

    /// Ready once `og:title` is present — it exists on every real product page regardless of
    /// retail status (the Cloudflare interstitial has none), so a ready page with no
    /// `product:price:amount` is a genuinely retired set, not a page still loading.
    private static let readinessScript = """
    (function() {
        const el = document.querySelector('meta[property="og:title"]');
        return !!el && el.getAttribute('content') !== null;
    })();
    """

    private static let extractScript = """
    (function() {
        const get = (prop) => {
            const el = document.querySelector(`meta[property="${prop}"]`);
            return el ? el.getAttribute('content') : null;
        };
        return JSON.stringify({
            amount: get('product:price:amount'),
            currency: get('product:price:currency'),
            availability: get('product:availability')
        });
    })();
    """

    @MainActor
    func fetchStorePrice(setNum: String) async throws -> StorePrice {
        guard let url = LegoStoreRepository.storeUrl(setNum: setNum) else {
            throw LegoStoreError.pageUnavailable
        }
        guard NetworkMonitor.shared.isConnected else {
            throw LegoStoreError.offline
        }

        let json: String
        do {
            json = try await HeadlessWebScraper.shared.loadAndExtract(
                url: url,
                readinessScript: Self.readinessScript,
                extractScript: Self.extractScript,
                timeout: Self.timeout,
                failsOnHTTP404: true
            )
        } catch ScrapeError.httpNotFound {
            throw LegoStoreError.setNotOnStore
        } catch ScrapeError.challengeUnsolved {
            throw LegoStoreError.timedOut
        } catch {
            throw LegoStoreError.pageUnavailable
        }

        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MetaTagsPayload.self, from: data) else {
            throw LegoStoreError.pageUnavailable
        }
        return StorePrice(
            amount: payload.amount.flatMap(Double.init),
            currency: payload.currency,
            availability: payload.availability
        )
    }

    private struct MetaTagsPayload: Decodable {
        let amount: String?
        let currency: String?
        let availability: String?
    }
}
