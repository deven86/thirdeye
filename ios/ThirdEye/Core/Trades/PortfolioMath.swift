import Foundation

/// Portfolio-level numbers built from trades + live prices. Per currency; conversion is optional and labelled.
nonisolated enum PortfolioMath {
    nonisolated struct Holding: Identifiable, Equatable {
        var id: UUID { trade.id }
        var trade: Trade
        var openQuantity: Double
        var averageEntry: Double
        var price: Double?
        var cost: Double              // open qty × avg entry
        var value: Double?            // open qty × price (exposure, also for shorts)
        var unrealized: Double?
        var openRisk: Double          // loss if the current stop is hit (0 once the stop protects the entry)
    }

    nonisolated struct CurrencySummary: Equatable {
        var currency: String
        var holdings: [Holding]
        var cost: Double
        var value: Double?            // nil while any price is missing
        var unrealized: Double?
        var realizedAllTime: Double
        var realizedThisMonth: Double
        var openRisk: Double
        var capital: Double?

        var openRiskPercentOfCapital: Double? {
            guard let capital, capital > 0 else { return nil }
            return openRisk / capital * 100
        }
    }

    static func holding(_ t: Trade, price: Double?) -> Holding? {
        guard t.status == .open else { return nil }
        let s = TradeMath.summary(t, lastPrice: price)
        guard s.openQuantity > 0, let avg = s.averageEntry else { return nil }
        let perUnitRisk = t.isLong ? avg - t.stopLoss : t.stopLoss - avg
        return Holding(trade: t, openQuantity: s.openQuantity, averageEntry: avg, price: price,
                       cost: s.openQuantity * avg, value: price.map { s.openQuantity * $0 },
                       unrealized: s.unrealized, openRisk: max(0, perUnitRisk) * s.openQuantity)
    }

    /// Realised P&L of each exit, dated — the basis for "this month" and the equity curve.
    /// Fees are charged on the day they were paid.
    static func realizedEvents(_ t: Trade) -> [(date: Date, amount: Double)] {
        let entries = t.fills.filter { $0.kind == .entry }
        let qty = entries.reduce(0) { $0 + $1.quantity }
        guard qty > 0 else { return t.fills.filter { $0.fees > 0 }.map { ($0.date, -$0.fees) } }
        let avg = entries.reduce(0) { $0 + $1.quantity * $1.price } / qty
        let dir: Double = t.isLong ? 1 : -1
        return t.fills.map { f in
            f.kind == .exit ? (f.date, dir * (f.price - avg) * f.quantity - f.fees) : (f.date, -f.fees)
        }
    }

    static func summaries(_ trades: [Trade], mode: TradeMode, prices: (Instrument) -> Double?,
                          capital: [String: Double], now: Date = Date()) -> [CurrencySummary] {
        let mine = trades.filter { $0.mode == mode && $0.status != .cancelled && $0.status != .upcoming }
        let monthStart = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        var out: [CurrencySummary] = []
        for currency in Set(mine.map(\.instrument.currency)).sorted() {
            let group = mine.filter { $0.instrument.currency == currency }
            let holdings = group.compactMap { holding($0, price: prices($0.instrument)) }
                .sorted { ($0.value ?? $0.cost) > ($1.value ?? $1.cost) }
            let events = group.flatMap(realizedEvents)
            let missingPrice = holdings.contains { $0.price == nil }
            out.append(CurrencySummary(
                currency: currency,
                holdings: holdings,
                cost: holdings.reduce(0) { $0 + $1.cost },
                value: missingPrice ? nil : holdings.reduce(0) { $0 + ($1.value ?? 0) },
                unrealized: missingPrice ? nil : holdings.reduce(0) { $0 + ($1.unrealized ?? 0) },
                realizedAllTime: events.reduce(0) { $0 + $1.amount },
                realizedThisMonth: events.filter { $0.date >= monthStart }.reduce(0) { $0 + $1.amount },
                openRisk: holdings.reduce(0) { $0 + $1.openRisk },
                capital: capital[currency]))
        }
        return out
    }

    nonisolated struct Slice: Identifiable, Equatable {
        var id: String { label }
        var label: String
        var amount: Double
        var percent: Double
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case product = "Product", assetClass = "Type", market = "Market"
        var id: String { rawValue }
    }

    /// Share of current value (cost when no price yet).
    static func allocation(_ holdings: [Holding], by grouping: Grouping) -> [Slice] {
        var sums: [String: Double] = [:]
        for h in holdings {
            let key: String
            switch grouping {
            case .product: key = h.trade.instrument.symbol
            case .assetClass: key = h.trade.instrument.kind.title
            case .market: key = h.trade.instrument.exchange
            }
            sums[key, default: 0] += abs(h.value ?? h.cost)
        }
        let total = sums.values.reduce(0, +)
        guard total > 0 else { return [] }
        return sums.map { Slice(label: $0.key, amount: $0.value, percent: $0.value / total * 100) }
            .sorted { $0.amount > $1.amount }
    }

    nonisolated struct EquityPoint: Identifiable, Equatable {
        var id: Date { date }
        var date: Date
        var cumulative: Double
    }

    /// Cumulative realised P&L by day.
    static func equityCurve(_ trades: [Trade], mode: TradeMode, currency: String) -> [EquityPoint] {
        let events = trades.filter { $0.mode == mode && $0.instrument.currency == currency }
            .flatMap(realizedEvents)
            .filter { $0.amount != 0 }
        let byDay = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }
            .mapValues { $0.reduce(0) { $0 + $1.amount } }
        var running = 0.0
        return byDay.keys.sorted().map { day in
            running += byDay[day]!
            return EquityPoint(date: day, cumulative: running)
        }
    }

    /// Optional single total in INR. USDT is treated as USD (≈1:1); the rate and its time are shown to the user.
    static func totalInINR(_ summaries: [CurrencySummary], usdInr: Double?) -> Double? {
        var total = 0.0
        for s in summaries {
            guard let v = s.value else { return nil }
            switch s.currency {
            case "INR": total += v
            case "USD", "USDT":
                guard let usdInr else { return nil }
                total += v * usdInr
            default: return nil
            }
        }
        return total
    }
}
