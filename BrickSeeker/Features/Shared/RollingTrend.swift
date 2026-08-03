import Foundation

/// A **rolling 12-month trend** computed from our own recorded history (#217) — the local
/// equivalent of BrickEconomy's `rolling_growth_12months`, with no forecast attached (the 1-year /
/// 5-year predictions are deliberately not reproduced, see #212).
///
/// This is a different quantity from `SetValuation.growthPercent`, and the UI must never mix the
/// two up:
/// - « Évolution depuis l'achat » = today's value vs the price **paid** (or retail) — `SetValuation`;
/// - « Tendance 12 mois » = today's value vs the value **a year ago** — this type.
///
/// Pure like `SetValuation`/`PriceComparison`: no repository, no `ModelContext`, no network. The
/// caller hands in rows it already read.
enum RollingTrend {
    enum Result: Equatable {
        /// `percent` measured against the reading taken at `since`, which is `months` old. `months`
        /// is **not** always 12: when the history doesn't reach a year back, the real window is
        /// reported instead so the label can say "sur 7 mois" rather than claim a year it doesn't
        /// have.
        case percent(Double, since: Date, months: Int)
        /// Not enough history to claim anything. `oldest` is the earliest reading we do have (nil
        /// when there is none at all), so the UI can say how far the history currently reaches.
        case insufficient(oldest: Date?)
    }

    /// Below this span, no trend at all: two months of readings on a set that was cached last week
    /// would otherwise produce a confident-looking percentage built on noise.
    static let minimumSpanDays = 60
    /// The window the base reading is looked for in — a year back, ±1 month, since readings are
    /// only taken when a price is actually fetched and nothing guarantees one landed on the exact
    /// anniversary.
    static let targetMonths = 12
    private static let windowStartMonths = -13
    private static let windowEndMonths = -11

