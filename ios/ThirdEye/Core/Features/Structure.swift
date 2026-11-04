import Foundation

// MARK: - Swing points & support/resistance

nonisolated enum Levels {
    nonisolated struct Swing: Equatable { var index: Int; var price: Double; var isHigh: Bool }

    /// Fractal swing points: a high/low that is the extreme of `span` bars on each side.
    static func swings(_ c: [Candle], span: Int = 3) -> [Swing] {
        guard c.count > span * 2 else { return [] }
        var out: [Swing] = []
        for i in span..<(c.count - span) {
            let window = (i - span)...(i + span)
            if window.allSatisfy({ $0 == i || c[$0].high < c[i].high }) {
                out.append(Swing(index: i, price: c[i].high, isHigh: true))
            }
            if window.allSatisfy({ $0 == i || c[$0].low > c[i].low }) {
                out.append(Swing(index: i, price: c[i].low, isHigh: false))
            }
        }
        return out
    }

    nonisolated struct Zone: Equatable, Identifiable {
        var id: String { "\(kind)-\(Int(price * 100))" }
        var kind: Kind
        var price: Double
        var low: Double
        var high: Double
        var touches: Int
        var lastTouch: Int
        nonisolated enum Kind: String { case support, resistance }
    }

    /// Clusters swing points within `tolerance` (default 0.5 × ATR) into zones,
    /// labelled support/resistance relative to the last close. Strongest (most touches, most recent) first.
    static func zones(_ c: [Candle], atr: Double?, maxZones: Int = 6) -> [Zone] {
        guard let last = c.last else { return [] }
        let tol = max(atr ?? 0, last.close * 0.002) * 0.5
        let points = swings(c).sorted { $0.price < $1.price }
        var clusters: [[Swing]] = []
        for p in points {
            if let lastCluster = clusters.last, let ref = lastCluster.last, p.price - ref.price <= tol {
                clusters[clusters.count - 1].append(p)
            } else {
                clusters.append([p])
            }
        }
        let zones = clusters.map { cl -> Zone in
            let price = cl.map(\.price).reduce(0, +) / Double(cl.count)
            return Zone(kind: price <= last.close ? .support : .resistance,
                        price: price,
                        low: cl.map(\.price).min()!, high: cl.map(\.price).max()!,
                        touches: cl.count, lastTouch: cl.map(\.index).max()!)
        }
        let n = Double(c.count)
        func strength(_ z: Zone) -> Double { Double(z.touches) + Double(z.lastTouch) / n }
        // Keep the strongest, then report nearest-first on each side.
        let strongest = zones.sorted { strength($0) > strength($1) }.prefix(maxZones)
        return strongest.sorted { abs($0.price - last.close) < abs($1.price - last.close) }
    }
}

// MARK: - Candlestick patterns with this instrument's own hit rate

