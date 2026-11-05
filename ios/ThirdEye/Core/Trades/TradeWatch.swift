import Foundation

/// The parameters an analysis was based on, captured from the plan's chart. The trade watch compares the
/// same parameters later and reports what changed — in the trade's favour or against it.
nonisolated struct WatchParams: Codable, Hashable, Sendable {
    var timeframe: Timeframe
    var at: Date
    var price: Double
    var vs20: Int?          // +1 price above the 20-bar average, −1 below
    var vs50: Int?
    var structure: Int?     // +1 higher highs & lows, −1 lower highs & lows, 0 mixed
    var macd: Int?          // +1 above its signal line
    var rsi: Double?
    var adx: Double?
    var atr: Double?
    var support: Double?    // nearest support below the price
    var resistance: Double? // nearest resistance above
    var bias: String        // Bullish / Bearish / Mixed (code-computed lean)

    init(timeframe: Timeframe, at: Date, price: Double, vs20: Int? = nil, vs50: Int? = nil, structure: Int? = nil,
         macd: Int? = nil, rsi: Double? = nil, adx: Double? = nil, atr: Double? = nil,
         support: Double? = nil, resistance: Double? = nil, bias: String = "Mixed") {
        self.timeframe = timeframe; self.at = at; self.price = price; self.vs20 = vs20; self.vs50 = vs50
        self.structure = structure; self.macd = macd; self.rsi = rsi; self.adx = adx; self.atr = atr
        self.support = support; self.resistance = resistance; self.bias = bias
    }

    init(_ snap: FeatureEngine.Snapshot, price: Double) {
        let p = FeatureEngine.prefix(snap.timeframe)
        func f(_ id: String) -> FeatureEngine.Feature? { snap.features.first { $0.id == "\(p).\(id)" } }
        self.init(timeframe: snap.timeframe, at: snap.asOf, price: price,
                  vs20: f("SMA20")?.signal, vs50: f("SMA50")?.signal, structure: f("STRUCTURE")?.signal,
                  macd: f("MACD")?.signal, rsi: f("RSI14")?.value, adx: f("ADX14")?.value, atr: f("ATR14")?.value,
                  support: snap.zones.filter { $0.kind == .support && $0.price < price }.map(\.price).max(),
                  resistance: snap.zones.filter { $0.kind == .resistance && $0.price > price }.map(\.price).min(),
                  bias: snap.bias.label)
    }
}

nonisolated enum WatchStatus: String, Codable, Sendable, CaseIterable {
    case strengthened, intact, weakened, broken

    var title: String {
        switch self {
        case .strengthened: "Stronger"
        case .intact: "Intact"
        case .weakened: "Weakened"
        case .broken: "Broken"
        }
    }

    var rank: Int {
        switch self {
        case .strengthened: 0
        case .intact: 1
        case .weakened: 2
        case .broken: 3
        }
    }
}

/// One parameter that moved since the analysis.
nonisolated struct ParamChange: Codable, Hashable, Sendable, Identifiable {
    nonisolated enum Effect: String, Codable, Sendable { case favourable, adverse, info }
    var id: String
    var title: String
    var before: String
    var now: String
    var effect: Effect
    var weight: Int          // 1 minor · 2 major · 3 critical
    var advice: String
}

nonisolated struct TrailSuggestion: Codable, Hashable, Sendable {
    var price: Double
    var reason: String
    var lockedR: Double      // result if the new stop is hit, in R (negative = still a loss)
}

/// The AI's re-check of an open trade.
nonisolated struct AIReview: Codable, Hashable, Sendable {
    var at: Date
    var status: WatchStatus
    var action: String       // hold · tighten_stop · book_partial · exit · add
    var newStop: Double?
    var bookPercent: Double?
    var summary: String
    var points: [String]
    var sources: [StageSourceRef]
    var warnings: [String]
    var model: String
    var costUSD: Double

    var actionTitle: String {
        switch action {
        case "tighten_stop": "Tighten the stop"
        case "book_partial": "Book part of the profit"
        case "exit": "Exit the trade"
        case "add": "Add to the position"
        default: "Hold — no change"
        }
    }
}

