import Foundation

/// Builds a technical snapshot ("feature pack") for one instrument and timeframe.
/// Every number is computed here, in code. In Milestone 4 the AI receives this pack
/// and must cite features by ID (e.g. `D.RSI14`) — it never reads raw candles.
nonisolated enum FeatureEngine {
    nonisolated enum Category: String, CaseIterable, Codable {
        case trend = "Trend"
        case momentum = "Momentum"
        case volatility = "Volatility"
        case volume = "Volume"
        case levels = "Levels"
        case patterns = "Patterns"
        case history = "History"
    }

    nonisolated struct Feature: Identifiable, Equatable, Codable {
        var id: String          // stable ID, e.g. "D.RSI14"
        var category: Category
        var label: String
        var value: Double?
        var display: String
        var signal: Int         // +1 bullish, −1 bearish, 0 neutral/informational
        var note: String?
    }

    nonisolated struct Snapshot: Equatable {
        var timeframe: Timeframe
        var asOf: Date
        var bars: Int
        var features: [Feature]
        var zones: [Levels.Zone]
        var patternStats: [Patterns.Stat]
        var recentPatterns: [(kind: Patterns.Kind, barsAgo: Int)]
        var history: History.Summary?

        /// Code-computed technical lean from the signalling features. Not the AI score.
        var bias: (bullish: Int, bearish: Int, label: String) {
            let b = features.filter { $0.signal > 0 }.count
            let s = features.filter { $0.signal < 0 }.count
            let label = b >= s + 3 ? "Bullish" : s >= b + 3 ? "Bearish" : "Mixed"
            return (b, s, label)
        }

        func features(in category: Category) -> [Feature] { features.filter { $0.category == category } }

        static func == (l: Snapshot, r: Snapshot) -> Bool {
            l.timeframe == r.timeframe && l.asOf == r.asOf && l.bars == r.bars && l.features == r.features
        }
    }

    static func prefix(_ tf: Timeframe) -> String {
        switch tf {
        case .m1: "M1"
        case .m5: "M5"
        case .m15: "M15"
        case .m30: "M30"
        case .h1: "H1"
        case .d1: "D"
        case .w1: "W"
        case .mo1: "MO"
        }
    }

    static let minimumBars = 30

    static func snapshot(_ c: [Candle], timeframe tf: Timeframe) -> Snapshot? {
        guard c.count >= minimumBars, let last = c.last else { return nil }
        let p = prefix(tf)
        let closes = c.map(\.close)
        let i = c.count - 1
        var f: [Feature] = []

        func pct(_ v: Double) -> String { String(format: "%+.2f%%", v) }
        func num(_ v: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", v) }
        func add(_ id: String, _ cat: Category, _ label: String, _ value: Double?, _ display: String,
                 _ signal: Int = 0, _ note: String? = nil) {
            f.append(Feature(id: "\(p).\(id)", category: cat, label: label, value: value, display: display, signal: signal, note: note))
        }

        // Trend
        let sma = [20, 50, 100, 200].map { ($0, Indicators.sma(closes, $0)[i]) }
        let ema20 = Indicators.ema(closes, 20)[i]
        for (n, v) in sma {
            guard let v else { continue }
            let above = last.close > v
            add("SMA\(n)", .trend, "Price vs \(n)-bar average", (last.close / v - 1) * 100,
                "\(above ? "Above" : "Below") by \(pct((last.close / v - 1) * 100))", above ? 1 : -1)
        }
        if let s50 = sma[1].1, let s200 = sma[3].1 {
            let prev50 = Indicators.sma(Array(closes.dropLast()), 50).last ?? nil
            let prev200 = Indicators.sma(Array(closes.dropLast()), 200).last ?? nil
            var note: String?
            if let a = prev50, let b = prev200 {
                if a <= b && s50 > s200 { note = "Golden cross on the latest bar" }
                if a >= b && s50 < s200 { note = "Death cross on the latest bar" }
            }
            add("CROSS50_200", .trend, "50 vs 200 average", s50 - s200, s50 > s200 ? "50 above 200" : "50 below 200",
                s50 > s200 ? 1 : -1, note)
        }
        if let e = ema20, let ePrev = Indicators.ema(closes, 20)[max(i - 5, 0)] {
            let slope = (e / ePrev - 1) * 100
            add("EMA20.SLOPE5", .trend, "20-bar EMA slope (5 bars)", slope, pct(slope), slope > 0.2 ? 1 : slope < -0.2 ? -1 : 0)
        }
        let dmi = Indicators.adx(c)
        if let a = dmi.adx[i], let pd = dmi.plusDI[i], let md = dmi.minusDI[i] {
            let strength = a >= 25 ? "strong" : a >= 20 ? "developing" : "weak"
            add("ADX14", .trend, "Trend strength (ADX)", a, "\(num(a, 1)) · \(strength), \(pd > md ? "buyers" : "sellers") lead",
                a >= 20 ? (pd > md ? 1 : -1) : 0)
        }
        let swings = Levels.swings(c)
        let highs = swings.filter(\.isHigh).suffix(2).map(\.price)
        let lows = swings.filter { !$0.isHigh }.suffix(2).map(\.price)
        if highs.count == 2, lows.count == 2 {
            let hh = highs[1] > highs[0], hl = lows[1] > lows[0]
            let (text, sig) = hh && hl ? ("Higher highs & higher lows", 1)
                : !hh && !hl ? ("Lower highs & lower lows", -1) : ("Mixed swing structure", 0)
            add("STRUCTURE", .trend, "Market structure", nil, text, sig)
        }

        // Momentum
        if let r = Indicators.rsi(closes)[i] {
            let (text, sig) = r >= 70 ? ("Overbought", -1) : r <= 30 ? ("Oversold", 1) : r >= 55 ? ("Positive", 1) : r <= 45 ? ("Negative", -1) : ("Neutral", 0)
            add("RSI14", .momentum, "RSI (14)", r, "\(num(r, 1)) · \(text)", sig)
        }
        let m = Indicators.macd(closes)
        if let line = m.macd[i], let sig = m.signal[i], let h = m.histogram[i] {
            let prevH = m.histogram[i - 1] ?? h
            let cross = (prevH <= 0 && h > 0) ? " · bullish cross" : (prevH >= 0 && h < 0) ? " · bearish cross" : ""
            add("MACD", .momentum, "MACD vs signal", h, "\(line > sig ? "Above" : "Below") signal\(cross)", h > 0 ? 1 : -1)
        }
        for n in [10, 20] {
            if let r = Indicators.roc(closes, n)[i] {
                add("ROC\(n)", .momentum, "Change over \(n) bars", r, pct(r), r > 0 ? 1 : r < 0 ? -1 : 0)
            }
        }

        // Volatility
        let atr = Indicators.atr(c)
        if let a = atr[i] {
            add("ATR14", .volatility, "Average true range", a, "\(num(a, a < 1 ? 4 : 2)) (\(pct(a / last.close * 100).dropFirst()) of price)")
        }
        let bb = Indicators.bollinger(closes)
        if let u = bb.upper[i], let l = bb.lower[i], let mid = bb.middle[i], u > l {
            let pos = (last.close - l) / (u - l) * 100
            let width = (u - l) / mid * 100
            let widths = closes.indices.suffix(120).compactMap { j -> Double? in
                guard let uu = bb.upper[j], let ll = bb.lower[j], let mm = bb.middle[j], mm != 0 else { return nil }
                return (uu - ll) / mm * 100
            }
            let rank = widths.isEmpty ? 50 : Double(widths.filter { $0 <= width }.count) / Double(widths.count) * 100
            add("BB.POS", .volatility, "Position in Bollinger band", pos, "\(num(pos, 0))% of the band", 0,
                pos > 100 ? "Closed above the upper band" : pos < 0 ? "Closed below the lower band" : nil)
            add("BB.WIDTH.PCTL", .volatility, "Band width vs last 120 bars", rank, "\(num(rank, 0))th percentile", 0,
                rank <= 15 ? "Squeeze — a large move often follows" : nil)
        }
        let rets = Indicators.returns(closes).suffix(20).compactMap { $0 }
        if rets.count >= 10 {
            let vol = Indicators.stdev(rets) * 100
            add("VOL20", .volatility, "Volatility (20 bars)", vol, "\(num(vol)) % per bar")
        }

        // Volume
        let vols = c.map(\.volume)
        if vols.contains(where: { $0 > 0 }) {
            if let avg = Indicators.sma(vols, 20)[i], avg > 0 {
                let rel = last.volume / avg
                let up = last.close >= last.open
                add("RELVOL20", .volume, "Volume vs 20-bar average", rel, "\(num(rel)) ×",
                    rel >= 1.5 ? (up ? 1 : -1) : 0, rel >= 1.5 ? "Heavy volume on a \(up ? "rising" : "falling") bar" : nil)
            }
            let obv = Indicators.obv(c)
            if c.count > 21 {
                let change = obv[i] - obv[i - 20]
                add("OBV.TREND20", .volume, "On-balance volume (20 bars)", change, change >= 0 ? "Accumulation" : "Distribution",
                    change > 0 ? 1 : change < 0 ? -1 : 0)
            }
        }

        // Levels
        let zones = Levels.zones(c, atr: atr[i])
        if let s = zones.first(where: { $0.kind == .support }) {
            let dist = (last.close / s.price - 1) * 100
            add("SUPPORT1", .levels, "Nearest support", s.price, "\(num(s.price, decimals(last.close))) · \(pct(-dist)) away · \(s.touches) touches")
        }
        if let r = zones.first(where: { $0.kind == .resistance }) {
            let dist = (r.price / last.close - 1) * 100
            add("RESIST1", .levels, "Nearest resistance", r.price, "\(num(r.price, decimals(last.close))) · \(pct(dist)) away · \(r.touches) touches")
        }
        let lookback = c.suffix(tf == .d1 ? 252 : tf == .w1 ? 52 : 120)
        if let hi = lookback.map(\.high).max(), let lo = lookback.map(\.low).min(), hi > lo {
            let pos = (last.close - lo) / (hi - lo) * 100
            add("RANGE.POS", .levels, tf == .d1 ? "Position in 52-week range" : "Position in recent range", pos,
                "\(num(pos, 0))% (low \(num(lo, decimals(last.close))), high \(num(hi, decimals(last.close))))")
        }

        // Patterns
        let stats = Patterns.backtest(c)
        var recent: [(Patterns.Kind, Int)] = []
        for back in 0..<3 {
            for k in Patterns.detect(c, at: i - back) { recent.append((k, back)) }
        }
        var reported = Set<Patterns.Kind>()
        for (k, back) in recent where k.bias != 0 && reported.insert(k).inserted { // most recent occurrence only
            let s = stats[k]
            let reliability = s.map { "\(Int(($0.hitRate * 100).rounded()))% worked here (\($0.occurrences) times)" } ?? "no history"
            add("PAT.\(k.rawValue.uppercased())", .patterns, k.title, s?.hitRate,
                "\(back == 0 ? "Latest bar" : "\(back) bar\(back > 1 ? "s" : "") ago") · \(reliability)",
                (s?.occurrences ?? 0) >= 8 && (s?.hitRate ?? 0) >= 0.55 ? k.bias : 0)
        }

        // History (meaningful on daily and longer)
        let history = (tf == .d1 || tf == .w1 || tf == .mo1) ? History.summary(c) : nil
        if let h = history {
            add("HIST.TOTAL", .history, "Return over loaded history", h.totalReturnPct, pct(h.totalReturnPct))
            if let cagr = h.cagrPct { add("HIST.CAGR", .history, "Yearly growth (CAGR)", cagr, pct(cagr)) }
            if let dd = h.maxDrawdown {
                add("HIST.MAXDD", .history, "Worst fall from a peak", dd.percent,
                    "\(pct(dd.percent)) (\(dd.peak.formatted(date: .abbreviated, time: .omitted)) → \(dd.trough.formatted(date: .abbreviated, time: .omitted)))",
                    0, dd.recovered == nil ? "Not yet recovered" : nil)
            }
        }

        return Snapshot(timeframe: tf, asOf: last.time, bars: c.count, features: f, zones: zones,
                        patternStats: stats.values.sorted { $0.occurrences > $1.occurrences },
                        recentPatterns: recent.map { (kind: $0.0, barsAgo: $0.1) }, history: history)
    }

    static func decimals(_ price: Double) -> Int {
        price < 1 ? 5 : price < 10 ? 4 : 2
    }

    /// A price with sensible decimals and no grouping, for messages.
    static func plain(_ price: Double) -> String {
        String(format: "%.\(decimals(abs(price)))f", price)
    }

    /// Compact JSON for the AI (Milestone 4). Keeps tokens low: id → display text.
    static func featurePackJSON(_ s: Snapshot, instrument: Instrument) -> String {
        var dict: [String: Any] = [
            "product": instrument.symbol,
            "exchange": instrument.exchange,
            "timeframe": s.timeframe.label,
            "as_of": ISO8601DateFormatter().string(from: s.asOf),
            "bars": s.bars,
        ]
        var feats: [String: String] = [:]
        for feature in s.features {
            feats[feature.id] = feature.display + (feature.note.map { " — \($0)" } ?? "")
        }
        dict["features"] = feats
        if let regimes = s.history?.regimes.suffix(8) {
            dict["regimes"] = regimes.map {
                "\($0.kind.rawValue) \($0.start.formatted(date: .abbreviated, time: .omitted))→\($0.end.formatted(date: .abbreviated, time: .omitted)) \(String(format: "%+.1f%%", $0.changePct))"
            }
        }
        if let moves = s.history?.biggestMoves {
            dict["biggest_moves"] = moves.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)) \(String(format: "%+.1f%%", $0.changePct))" }
        }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
