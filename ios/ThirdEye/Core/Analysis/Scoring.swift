import Foundation

/// Deterministic scoring. The AI produces stage scores; this code alone turns them into the 0–1000 number.
nonisolated enum Scoring {
    static let minimumStages = 7

    nonisolated struct Breakdown: Hashable, Sendable {
        var stage: Int
        var name: String
        var weight: Double
        var score: Int
        var confidence: Double
        var effective: Double
        var contribution: Double   // points out of 1000
    }

    /// C = 10 × Σ(wᵢ × s_effᵢ) / 100 → 10…1000.
    static func composite(_ stages: [StageResult], profile: HoldingProfile) -> (value: Int, breakdown: [Breakdown]) {
        let weights = profile.weights
        var total = 0.0
        var rows: [Breakdown] = []
        for s in stages.sorted(by: { $0.stage < $1.stage }) {
            let w = s.stage >= 1 && s.stage <= 10 ? weights[s.stage - 1] : 0
            let eff = s.status == .done ? s.effectiveScore : 50
            let points = 10 * w * eff / 100
            total += points
            rows.append(Breakdown(stage: s.stage, name: s.name, weight: w, score: s.score,
                                  confidence: s.status == .done ? s.confidence : 0, effective: eff, contribution: points))
        }
        return (Int(total.rounded()), rows)
    }

    /// Reasons that force "No trade" regardless of the number.
    static func vetoes(stages: [StageResult], plan: TradePlan?, lastCandleAge: TimeInterval?, timeframe: Timeframe,
                       profile: HoldingProfile) -> [String] {
        var out: [String] = []
        let available = stages.filter { $0.status == .done }.count
        if available < minimumStages {
            out.append("Only \(available) of 10 stages completed — not enough evidence.")
        }
        if let age = lastCandleAge {
            let limit: TimeInterval = timeframe.isIntraday ? 3 * 3600 : 5 * 86_400
            if age > limit { out.append("Price data is stale (last bar \(Int(age / 3600)) hours old).") }
        }
        if let s2 = stages.first(where: { $0.stage == 2 }), let d = s2.extra["next_major_event_days"].flatMap(Int.init),
           d >= 0, d <= profile.maxHoldingDays {
            out.append("A major scheduled event falls inside the holding period (in \(d) day\(d == 1 ? "" : "s")).")
        }
        if let plan, !plan.issues.isEmpty {
            out.append(contentsOf: plan.issues.map { "Trade plan check: \($0)" })
        }
        return out
    }

    static func verdict(composite: Int, vetoes: [String]) -> Verdict {
        vetoes.isEmpty ? Verdict(composite: composite) : .noTrade
    }
}