/// One watch check, kept on the trade (newest first, last few only).
nonisolated struct TradeCheck: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var at: Date
    var price: Double
    var r: Double?
    var status: WatchStatus
    var changes: [ParamChange]
    var trail: TrailSuggestion?
    var ai: AIReview?
    var notified = false
}

/// Deterministic part of the trade watch: what changed, how serious it is, and where the stop could trail.
nonisolated enum TradeWatch {
    static let keepChecks = 8

    /// The chart the watch reads: the analysis's plan chart, else one that suits the holding period.
    static func timeframe(for t: Trade, run: AnalysisRun?) -> Timeframe {
        if let tf = run?.watchBaseline?.timeframe ?? run?.planTimeframe { return tf }
        switch t.badge {
        case .scalp, .intraday: return .m15
        case .shortTerm: return .h1
        case .swing, .positional: return .d1
        case .longTerm: return .w1
        }
    }

    /// How often to re-check (the chart's bar length, between 10 minutes and 6 hours).
    static func interval(_ tf: Timeframe) -> TimeInterval {
        min(max(tf.seconds, 600), 6 * 3600)
    }

    static func compare(baseline b: WatchParams, now n: WatchParams, trade t: Trade, decimals: Int) -> [ParamChange] {
        let dir = t.isLong ? 1 : -1
        let up = t.isLong ? "up" : "down"
        func fmt(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }
        func side(_ v: Int?) -> String { v == 1 ? "above" : v == -1 ? "below" : "—" }
        var out: [ParamChange] = []

        // Price beyond the key level the plan leaned on.
        if t.isLong, let s = b.support, n.price < s {
            out.append(ParamChange(id: "keylevel", title: "Key support broken", before: "support \(fmt(s))", now: "price \(fmt(n.price))",
                                   effect: .adverse, weight: 3, advice: "The level the long case rested on gave way. Exit, or keep only a small part with the stop unchanged."))
        }
        if !t.isLong, let r = b.resistance, n.price > r {
            out.append(ParamChange(id: "keylevel", title: "Key resistance broken", before: "resistance \(fmt(r))", now: "price \(fmt(n.price))",
                                   effect: .adverse, weight: 3, advice: "The level the short case rested on gave way. Exit, or keep only a small part with the stop unchanged."))
        }
        if t.isLong, let r = b.resistance, n.price > r {
            out.append(ParamChange(id: "breakout", title: "Broke above resistance", before: "resistance \(fmt(r))", now: "price \(fmt(n.price))",
                                   effect: .favourable, weight: 2, advice: "Move \(up) with it: trail the stop instead of exiting early, and let the runner work."))
        }
        if !t.isLong, let s = b.support, n.price < s {
            out.append(ParamChange(id: "breakout", title: "Broke below support", before: "support \(fmt(s))", now: "price \(fmt(n.price))",
                                   effect: .favourable, weight: 2, advice: "Trail the stop instead of exiting early, and let the runner work."))
        }

        func flip(_ id: String, _ title: String, _ before: Int?, _ now: Int?, against: Int, with: Int, text: (Int?) -> String,
                  adviceAgainst: String, adviceWith: String) {
            guard let before, let now, before != now else { return }
            if now == -dir {
                out.append(ParamChange(id: id, title: title, before: text(before), now: text(now), effect: .adverse, weight: against, advice: adviceAgainst))
            } else if now == dir {
                out.append(ParamChange(id: id, title: title, before: text(before), now: text(now), effect: .favourable, weight: with, advice: adviceWith))
            }
        }
        flip("vs50", "Price vs 50-bar average", b.vs50, n.vs50, against: 2, with: 1, text: side,
             adviceAgainst: "The medium trend turned against the trade. Tighten the stop; don't add.",
             adviceWith: "The medium trend now supports the trade.")
        flip("vs20", "Price vs 20-bar average", b.vs20, n.vs20, against: 1, with: 1, text: side,
             adviceAgainst: "Short-term momentum faded. Normal in a pullback — watch the stop.",
             adviceWith: "Short-term trend is back in the trade's favour.")
        flip("structure", "Swing structure", b.structure, n.structure, against: 2, with: 1,
             text: { $0 == 1 ? "higher highs & lows" : $0 == -1 ? "lower highs & lows" : "mixed" },
             adviceAgainst: "Swings now point against the trade. Consider booking part and tightening the stop.",
             adviceWith: "Swings now confirm the trade's direction.")
        flip("macd", "MACD vs signal", b.macd, n.macd, against: 1, with: 1, text: side,
             adviceAgainst: "Momentum crossed against the trade.", adviceWith: "Momentum crossed in the trade's favour.")

        if let br = b.rsi, let nr = n.rsi {
            let stretched = t.isLong ? (nr >= 75 && br < 75) : (nr <= 25 && br > 25)
            let weak = t.isLong ? (nr < 40 && br >= 45) : (nr > 60 && br <= 55)
            if stretched {
                out.append(ParamChange(id: "rsi", title: t.isLong ? "Overbought" : "Oversold",
                                       before: String(format: "RSI %.0f", br), now: String(format: "RSI %.0f", nr), effect: .info, weight: 1,
                                       advice: "The move is stretched. A good moment to book the next target or trail the stop closer."))
            } else if weak {
                out.append(ParamChange(id: "rsi", title: "Momentum weakened", before: String(format: "RSI %.0f", br), now: String(format: "RSI %.0f", nr),
                                       effect: .adverse, weight: 1, advice: "Buyers\(t.isLong ? "" : "/sellers") are losing strength. Don't add."))
            }
        }
        if let ba = b.atr, let na = n.atr, ba > 0 {
            let ratio = na / ba
            if ratio >= 1.5 {
                out.append(ParamChange(id: "atr", title: "Volatility jumped", before: fmt(ba), now: "\(fmt(na)) (×\(String(format: "%.1f", ratio)))",
                                       effect: .adverse, weight: 1, advice: "Swings are bigger than when you planned. Don't add; a normal wiggle may now reach the stop."))
            }
        }
        if b.bias != n.bias {
            let aligned = (t.isLong && b.bias == "Bullish") || (!t.isLong && b.bias == "Bearish")
            let against = (t.isLong && n.bias == "Bearish") || (!t.isLong && n.bias == "Bullish")
            let now = (t.isLong && n.bias == "Bullish") || (!t.isLong && n.bias == "Bearish")
            if against || (aligned && n.bias == "Mixed") {
                out.append(ParamChange(id: "bias", title: "Overall chart lean", before: b.bias, now: n.bias, effect: .adverse,
                                       weight: against ? 2 : 1, advice: against ? "Most indicators now point against the trade." : "The chart is no longer clearly in your favour."))
            } else if now {
                out.append(ParamChange(id: "bias", title: "Overall chart lean", before: b.bias, now: n.bias, effect: .favourable, weight: 1,
                                       advice: "Most indicators now point the trade's way."))
            }
        }
        return out.sorted { ($0.effect == .adverse ? 0 : 1, -$0.weight) < ($1.effect == .adverse ? 0 : 1, -$1.weight) }
    }

    static func status(_ changes: [ParamChange], r: Double?) -> WatchStatus {
        let adverse = changes.filter { $0.effect == .adverse }
        let against = adverse.reduce(0) { $0 + $1.weight }
        let favour = changes.filter { $0.effect == .favourable }.reduce(0) { $0 + $1.weight }
        if adverse.contains(where: { $0.weight >= 3 }) || against >= 5 { return .broken }
        if against >= 2 && against > favour { return .weakened }
        if favour >= 2 && against <= 1 { return .strengthened }
        if let r, r <= -0.75, against >= 1 { return .weakened }
        return .intact
    }

    /// Where the stop could go now: breakeven from +1R, behind the booked targets, then an ATR trail
    /// (highest high since entry − 2.5 ATR for longs). Only ever tighter than the current stop, and never
    /// closer than ½ ATR to the price. Nil when no move is worth making (< 0.1R).
    static func trail(_ t: Trade, price: Double, candlesSinceEntry: [Candle], atr: Double?) -> TrailSuggestion? {
        let s = TradeMath.summary(t, lastPrice: price)
        guard t.status == .open, let entry = s.averageEntry else { return nil }
        let risk = abs(entry - t.initialStop)
        guard risk > 0 else { return nil }
        let dir: Double = t.isLong ? 1 : -1
        let r = dir * (price - entry) / risk
        let booked = Set(t.fills.compactMap(\.takeProfitStage))
        var candidates: [(Double, String)] = []
        if r >= 1 { candidates.append((entry, "Breakeven — the trade can no longer lose")) }
        for stage in booked.sorted() {
            if stage >= 2, let prev = t.takeProfits.first(where: { $0.stage == stage - 1 })?.price {
                candidates.append((prev, "Behind TP\(stage - 1) after booking TP\(stage)"))
            }
        }
        if let atr, atr > 0, r >= 1.5, !candlesSinceEntry.isEmpty {
            let extreme = t.isLong ? candlesSinceEntry.map(\.high).max()! : candlesSinceEntry.map(\.low).min()!
            candidates.append((extreme - dir * 2.5 * atr, "ATR trail: \(t.isLong ? "highest high" : "lowest low") since entry \(t.isLong ? "−" : "+") 2.5 ATR"))
        }
        let buffer = (atr ?? risk * 0.5) * 0.5
        let valid = candidates.filter { c in
            let tighter = t.isLong ? c.0 > t.stopLoss : c.0 < t.stopLoss
            let room = t.isLong ? c.0 <= price - buffer : c.0 >= price + buffer
            return tighter && room
        }
        guard let best = valid.max(by: { dir * $0.0 < dir * $1.0 }) else { return nil }
        guard abs(best.0 - t.stopLoss) / risk >= 0.1 else { return nil }
        return TrailSuggestion(price: best.0, reason: best.1, lockedR: dir * (best.0 - entry) / risk)
    }

    /// Builds one check. `baseline` is the analysis's (or the first check's) parameters.
    static func check(_ t: Trade, baseline: WatchParams, snapshot: FeatureEngine.Snapshot, price: Double,
                      candles: [Candle], now: Date = Date()) -> TradeCheck {
        let current = WatchParams(snapshot, price: price)
        let decimals = FeatureEngine.decimals(price)
        let changes = compare(baseline: baseline, now: current, trade: t, decimals: decimals)
        let s = TradeMath.summary(t, lastPrice: price)
        let entryDate = t.fills.filter { $0.kind == .entry }.map(\.date).min() ?? t.createdAt
        let since = candles.filter { $0.time >= entryDate.addingTimeInterval(-snapshot.timeframe.seconds) }
        let trail = trail(t, price: price, candlesSinceEntry: since, atr: current.atr)
        return TradeCheck(at: now, price: price, r: s.rMultiple, status: status(changes, r: s.rMultiple), changes: changes, trail: trail)
    }

    /// Something worth a notification: the status got worse or better, or a new major change appeared.
    static func isNews(_ check: TradeCheck, previous: TradeCheck?) -> Bool {
        guard let previous else { return check.status != .intact || check.changes.contains { $0.weight >= 2 } }
        if check.status != previous.status { return true }
        let old = Set(previous.changes.map(\.id))
        return check.changes.contains { $0.weight >= 2 && !old.contains($0.id) }
    }
}
