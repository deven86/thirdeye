import Foundation

/// Replays a plan's exact rules — same stop distance in ATRs, the 5-step take-profit ladder, the same time
/// limit — from every past bar of the same product, in the same direction.
///
/// It describes how trades managed this way have behaved on this product: how often the stop is hit first,
/// how often the targets are reached, typical losing streaks. That is for setting position size and
/// expectations. It is NOT a forecast: a walk-forward test on 28 coins (DECISIONS #39) showed that results
/// in "similar past conditions" did not predict the next trade, so no verdict depends on it.
nonisolated enum PlanReplay {
    nonisolated struct Outcome: Equatable, Sendable {
        var r: Double             // result in R (multiples of the initial risk), after costs
        var bars: Int             // bars held
        var targetsHit: Int       // 0…4
        var stoppedBeforeTP1: Bool
    }

    nonisolated struct BaseRate: Codable, Hashable, Sendable {
        var side: String
        var stopATR: Double
        var horizonBars: Int
        var costPct: Double
        var entries: Int          // every past bar replayed (overlapping trades)
        var independent: Int      // trades that never overlap — the honest sample size
        var stopFirstPct: Double  // stop hit before TP1
        var tp1Pct: Double
        var tp2Pct: Double
        var winPct: Double        // result above zero after costs
        var averageR: Double
        var longestLosingStreak: Int
        var from: Date
        var to: Date
    }

    /// Book 30 / 25 / 20 / 15 % at 1R–4R. After each target the stop steps up: breakeven, then 1R, 2R, 3R.
    /// The last 10 % runs to the time limit (or the stepped stop).
    static let ladder: [(r: Double, pct: Double)] = [(1, 0.30), (2, 0.25), (3, 0.20), (4, 0.15)]

    /// Enter at the close of bar `i`. Conservative: when one bar touches both the stop and a target, the stop
    /// counts first; a gap through the stop fills at the open.
    static func simulate(_ c: [Candle], entry i: Int, side: Int, risk: Double, horizon: Int, costPct: Double) -> Outcome? {
        guard risk > 0, i >= 0, i < c.count - 1 else { return nil }
        let e = c[i].close
        let s = Double(side)
        var stop = e - s * risk
        var remaining = 1.0, realized = 0.0
        var next = 0, bars = 0
        var stoppedBeforeTP1 = false
        let last = min(i + horizon, c.count - 1)
        var j = i + 1
        while j <= last {
            let bar = c[j]
            bars = j - i
            let stopHit = side > 0 ? bar.low <= stop : bar.high >= stop
            if stopHit {
                let fill = side > 0 ? min(bar.open, stop) : max(bar.open, stop)
                realized += remaining * s * (fill - e) / risk
                remaining = 0
                if next == 0 { stoppedBeforeTP1 = true }
                break
            }
            while next < ladder.count {
                let target = e + s * ladder[next].r * risk
                let reached = side > 0 ? bar.high >= target : bar.low <= target
                if !reached { break }
                let fill = side > 0 ? max(bar.open, target) : min(bar.open, target)
                realized += ladder[next].pct * s * (fill - e) / risk
                remaining -= ladder[next].pct
                stop = e + s * (ladder[next].r - 1) * risk
                next += 1
            }
            j += 1
        }
        if remaining > 1e-9 {
            realized += remaining * s * (c[last].close - e) / risk
        }
        return Outcome(r: realized - costPct / 100 * e / risk, bars: max(bars, 1), targetsHit: next,
                       stoppedBeforeTP1: stoppedBeforeTP1)
    }

    /// Replays every past bar whose full time limit lies inside the data.
    static func baseRate(_ c: [Candle], side: String, stopATR: Double, horizon: Int, costPct: Double) -> BaseRate? {
        guard stopATR > 0, horizon > 0, c.count > horizon + 30 else { return nil }
        let atr = Indicators.atr(c)
        let s = side == "short" ? -1 : 1
        var outcomes: [(i: Int, o: Outcome)] = []
        for i in 14..<(c.count - horizon) {
            guard let a = atr[i], a > 0,
                  let o = simulate(c, entry: i, side: s, risk: stopATR * a, horizon: horizon, costPct: costPct) else { continue }
            outcomes.append((i, o))
        }
        guard outcomes.count >= 20, let firstEntry = outcomes.first, let lastBar = c.last else { return nil }
        let n = Double(outcomes.count)
        // Independent trades: take one, then skip until it has closed.
        var independent: [Outcome] = []
        var free = -1
        for (i, o) in outcomes where i > free {
            independent.append(o)
            free = i + max(o.bars, 1)
        }
        var longest = 0, run = 0
        for o in independent {
            if o.r <= 0 { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return BaseRate(side: s > 0 ? "long" : "short", stopATR: stopATR, horizonBars: horizon, costPct: costPct,
                        entries: outcomes.count, independent: independent.count,
                        stopFirstPct: Double(outcomes.filter { $0.o.stoppedBeforeTP1 }.count) / n,
                        tp1Pct: Double(outcomes.filter { $0.o.targetsHit >= 1 }.count) / n,
                        tp2Pct: Double(outcomes.filter { $0.o.targetsHit >= 2 }.count) / n,
                        winPct: Double(outcomes.filter { $0.o.r > 0 }.count) / n,
                        averageR: outcomes.reduce(0) { $0 + $1.o.r } / n,
                        longestLosingStreak: longest,
                        from: c[firstEntry.i].time, to: lastBar.time)
    }

    /// Typical round-trip cost (fees, taxes, spread) in % of price, by market.
    static func roundTripCostPct(_ i: Instrument) -> Double {
        switch i.kind {
        case .crypto: return 0.2                       // ~0.1 % taker fee each side
        case .forex: return 0.03
        case .commodity: return i.provider == .upstox ? 0.1 : 0.05
        case .future, .option, .index: return 0.1
        case .equity, .etf: return i.provider == .upstox ? 0.25 : 0.05  // India delivery: STT both sides + charges
        }
    }

    /// Holding period in bars of the plan's chart. Crypto trades every day; most other markets ~5 days a week.
    static func horizonBars(days: Int, timeframe: Timeframe, instrument: Instrument) -> Int {
        let d = Double(max(days, 1))
        let everyDay = instrument.kind == .crypto
        let bars: Double
        switch timeframe {
        case .d1: bars = everyDay ? d : d * 5 / 7
        case .w1: bars = d / 7
        case .mo1: bars = d / 30
        default:
            let sessionHours = everyDay ? 24.0 : instrument.provider == .upstox ? 6.25 : 8.0
            bars = d * sessionHours * 3600 / timeframe.seconds
        }
        return min(max(Int(bars.rounded()), 1), 250)
    }
}