    /// Trend for one set (or minifig), rebuilt from its `PriceHistoryEntry` rows.
    ///
    /// The history is **not** followed source by source. Which source wins changes from one day to
    /// the next (a lego.com price appearing or disappearing, an Amazon quote expiring), so tracking
    /// a single source manufactures jumps the collection never saw. Instead each day is rebuilt
    /// into the same inputs the rest of the app values a set from — a `[PriceQuote]` plus a
    /// `storePriceEUR` — and replayed through `resolveCollectionPrice`/`resolveMinifigPrice`. Same
    /// function as the header card, the Collection row and the Statistics total (#194's "one chain
    /// only" rule), so the trend cannot contradict the value displayed next to it.
    ///
    /// - Parameters:
    ///   - history: every recorded reading for one item, any source, any date.
    ///   - condition: the owning list's condition — the same input the header valuation uses.
    ///   - isMinifig: `String.isMinifig` for the item. Not in the original sketch of this API, but
    ///     required by the one-chain rule: a minifig is valued by `resolveMinifigPrice`, which
    ///     defaults to *used* where `resolveCollectionPrice` defaults to *new* (#203). Replaying
    ///     the wrong resolver would put a trend on screen that disagrees with the value above it.
    static func perSet(
        history: [PriceHistoryEntry],
        condition: ListCondition?,
        isMinifig: Bool = false,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Result {
        trend(
            from: resolvedDailyValues(history: history, condition: condition, isMinifig: isMinifig, calendar: calendar),
            now: now,
            calendar: calendar
        )
    }

    /// Trend for the whole collection, from the monthly snapshots of #216 — never a per-set replay
    /// summed up. The snapshots are the collection's recorded value; re-deriving a second answer
    /// from today's prices applied to yesterday's collection would produce a number the chart above
    /// it doesn't show.
    ///
    /// Thin-coverage months are skipped rather than used as either end: `CachedSetPrice` expires
    /// after 7 days, so a month nobody refreshed values the collection at a fraction of itself
    /// (which is exactly why the chart greys those points, see `CollectionValueSnapshot`). Reading a
    /// trend off one would invent a crash or a recovery that never happened.
    static func collection(
        snapshots: [CollectionValueSnapshot],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Result {
        let points = snapshots
            .filter { $0.coverage >= CollectionValueSnapshot.reliableCoverage && $0.totalValueEUR > 0 }
            .compactMap { snapshot -> Point? in
                guard let date = snapshot.monthStart(calendar: calendar) else { return nil }
                return Point(date: date, value: snapshot.totalValueEUR)
            }
            .sorted { $0.date < $1.date }
        return trend(from: points, now: now, calendar: calendar)
    }

    private struct Point {
        let date: Date
        let value: Double
    }

    /// One resolved value per day, oldest first. A day whose sources resolve to nothing is dropped
    /// rather than carried forward from the previous day — an invented flat line would read as "the
    /// price held" when in fact nothing was known.
    private static func resolvedDailyValues(
        history: [PriceHistoryEntry],
        condition: ListCondition?,
        isMinifig: Bool,
        calendar: Calendar
    ) -> [Point] {
        Dictionary(grouping: history) { calendar.startOfDay(for: $0.fetchedAt) }
            .compactMap { day, entries -> Point? in
                var storePriceEUR: Double?
                var quotes: [PriceQuote] = []
                // One row per set+source+day by construction (`recordPriceHistory`), but a device
                // clock change or a pre-existing duplicate must not double-count a source here —
                // the latest reading of the day wins.
                let latestBySource = Dictionary(grouping: entries, by: \.source)
                    .compactMapValues { $0.max(by: { $0.fetchedAt < $1.fetchedAt }) }
                for (source, entry) in latestBySource {
                    if source == legoStoreHistorySource {
                        storePriceEUR = (entry.amount as NSDecimalNumber).doubleValue
                    } else if let priceSource = PriceSource(rawValue: source) {
                        quotes.append(PriceQuote(
                            source: priceSource,
                            amount: entry.amount,
                            currency: entry.currency,
                            sourceURL: nil,
                            fetchedAt: entry.fetchedAt
                        ))
                    }
                }
                let value = isMinifig
                    ? resolveMinifigPrice(condition: condition, quotes: quotes)
                    : resolveCollectionPrice(storePriceEUR: storePriceEUR, condition: condition, quotes: quotes)
                guard let value, value > 0 else { return nil }
                return Point(date: day, value: value)
            }
            .sorted { $0.date < $1.date }
    }

    /// The shared arithmetic, once both series shapes have been reduced to dated values.
    ///
    /// Base selection, in order:
    /// 1. the **oldest** reading inside `[now−13 months, now−11 months]` → a genuine 12-month trend;
    /// 2. failing that (a gap around the anniversary), the **newest** reading at least 11 months
    ///    old — the closest thing to a year ago that exists — labelled with its real age;
    /// 3. failing that, the oldest reading of all, again labelled with its real age.
    ///
    /// Steps 2 and 3 never say "12 mois": a window we don't have must be named for what it is.
    private static func trend(from points: [Point], now: Date, calendar: Calendar) -> Result {
        guard let oldest = points.first, let latest = points.last, points.count >= 2 else {
            return .insufficient(oldest: points.first?.date)
        }
        let spanDays = calendar.dateComponents([.day], from: oldest.date, to: latest.date).day ?? 0
        guard spanDays >= minimumSpanDays else { return .insufficient(oldest: oldest.date) }

        let windowStart = calendar.date(byAdding: .month, value: windowStartMonths, to: now) ?? now
        let windowEnd = calendar.date(byAdding: .month, value: windowEndMonths, to: now) ?? now

        let base: Point
        let months: Int
        if let inWindow = points.first(where: { $0.date >= windowStart && $0.date <= windowEnd }) {
            base = inWindow
            months = targetMonths
        } else {
            base = points.last(where: { $0.date < windowEnd }) ?? oldest
            months = monthsBetween(base.date, and: now, calendar: calendar)
        }

        guard base.value > 0, base.date < latest.date else { return .insufficient(oldest: oldest.date) }
        return .percent((latest.value - base.value) / base.value * 100, since: base.date, months: months)
    }

    /// Whole months between two dates, rounding on the leftover days — 7 months and 3 weeks is "8
    /// mois", not "7". Never returns 0: the caller has already required a 60-day span, and a
    /// "tendance sur 0 mois" would be nonsense.
    private static func monthsBetween(_ from: Date, and to: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.month, .day], from: from, to: to)
        return max(1, (components.month ?? 0) + ((components.day ?? 0) >= 15 ? 1 : 0))
    }
}

extension RollingTrend.Result {
    /// "Tendance 12 mois" / "Tendance sur 7 mois" — the window is part of the label, never implied.
    /// The insufficient case still names the 12-month intent, since that's the figure the row is
    /// there to eventually show.
    var title: String {
        switch self {
        case .percent(_, _, let months) where months == RollingTrend.targetMonths:
            return "Tendance 12 mois"
        case .percent(_, _, let months):
            return "Tendance sur \(months) mois"
        case .insufficient:
            return "Tendance 12 mois"
        }
    }

    var percent: Double? {
        switch self {
        case .percent(let value, _, _): return value
        case .insufficient: return nil
        }
    }
}
