import Foundation

/// Checks shown before saving a new trade. Advice, not a lock: a "stop" check needs an explicit override.
nonisolated enum RiskGuard {
    nonisolated enum Level: Int, Comparable, Sendable {
        case ok, caution, stop
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    nonisolated struct Check: Identifiable, Equatable, Sendable {
        var id: String
        var title: String
        var detail: String
        var level: Level
    }

    /// Realised R of trades closed in the last 7 days (this mode).
    static func lastSevenDays(_ trades: [Trade], mode: TradeMode, now: Date) -> (r: Double, count: Int) {
        let since = now.addingTimeInterval(-7 * 86_400)
        var total = 0.0, count = 0
        for t in trades where t.mode == mode && t.status == .closed {
            guard let closed = t.closedAt, closed >= since, closed <= now,
                  let r = TradeMath.summary(t, lastPrice: nil).rMultiple else { continue }
            total += r
            count += 1
        }
        return (total, count)
    }

    static func weeklyCheck(_ trades: [Trade], mode: TradeMode, limitR: Double, now: Date) -> Check {
        let week = lastSevenDays(trades, mode: mode, now: now)
        if week.count == 0 {
            return Check(id: "week", title: "Last 7 days", detail: "No closed trades.", level: .ok)
        }
        let text = "\(String(format: "%+.1f", week.r))R from \(week.count) closed trade\(week.count == 1 ? "" : "s") (pause at −\(String(format: "%.1f", limitR))R)."
        if week.r <= -limitR {
            return Check(id: "week", title: "Losing week — the guard says pause",
                         detail: text + " Losses cluster; a short break protects your capital and judgement.", level: .stop)
        }
        return Check(id: "week", title: "Last 7 days", detail: text, level: week.r <= -limitR * 0.66 ? .caution : .ok)
    }

    /// Open risk (all open trades in this currency and mode, if every stop is hit) plus the new trade's risk.
    static func openRiskCheck(_ trades: [Trade], mode: TradeMode, currency: String, newRisk: Double,
                              capital: Double?, capPercent: Double) -> Check? {
        guard let capital, capital > 0, newRisk > 0 else { return nil }
        let existing = trades.filter { $0.mode == mode && $0.instrument.currency == currency }
            .compactMap { PortfolioMath.holding($0, price: nil)?.openRisk }
            .reduce(0, +)
        let pct = (existing + newRisk) / capital * 100
        let detail = "\(String(format: "%.1f", pct))% of your \(currency) capital would be at risk if every stop is hit (cap \(String(format: "%.0f", capPercent))%)."
        return Check(id: "open", title: "Total open risk", detail: detail, level: pct > capPercent ? .caution : .ok)
    }

    /// Same direction + prices that move together = one bigger bet.
    /// `correlations` maps an existing trade's instrument id to its 60-day daily-return correlation with the new
    /// product (when it could be measured).
    static func sameBetCheck(newInstrument: Instrument, side: String, trades: [Trade], mode: TradeMode,
                             correlations: [String: Double]) -> Check? {
        let active = trades.filter {
            $0.mode == mode && ($0.status == .open || $0.status == .upcoming) && $0.side == side
                && $0.instrument.id != newInstrument.id
        }
        var linked: [(String, String)] = []
        for t in active {
            if let rho = correlations[t.instrument.id] {
                if rho >= 0.7 { linked.append((t.instrument.symbol, String(format: "ρ %.2f", rho))) }
            } else if t.instrument.kind == .crypto && newInstrument.kind == .crypto {
                linked.append((t.instrument.symbol, "crypto moves together"))
            }
        }
        guard !linked.isEmpty else { return nil }
        let names = linked.prefix(4).map { "\($0.0) (\($0.1))" }.joined(separator: ", ")
        return Check(id: "same", title: "Same bet as \(linked.count) other trade\(linked.count == 1 ? "" : "s")",
                     detail: "\(side == "long" ? "Long" : "Short") \(names). Together they behave like one bigger position — consider a smaller size.",
                     level: linked.count >= 2 ? .caution : .ok)
    }

    /// Pearson correlation of daily returns over the last `days` common dates.
    static func returnCorrelation(_ a: [Candle], _ b: [Candle], days: Int = 60) -> Double? {
        let cal = Calendar(identifier: .gregorian)
        func byDay(_ c: [Candle]) -> [Date: Double] {
            var m: [Date: Double] = [:]
            for x in c { m[cal.startOfDay(for: x.time)] = x.close }
            return m
        }
        let ma = byDay(a), mb = byDay(b)
        let common = Set(ma.keys).intersection(mb.keys).sorted().suffix(days + 1)
        guard common.count >= 21 else { return nil }
        var ra: [Double] = [], rb: [Double] = []
        var prev: Date?
        for d in common {
            if let p = prev, let a0 = ma[p], let a1 = ma[d], let b0 = mb[p], let b1 = mb[d], a0 > 0, b0 > 0 {
                ra.append(a1 / a0 - 1)
                rb.append(b1 / b0 - 1)
            }
            prev = d
        }
        return Indicators.correlation(ra, rb)
    }
}
