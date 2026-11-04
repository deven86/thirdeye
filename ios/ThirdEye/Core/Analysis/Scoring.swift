import Foundation

/// One pass/fail check behind a verdict, listed on the report so the reason for "No trade" is never hidden.
nonisolated struct ScoreCheck: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var passed: Bool
    /// Blocking checks must all pass for Buy/Sell; the others are information.
    var blocking: Bool = true
}

/// Deterministic scoring. The AI produces stage scores; this code alone turns them into the 10–1000 number,
/// the checks and the verdict.
nonisolated enum Scoring {
    /// 1 = 0.4–0.7 (confidence-shrunk sum), 2 = 0.8 (confidence-weighted average plus checks).
    static let version = 2
    static let minimumStages = 7
    static let minimumEvidence = 0.35
    static let minimumSupport = 0.5
    static let maximumOpposition = 0.3
    /// No trade, but the number leans clearly one way: shown as "Watch".
    static let watchLong = 580
    static let watchShort = 430

    nonisolated struct Breakdown: Hashable, Sendable {
        var stage: Int
        var name: String
        var weight: Double
        var score: Int
        var confidence: Double
        var counted: Bool
        var share: Double         // this stage's share of the evidence (w × c), 0…1
        var contribution: Double  // points out of 1000
    }

    private static func weight(_ s: StageResult, _ profile: HoldingProfile) -> Double {
        s.stage >= 1 && s.stage <= 10 ? profile.weights[s.stage - 1] : 0
    }

    /// C = 10 × Σ(wᵢ·cᵢ·sᵢ) / Σ(wᵢ·cᵢ) over completed stages → 10…1000.
    /// Confidence decides how much a stage counts, not how far its score is pulled toward 50: in version 1
    /// both the model and the formula hedged, so even "every stage clearly bearish" scored 391 (No trade).
    static func composite(_ stages: [StageResult], profile: HoldingProfile) -> (value: Int, breakdown: [Breakdown]) {
        let sorted = stages.sorted { $0.stage < $1.stage }
        let denominator = sorted.filter { $0.status == .done }.reduce(0) { $0 + weight($1, profile) * $1.confidence }
        var total = 0.0
        let rows = sorted.map { s -> Breakdown in
            let w = weight(s, profile)
            let counted = s.status == .done && w > 0 && denominator > 0
            let share = counted ? w * s.confidence / denominator : 0
            let points = 10 * share * Double(s.score)
            total += points
            return Breakdown(stage: s.stage, name: s.name, weight: w, score: s.score,
                             confidence: s.status == .done ? s.confidence : 0, counted: counted, share: share, contribution: points)
        }
        return (denominator > 0 ? Int(total.rounded()) : 500, rows)
    }

    /// Version 1 (0.4–0.7), kept only to explain runs saved before 0.8:
    /// C = 10 × Σ wᵢ × (50 + cᵢ × (sᵢ − 50)) / 100, unavailable stages counted as 50.
    static func compositeV1(_ stages: [StageResult], profile: HoldingProfile) -> (value: Int, breakdown: [Breakdown]) {
        var total = 0.0
        let rows = stages.sorted { $0.stage < $1.stage }.map { s -> Breakdown in
            let w = weight(s, profile)
            let eff = s.status == .done ? s.effectiveScore : 50
            let points = 10 * w * eff / 100
            total += points
            return Breakdown(stage: s.stage, name: s.name, weight: w, score: s.score,
                             confidence: s.status == .done ? s.confidence : 0, counted: true, share: w / 100, contribution: points)
        }
        return (Int(total.rounded()), rows)
    }

    nonisolated struct Consensus: Hashable, Sendable {
        var completed: Int
        /// Σ(w × c) of completed stages ÷ Σ w of all stages: how much of the analysis rests on confident evidence.
        var evidence: Double
        /// Weight share of completed stages pointing the trade's way (score ≥ 55 for long, ≤ 45 for short).
        var support: Double
        var opposition: Double
    }

    static func consensus(_ stages: [StageResult], profile: HoldingProfile, side: String) -> Consensus {
        let done = stages.filter { $0.status == .done && weight($0, profile) > 0 }
        let totalWeight = profile.weights.reduce(0, +)
        let doneWeight = done.reduce(0) { $0 + weight($1, profile) }
        let evidence = totalWeight > 0 ? done.reduce(0) { $0 + weight($1, profile) * $1.confidence } / totalWeight : 0
        func share(_ test: (Int) -> Bool) -> Double {
            doneWeight > 0 ? done.filter { test($0.score) }.reduce(0) { $0 + weight($1, profile) } / doneWeight : 0
        }
        let long = side != "short"
        return Consensus(completed: stages.filter { $0.status == .done }.count, evidence: evidence,
                         support: share { long ? $0 >= 55 : $0 <= 45 },
                         opposition: share { long ? $0 <= 45 : $0 >= 55 })
    }

    nonisolated struct Evaluation: Sendable {
        var composite: Int
        var verdict: Verdict
        var side: String          // where the number points: long (≥ 505) or short
        var checks: [ScoreCheck]
        var cautions: [String]
        var grade: String?        // A+ / A / B when tradable
        var lean: String?         // long / short: not tradable, but worth watching
        var consensus: Consensus

        var vetoes: [String] { checks.filter { $0.blocking && !$0.passed }.map { "\($0.title): \($0.detail)" } }
    }

    static func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    /// Indian cash shares can be sold short only intraday.
    static func cannotHoldShort(_ i: Instrument, profile: HoldingProfile) -> Bool {
        i.provider == .upstox && (i.kind == .equity || i.kind == .etf) && profile != .scalpIntraday
    }

    /// Score, checks and verdict. Buy/Sell needs the number in a trade band AND every blocking check passed.
    static func evaluate(stages: [StageResult], plan: TradePlan?, lastCandleAge: TimeInterval?,
                         profile: HoldingProfile, instrument: Instrument) -> Evaluation {
        let c = composite(stages, profile: profile).value
        let band = Verdict(composite: c)
        let side = c >= 500 ? "long" : "short"
        let way = side == "long" ? "up" : "down"
        // Near 500 the number has no direction; say so instead of calling it "up" or "down".
        let balanced = band == .noTrade && abs(c - 500) < 30
        let cons = consensus(stages, profile: profile, side: side)
        let (up, down) = side == "long" ? (cons.support, cons.opposition) : (cons.opposition, cons.support)
        var checks: [ScoreCheck] = []

        checks.append(ScoreCheck(id: "score", title: "Score",
                                 detail: band == .noTrade ? "\(c) is in the No-trade band (381–619)" : "\(c) is in the \(band.title) band",
                                 passed: band != .noTrade))
        checks.append(ScoreCheck(id: "stages", title: "Stages completed",
                                 detail: "\(cons.completed) of 10 (needs \(minimumStages))", passed: cons.completed >= minimumStages))
        checks.append(ScoreCheck(id: "evidence", title: "Evidence strength",
                                 detail: "\(percent(cons.evidence)) (needs \(percent(minimumEvidence)))",
                                 passed: cons.evidence >= minimumEvidence))
        checks.append(ScoreCheck(id: "agreement", title: "Agreement",
                                 detail: balanced
                                    ? "balanced — \(percent(up)) of the analysis points up, \(percent(down)) down"
                                    : "\(percent(cons.support)) of the analysis points \(way), \(percent(cons.opposition)) against (needs ≥ 50% and ≤ 30%)",
                                 passed: !balanced && cons.support >= minimumSupport && cons.opposition <= maximumOpposition))
        if let age = lastCandleAge {
            let limit: TimeInterval = profile.planTimeframe.isIntraday ? 3 * 3600 : 5 * 86_400
            checks.append(ScoreCheck(id: "data", title: "Fresh price data",
                                     detail: age > limit ? "last bar is \(Int(age / 3600)) hours old" : "up to date", passed: age <= limit))
        }
        // Only events specific to this product block a trade (its results, dividend, index change, token unlock…).
        // Market-wide data happens every few days and becomes a caution instead.
        // Long holds (positional, long-term) always span a results date, so for them only the next 14 days block.
        let holding = plan?.holdingDays ?? profile.maxHoldingDays
        let longHold: [HoldingProfile] = [.positional, .longTerm, .equal]
        let blockWindow = longHold.contains(profile) ? min(holding, 14) : holding
        if let s2 = stages.first(where: { $0.stage == 2 && $0.status == .done }) {
            let knowledgeOnly = !s2.usedWebSearch ? " (model knowledge only — verify the date)" : ""
            if let d = s2.extra["next_major_event_days"].flatMap(Int.init), d >= 0 {
                let blocks = d <= blockWindow
                let detail = blocks ? "a product-specific event is due in \(d) day\(d == 1 ? "" : "s")\(knowledgeOnly)"
                    : d <= holding ? "next one in \(d) days — inside the holding period, so expect a possible gap\(knowledgeOnly)"
                    : "next one in \(d) days, after the holding period"
                checks.append(ScoreCheck(id: "event", title: "No product event soon", detail: detail, passed: !blocks))
            } else if s2.extra["next_major_event_checked"] == "1" || s2.extra["next_major_event_days"] != nil {
                checks.append(ScoreCheck(id: "event", title: "No product event soon", detail: "none found\(knowledgeOnly)", passed: true))
            } else {
                checks.append(ScoreCheck(id: "event", title: "No product event soon",
                                         detail: "the event stage did not answer this — check results dates yourself", passed: false, blocking: false))
            }
        } else {
            checks.append(ScoreCheck(id: "event", title: "No product event soon",
                                     detail: "event calendar stage unavailable — check results dates yourself", passed: false, blocking: false))
        }
        if let plan {
            if plan.side != side || balanced {
                checks.append(ScoreCheck(id: "plan", title: "Trade plan",
                                         detail: balanced ? "the final stage proposed a \(plan.side) plan, but the score has no clear direction"
                                                          : "the final stage proposed a \(plan.side) plan, but the score points \(way)", passed: false))
            } else if !plan.issues.isEmpty {
                checks.append(ScoreCheck(id: "plan", title: "Trade plan", detail: plan.issues.joined(separator: " · "), passed: false))
            } else {
                checks.append(ScoreCheck(id: "plan", title: "Trade plan", detail: "entry, stop and targets checked", passed: true))
            }
        } else {
            checks.append(ScoreCheck(id: "plan", title: "Trade plan", detail: "the final stage gave no entry and stop", passed: false))
        }
        if band == .sell || band == .strongSell, cannotHoldShort(instrument, profile: profile) {
            checks.append(ScoreCheck(id: "short", title: "Can be held short",
                                     detail: "Indian shares can't be held short overnight — read this as \"avoid / exit if holding\"",
                                     passed: false))
        }

        let tradable = band != .noTrade && checks.allSatisfy { !$0.blocking || $0.passed }
        let verdict = tradable ? band : .noTrade
        var lean: String?
        if !tradable {
            if c >= watchLong { lean = "long" }
            else if c <= watchShort, !cannotHoldShort(instrument, profile: profile) { lean = "short" }
        }
        return Evaluation(composite: c, verdict: verdict, side: side, checks: checks,
                          cautions: cautions(stages: stages, profile: profile),
                          grade: tradable ? grade(composite: c, consensus: cons) : nil, lean: lean, consensus: cons)
    }

    /// A+ needs the Strong band, strong evidence and near-unanimous agreement; A most of that; B = passes the checks.
    static func grade(composite: Int, consensus: Consensus) -> String {
        let distance = abs(composite - 500)   // bands are symmetric around 500: 620/380 and 750/250
        var points = distance >= 250 ? 2 : distance >= 170 ? 1 : 0
        points += consensus.evidence >= 0.65 ? 2 : consensus.evidence >= 0.5 ? 1 : 0
        points += consensus.support >= 0.85 && consensus.opposition <= 0.05 ? 2
            : consensus.support >= 0.65 && consensus.opposition <= 0.2 ? 1 : 0
        return points >= 6 ? "A+" : points >= 4 ? "A" : "B"
    }

    /// Version-1 veto list, kept for the existing tests and older callers.
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
            out.append("A product-specific event falls inside the holding period (in \(d) day\(d == 1 ? "" : "s")).")
        }
        if let plan, !plan.issues.isEmpty {
            out.append(contentsOf: plan.issues.map { "Trade plan check: \($0)" })
        }
        return out
    }

    /// Non-blocking cautions shown on the report.
    static func cautions(stages: [StageResult], profile: HoldingProfile) -> [String] {
        guard let s2 = stages.first(where: { $0.stage == 2 }),
              let d = s2.extra["next_macro_event_days"].flatMap(Int.init), d >= 0, d <= min(profile.maxHoldingDays, 7) else { return [] }
        return ["Market-wide data or a central-bank decision is due in \(d) day\(d == 1 ? "" : "s") — expect volatility."]
    }

    static func verdict(composite: Int, vetoes: [String]) -> Verdict {
        vetoes.isEmpty ? Verdict(composite: composite) : .noTrade
    }

    /// Nearest support below and resistance above the price, as plain-English levels to watch.
    static func watchLevels(zones: [Levels.Zone], lastPrice: Double, lean: String?, currency: String,
                            includeShort: Bool = true) -> [String] {
        func fmt(_ v: Double) -> String {
            v.formatted(.number.precision(.fractionLength(FeatureEngine.decimals(v))).grouping(.automatic)
                .locale(Locale(identifier: currency == "INR" ? "en_IN" : "en_US")))
        }
        var out: [String] = []
        if let r = zones.filter({ $0.kind == .resistance && $0.price > lastPrice }).min(by: { $0.price < $1.price }) {
            out.append("Long case improves on a close above \(fmt(r.price)) (resistance, \(r.touches) touch\(r.touches == 1 ? "" : "es")).")
        }
        if let s = zones.filter({ $0.kind == .support && $0.price < lastPrice }).max(by: { $0.price < $1.price }) {
            out.append(includeShort
                       ? "Short case improves on a close below \(fmt(s.price)) (support, \(s.touches) touch\(s.touches == 1 ? "" : "es"))."
                       : "The long case weakens on a close below \(fmt(s.price)) (support, \(s.touches) touch\(s.touches == 1 ? "" : "es")).")
        }
        return lean == "short" && includeShort ? out.reversed() : out
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