/// Builds and validates the trade plan from stage 10's entry/stop, entirely in code.
nonisolated enum TradePlanner {
    nonisolated struct Proposal: Sendable {
        var side: String
        var entryLow: Double
        var entryHigh: Double
        var stopLoss: Double
        var holdingDays: Int
        var invalidation: String
        var rationale: String
    }

    /// Default 5-stage ladder: 1R 30 % (stop → breakeven), 2R 25 %, 3R 20 %, 4R 15 %, runner 10 %.
    static let ladder5: [(r: Double?, pct: Double, then: String)] = [
        (1, 30, "Move stop to breakeven — rest of the trade is now risk-free"),
        (2, 25, "Trail stop to TP1"),
        (3, 20, "Trail stop to TP2"),
        (4, 15, "Trail stop to TP3"),
        (nil, 10, "Runner with ATR trailing stop"),
    ]
    static let ladder3: [(r: Double?, pct: Double, then: String)] = [
        (1, 40, "Move stop to breakeven"),
        (2, 35, "Trail stop to TP1"),
        (nil, 25, "Runner with ATR trailing stop"),
    ]

    static func build(_ p: Proposal, lastPrice: Double, atr: Double?, tick: Double?, stages: Int = 5, now: Date = Date()) -> TradePlan {
        let long = p.side == "long"
        let lo = min(p.entryLow, p.entryHigh), hi = max(p.entryLow, p.entryHigh)
        let entry = (lo + hi) / 2
        let risk = abs(entry - p.stopLoss)
        var issues: [String] = []

        if long && p.stopLoss >= lo { issues.append("Stop-loss is not below the entry zone.") }
        if !long && p.stopLoss <= hi { issues.append("Stop-loss is not above the entry zone.") }
        if risk <= 0 { issues.append("Zero risk distance.") }
        if let atr, atr > 0 {
            if abs(entry - lastPrice) > 3 * atr { issues.append("Entry is more than 3 ATR away from the current price.") }
            if risk > 4 * atr { issues.append("Stop is more than 4 ATR from entry — risk too wide.") }
            if risk < 0.25 * atr { issues.append("Stop is within normal noise (under ¼ ATR).") }
        }

        /// Snap to the tick, then trim binary noise (2100 × 0.05 = 105.00000000000001).
        func round(_ v: Double) -> Double {
            guard let tick, tick > 0 else { return v }
            let snapped = (v / tick).rounded() * tick
            let places = max(0, Int(ceil(-log10(tick))))
            let scale = pow(10, Double(places))
            return (snapped * scale).rounded() / scale
        }
        let ladder = stages == 3 ? ladder3 : ladder5
        let tps = ladder.enumerated().map { i, step -> TakeProfit in
            let price = step.r.map { round(long ? entry + $0 * risk : entry - $0 * risk) }
            return TakeProfit(stage: i + 1, price: price, rMultiple: step.r, bookPercent: step.pct, then: step.then)
        }
        if let tp = tps.compactMap(\.price).first, (long && tp <= entry) || (!long && tp >= entry) {
            issues.append("Targets are on the wrong side of entry.")
        }
        let days = max(p.holdingDays, 0)
        return TradePlan(side: long ? "long" : "short",
                         entryLow: round(lo), entryHigh: round(hi), stopLoss: round(p.stopLoss),
                         takeProfits: tps, riskPerUnit: risk, rewardRiskAtTP2: 2,
                         holdingDays: days, badge: HoldingBadge.from(days: days),
                         completeBy: Calendar(identifier: .gregorian).date(byAdding: .day, value: max(days, 1), to: now)!,
                         invalidation: p.invalidation, rationale: p.rationale, issues: issues)
    }
}

/// Model prices (USD per 1M tokens). Mirrors shared/config/model_prices.json; matched by ID prefix.
nonisolated enum Pricing {
    nonisolated struct Price { var input: Double; var output: Double }

    static let table: [(prefix: String, price: Price)] = [
        ("claude-haiku", Price(input: 0.10, output: 0.50)),
        ("claude-sonnet", Price(input: 2.00, output: 10.00)),
        ("claude-opus", Price(input: 4.00, output: 20.00)),
        ("claude-fable", Price(input: 10.00, output: 50.00)),
        ("claude-mythos", Price(input: 10.00, output: 50.00)),
        ("gpt-5-nano", Price(input: 0.05, output: 0.40)),
        ("gpt-5-mini", Price(input: 0.25, output: 2.00)),
        ("gpt-5.4", Price(input: 2.50, output: 15.00)),
        ("gpt-5.5", Price(input: 5.00, output: 30.00)),
        ("gemini-2.5-flash-lite", Price(input: 0.10, output: 0.40)),
        ("gemini-3.1-pro", Price(input: 2.00, output: 12.00)),
    ]
    static let fallback = Price(input: 5.00, output: 25.00) // unknown model: assume expensive
    static let webSearchPerRequest = 0.01

    static func price(for model: String) -> Price {
        table.first { model.lowercased().hasPrefix($0.prefix) }?.price ?? fallback
    }

    /// Cache reads ≈ 0.1× input, cache writes ≈ 1.25× input (Anthropic).
    static func cost(_ u: AIUsage, model: String) -> Double {
        let p = price(for: model)
        let input = Double(u.inputTokens) * p.input + Double(u.cacheReadTokens) * p.input * 0.1
            + Double(u.cacheWriteTokens) * p.input * 1.25
        return (input + Double(u.outputTokens) * p.output) / 1_000_000 + Double(u.webSearches) * webSearchPerRequest
    }
}