nonisolated enum Patterns {
    nonisolated enum Kind: String, CaseIterable {
        case bullishEngulfing, bearishEngulfing, hammer, shootingStar, doji,
             morningStar, eveningStar, threeWhiteSoldiers, threeBlackCrows, insideBar

        var title: String {
            switch self {
            case .bullishEngulfing: "Bullish engulfing"
            case .bearishEngulfing: "Bearish engulfing"
            case .hammer: "Hammer"
            case .shootingStar: "Shooting star"
            case .doji: "Doji"
            case .morningStar: "Morning star"
            case .eveningStar: "Evening star"
            case .threeWhiteSoldiers: "Three white soldiers"
            case .threeBlackCrows: "Three black crows"
            case .insideBar: "Inside bar"
            }
        }

        /// +1 bullish, −1 bearish, 0 neutral (indecision).
        var bias: Int {
            switch self {
            case .bullishEngulfing, .hammer, .morningStar, .threeWhiteSoldiers: 1
            case .bearishEngulfing, .shootingStar, .eveningStar, .threeBlackCrows: -1
            case .doji, .insideBar: 0
            }
        }
    }

    /// Patterns completing at bar `i`.
    static func detect(_ c: [Candle], at i: Int) -> [Kind] {
        guard i >= 2, i < c.count else { return [] }
        let x = c[i], p = c[i - 1], pp = c[i - 2]
        func body(_ k: Candle) -> Double { abs(k.close - k.open) }
        func range(_ k: Candle) -> Double { max(k.high - k.low, .ulpOfOne) }
        func bull(_ k: Candle) -> Bool { k.close > k.open }
        func bear(_ k: Candle) -> Bool { k.close < k.open }
        let upper = x.high - max(x.open, x.close)
        let lower = min(x.open, x.close) - x.low
        // Short context trend over the previous 5 closes.
        let start = max(0, i - 5)
        let downBefore = c[i - 1].close < c[start].close
        let upBefore = c[i - 1].close > c[start].close

        var found: [Kind] = []
        if bear(p), bull(x), x.open <= p.close, x.close >= p.open, body(x) > body(p) { found.append(.bullishEngulfing) }
        if bull(p), bear(x), x.open >= p.close, x.close <= p.open, body(x) > body(p) { found.append(.bearishEngulfing) }
        if body(x) <= range(x) * 0.35, lower >= body(x) * 2, upper <= body(x) * 0.5 + range(x) * 0.05, downBefore {
            found.append(.hammer)
        }
        if body(x) <= range(x) * 0.35, upper >= body(x) * 2, lower <= body(x) * 0.5 + range(x) * 0.05, upBefore {
            found.append(.shootingStar)
        }
        if body(x) <= range(x) * 0.1 { found.append(.doji) }
        if bear(pp), body(p) <= body(pp) * 0.5, bull(x), x.close > (pp.open + pp.close) / 2, body(pp) > range(pp) * 0.5 {
            found.append(.morningStar)
        }
        if bull(pp), body(p) <= body(pp) * 0.5, bear(x), x.close < (pp.open + pp.close) / 2, body(pp) > range(pp) * 0.5 {
            found.append(.eveningStar)
        }
        if bull(pp), bull(p), bull(x), p.close > pp.close, x.close > p.close,
           p.open > pp.open, x.open > p.open, body(x) > range(x) * 0.5 { found.append(.threeWhiteSoldiers) }
        if bear(pp), bear(p), bear(x), p.close < pp.close, x.close < p.close,
           p.open < pp.open, x.open < p.open, body(x) > range(x) * 0.5 { found.append(.threeBlackCrows) }
        if x.high <= p.high, x.low >= p.low { found.append(.insideBar) }
        return found
    }

    nonisolated struct Stat: Equatable {
        var kind: Kind
        var occurrences: Int
        var hits: Int
        var avgReturnPct: Double
        var hitRate: Double { occurrences == 0 ? 0 : Double(hits) / Double(occurrences) }
    }

    /// For each directional pattern: how often price moved in the expected direction
    /// `horizon` bars later, on THIS instrument's history. Neutral patterns report
    /// the share of times price moved more than 1 ATR either way.
    static func backtest(_ c: [Candle], horizon: Int = 5) -> [Kind: Stat] {
        let atr = Indicators.atr(c)
        var stats: [Kind: Stat] = [:]
        guard c.count > horizon + 3 else { return stats }
        for i in 2..<(c.count - horizon) {
            for k in detect(c, at: i) {
                let ret = c[i + horizon].close / c[i].close - 1
                let hit: Bool
                switch k.bias {
                case 1: hit = ret > 0
                case -1: hit = ret < 0
                default: hit = abs(c[i + horizon].close - c[i].close) > (atr[i] ?? .infinity)
                }
                var s = stats[k] ?? Stat(kind: k, occurrences: 0, hits: 0, avgReturnPct: 0)
                s.avgReturnPct = (s.avgReturnPct * Double(s.occurrences) + ret * 100) / Double(s.occurrences + 1)
                s.occurrences += 1
                if hit { s.hits += 1 }
                stats[k] = s
            }
        }
        return stats
    }
}

