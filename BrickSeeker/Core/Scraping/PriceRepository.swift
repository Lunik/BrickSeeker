import Foundation

protocol PriceRepositoryProtocol: Sendable {
    /// Scrapes every price source for `legoSet` in parallel and returns
    /// whatever quotes succeeded. Never throws: a source that fails (CAPTCHA,
    /// layout change, timeout) is silently dropped rather than failing the
    /// whole call, since one bad source shouldn't hide the others.
    func fetchPrices(for legoSet: LegoSet) async -> [PriceQuote]
}

struct PriceRepository: PriceRepositoryProtocol {
    private let brickLinkRepository: BrickLinkPriceRepository
    private let amazonScraper: AmazonPriceScraper

    init(
        brickLinkRepository: BrickLinkPriceRepository = BrickLinkPriceRepository(),
        amazonScraper: AmazonPriceScraper = AmazonPriceScraper()
    ) {
        self.brickLinkRepository = brickLinkRepository
        self.amazonScraper = amazonScraper
    }

    func fetchPrices(for legoSet: LegoSet) async -> [PriceQuote] {
        guard await NetworkMonitor.shared.isConnected else { return [] }

        return await withTaskGroup(of: [PriceQuote].self) { group in
            group.addTask {
                (try? await brickLinkRepository.fetchPrices(for: legoSet)) ?? []
            }
            group.addTask {
                if let quote = try? await amazonScraper.fetchPrice(legoSet: legoSet) {
                    return [quote]
                }
                return []
            }

            var quotes: [PriceQuote] = []
            for await result in group {
                quotes.append(contentsOf: result)
            }
            return quotes
        }
    }
}