// MARK: - Long-history summary (stage 4 input)

nonisolated enum History {
    nonisolated struct Drawdown: Equatable { var percent: Double; var peak: Date; var trough: Date; var recovered: Date? }

    nonisolated struct Regime: Equatable {
        nonisolated enum Kind: String { case bull, bear, sideways }
        var kind: Kind
        var start: Date
        var end: Date
        var changePct: Double
    }

    nonisolated struct Move: Equatable { var date: Date; var changePct: Double }

    nonisolated struct Summary: Equatable {
        var firstDate: Date
        var lastDate: Date
        var totalReturnPct: Double
        var cagrPct: Double?
        var maxDrawdown: Drawdown?
        var regimes: [Regime]
        var biggestMoves: [Move]
    }

    static func maxDrawdown(_ c: [Candle]) -> Drawdown? {
        guard c.count > 1 else { return nil }
        var peakIdx = 0, best: (Double, Int, Int) = (0, 0, 0)
        for i in c.indices {
            if c[i].close > c[peakIdx].close { peakIdx = i }
            let dd = c[i].close / c[peakIdx].close - 1
            if dd < best.0 { best = (dd, peakIdx, i) }
        }
        guard best.0 < 0 else { return nil }
        let peakPrice = c[best.1].close
        let recovered = c[(best.2)...].first { $0.close >= peakPrice }?.time
        return Drawdown(percent: best.0 * 100, peak: c[best.1].time, trough: c[best.2].time, recovered: recovered)
    }

    /// Splits history into bull/bear/sideways phases using swings of at least `threshold` (default 20 %).
    static func regimes(_ c: [Candle], threshold: Double = 0.20) -> [Regime] {
        guard c.count > 2 else { return [] }
        var pivots: [Int] = [0]
        var direction = 0 // +1 rising, −1 falling
        var extreme = 0
        for i in 1..<c.count {
            let move = c[i].close / c[extreme].close - 1
            if direction >= 0 {
                if c[i].close > c[extreme].close { extreme = i }
                else if c[i].close / c[extreme].close - 1 <= -threshold {
                    if extreme != pivots.last { pivots.append(extreme) }
                    direction = -1; extreme = i
                }
            } else {
                if c[i].close < c[extreme].close { extreme = i }
                else if move >= threshold {
                    if extreme != pivots.last { pivots.append(extreme) }
                    direction = 1; extreme = i
                }
            }
        }
        if pivots.last != c.count - 1 { pivots.append(c.count - 1) }
        var out: [Regime] = []
        for (a, b) in zip(pivots, pivots.dropFirst()) {
            let change = (c[b].close / c[a].close - 1)
            let kind: Regime.Kind = change >= threshold ? .bull : change <= -threshold ? .bear : .sideways
            if let last = out.last, last.kind == kind {
                out[out.count - 1].end = c[b].time
                out[out.count - 1].changePct = ((1 + last.changePct / 100) * (1 + change) - 1) * 100
            } else {
                out.append(Regime(kind: kind, start: c[a].time, end: c[b].time, changePct: change * 100))
            }
        }
        return out
    }

    static func summary(_ c: [Candle], topMoves: Int = 8) -> Summary? {
        guard let first = c.first, let last = c.last, c.count > 2, first.close > 0 else { return nil }
        let years = last.time.timeIntervalSince(first.time) / (365.25 * 86_400)
        let total = last.close / first.close - 1
        let cagr = years >= 1 ? (pow(last.close / first.close, 1 / years) - 1) * 100 : nil
        let moves = c.indices.dropFirst()
            .map { Move(date: c[$0].time, changePct: (c[$0].close / c[$0 - 1].close - 1) * 100) }
            .sorted { abs($0.changePct) > abs($1.changePct) }
            .prefix(topMoves)
        return Summary(firstDate: first.time, lastDate: last.time, totalReturnPct: total * 100, cagrPct: cagr,
                       maxDrawdown: maxDrawdown(c), regimes: regimes(c), biggestMoves: Array(moves))
    }
}
