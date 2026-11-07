import Foundation

// MARK: - Extra Search (0.15.0)
//
// An optional second opinion on a finished analysis, switched on in Settings → Extra Search.
// It never changes the normal analysis: it reads a saved AnalysisRun, runs its own prompts and stores its own
// result next to it. The normal score, verdict, checks, plan, prompts and report card are untouched.

/// Stage groups used to spot disagreements inside one analysis.
nonisolated enum ExtraConflicts {
    nonisolated struct Group: Sendable {
        var id: String
        var title: String
        var stages: [Int]
    }

    static let groups: [Group] = [
        Group(id: "news", title: "News & events", stages: [1, 2]),
        Group(id: "business", title: "Business & context", stages: [3, 4, 7, 8]),
        Group(id: "chart", title: "Charts & momentum", stages: [5, 6, 9]),
    ]

    /// A group (or stage 10) leans up at ≥ 58 and down at ≤ 42 on the 1–100 stage scale.
    static let upAt = 58
    static let downAt = 42

    nonisolated struct Lean: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        var score: Int          // confidence-weighted 1…100 of the group's completed stages
        var evidence: Double    // Σ(w × c) of those stages — how much the group counts
        var stages: [Int]

        var direction: String { score >= ExtraConflicts.upAt ? "up" : score <= ExtraConflicts.downAt ? "down" : "neutral" }
    }

    nonisolated struct Conflict: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var text: String
        var strong: Bool        // the two sides are 30+ points apart
    }

    private static func weight(_ stage: Int, _ profile: HoldingProfile) -> Double {
        stage >= 1 && stage <= 10 ? profile.weights[stage - 1] : 0
    }

    /// Same formula as the main score (Σ w·c·s / Σ w·c), applied to one group of stages.
    static func lean(_ stages: [StageResult], ids: [Int], profile: HoldingProfile) -> (score: Int, evidence: Double)? {
        let done = stages.filter { ids.contains($0.stage) && $0.status == .done && weight($0.stage, profile) > 0 }
        let denominator = done.reduce(0.0) { $0 + weight($1.stage, profile) * $1.confidence }
        guard denominator > 0 else { return nil }
        let numerator = done.reduce(0.0) { $0 + weight($1.stage, profile) * $1.confidence * Double($1.score) }
        return (Int((numerator / denominator).rounded()), denominator)
    }

    static func leans(_ stages: [StageResult], profile: HoldingProfile) -> [Lean] {
        groups.compactMap { g in
            lean(stages, ids: g.stages, profile: profile).map {
                Lean(id: g.id, title: g.title, score: $0.score, evidence: $0.evidence, stages: g.stages)
            }
        }
    }

    /// Code-only, free: pairs of groups that point opposite ways, and a final stage that contradicts stages 1–9.
    static func conflicts(_ stages: [StageResult], profile: HoldingProfile) -> [Conflict] {
        let all = leans(stages, profile: profile)
        var out: [Conflict] = []
        for i in all.indices {
            for j in all.indices where j > i {
                let a = all[i], b = all[j]
                let pair: (up: Lean, down: Lean)
                if a.score >= upAt && b.score <= downAt { pair = (a, b) }
                else if b.score >= upAt && a.score <= downAt { pair = (b, a) }
                else { continue }
                let up = pair.up, down = pair.down
                out.append(Conflict(id: "\(up.id)-\(down.id)",
                                    text: "\(up.title) point up (\(up.score)) but \(down.title.lowercased()) point down (\(down.score)).",
                                    strong: up.score - down.score >= 30))
            }
        }
        if let s10 = stages.first(where: { $0.stage == 10 && $0.status == .done }),
           let rest = lean(stages, ids: Array(1...9), profile: profile) {
            let finalUp = s10.score >= upAt, finalDown = s10.score <= downAt
            let restUp = rest.score >= upAt, restDown = rest.score <= downAt
            if (finalUp && restDown) || (finalDown && restUp) {
                out.append(Conflict(id: "final-rest",
                                    text: "The final stage says \(finalUp ? "up" : "down") (\(s10.score)) while stages 1–9 together say \(restUp ? "up" : "down") (\(rest.score)).",
                                    strong: abs(s10.score - rest.score) >= 30))
            }
        }
        return out
    }

    /// The single most bullish and most bearish confident stage — shown so the user sees the two extremes.
    static func extremes(_ stages: [StageResult]) -> (bull: StageResult?, bear: StageResult?) {
        let done = stages.filter { $0.status == .done && $0.confidence >= 0.4 }
        let bull = done.filter { $0.score >= upAt }.max { $0.score < $1.score }
        let bear = done.filter { $0.score <= downAt }.min { $0.score < $1.score }
        return (bull, bear)
    }
}

/// How much the stages disagree, shown as "± N" next to the score. Not a statistical confidence interval:
/// it is the weighted spread of the stage scores divided by √(effective number of stages), in 1000-scale points.
nonisolated enum ExtraSpread {
    static func points(_ stages: [StageResult], profile: HoldingProfile) -> Int? {
        let (value, rows) = Scoring.composite(stages, profile: profile)
        let counted = rows.filter { $0.counted && $0.share > 0 }
        guard counted.count >= 3 else { return nil }
        let mean = Double(value) / 10
        let variance = counted.reduce(0.0) { $0 + $1.share * pow(Double($1.score) - mean, 2) }
        let shareSquares = counted.reduce(0.0) { $0 + $1.share * $1.share }
        guard shareSquares > 0 else { return nil }
        let effective = 1 / shareSquares
        let se = (variance / effective).squareRoot() * 10
        let rounded = Int((se / 5).rounded()) * 5
        return min(max(rounded, 5), 200)
    }
}

/// Position size advice from India VIX (fear gauge). Advice only: the quantity you type is never changed for you.
nonisolated enum VIXSizing {
    static let instrument = Instrument(id: "NSE_INDEX|India VIX", provider: .upstox, symbol: "INDIAVIX", name: "India VIX",
                                       exchange: "NSE", segment: "NSE_INDEX", kind: .index, currency: "INR")

    /// Only Indian products (Upstox) — India VIX says nothing about crypto or US shares.
    static func applies(to i: Instrument) -> Bool { i.provider == .upstox && i.kind != .index }

    /// 100 % below 15 · 85 % at 15–20 · 65 % at 20–25 · 50 % above 25.
    static func multiplier(vix: Double) -> Double {
        switch vix {
        case ..<15: 1
        case ..<20: 0.85
        case ..<25: 0.65
        default: 0.5
        }
    }

    static func band(vix: Double) -> String {
        switch vix {
        case ..<15: "calm"
        case ..<20: "normal"
        case ..<25: "nervous"
        default: "fearful"
        }
    }

    /// Normal quantity × multiplier, rounded down to the lot size (whole shares at least).
    static func adjusted(quantity: Double, multiplier: Double, lotSize: Double?) -> Double {
        guard quantity > 0 else { return 0 }
        let raw = quantity * multiplier
        let lot = max(lotSize ?? 1, 1)
        return (raw / lot + 1e-9).rounded(.down) * lot
    }
}

/// Past analyses of the same product and how they turned out — taken from the existing report card grading.
nonisolated enum DecisionMemory {
    nonisolated struct Item: Codable, Hashable, Sendable, Identifiable {
        var id: UUID              // the past run
        var date: Date
        var composite: Int
        var verdict: String
        var graded: Bool
        var directionRight: Bool?
        var forwardReturnPct: Double?
        var horizonDays: Int?
        var planR: Double?
        var extraStance: String?  // what an earlier Extra Search said about that run, if one was made
    }

    static func items(for instrument: Instrument, excluding runID: UUID, runs: [AnalysisRun],
                      outcomes: [UUID: AnalysisOutcome], extras: [ExtraSearchResult], limit: Int = 6) -> [Item] {
        runs.filter { $0.instrument.id == instrument.id && $0.id != runID && $0.finishedAt != nil }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { r in
                let o = outcomes[r.id]
                let extra = extras.filter { $0.runID == r.id }.max { $0.createdAt < $1.createdAt }
                return Item(id: r.id, date: r.startedAt, composite: r.composite ?? 500,
                            verdict: Verdict(rawValue: r.verdict ?? "")?.title ?? "No trade", graded: o != nil,
                            directionRight: o?.directionRight, forwardReturnPct: o?.forwardReturnPct,
                            horizonDays: o?.horizonDays, planR: o?.planR, extraStance: extra?.judge?.stance)
            }
    }

    static func promptText(_ items: [Item], card: ReportCard) -> String {
        var lines: [String] = []
        if items.isEmpty {
            lines.append("No earlier analyses of this product.")
        } else {
            lines.append("Earlier analyses of this product (newest first):")
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.locale = Locale(identifier: "en_US_POSIX")
            for i in items {
                var l = "- \(df.string(from: i.date)): score \(i.composite) (\(i.verdict))"
                if i.graded {
                    if let right = i.directionRight { l += "; price went the score's way: \(right ? "yes" : "no")" } else { l += "; score had no direction" }
                    if let r = i.forwardReturnPct, let d = i.horizonDays { l += "; \(String(format: "%+.1f", r))% over \(d) days" }
                    if let pr = i.planR { l += "; plan result \(String(format: "%+.2f", pr))R" }
                } else {
                    l += "; not graded yet"
                }
                if let s = i.extraStance { l += "; earlier Extra Search said \(s)" }
                lines.append(l)
            }
        }
        if card.graded > 0 {
            var l = "Across all products: \(card.graded) graded analyses"
            if let p = card.directionRightPct { l += ", direction right \(Int(p.rounded()))%" }
            if let w = card.tradeWinPct, card.tradesEntered > 0 { l += ", recommended trades ended in profit \(Int(w.rounded()))% of \(card.tradesEntered)" }
            lines.append(l + ".")
        }
        if card.graded < ReportCard.minimumForConclusions {
            lines.append("This track record is too small to prove anything — treat it as context only.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Result

nonisolated struct ExtraCase: Codable, Hashable, Sendable {
    var side: String          // bull / bear
    var summary: String
    var points: [String]
    var strength: Int         // 1…100: how strong this side's case honestly is
    var model: String?
    var costUSD: Double
    var rawOutput: String
}

nonisolated struct ExtraJudgement: Codable, Hashable, Sendable {
    var score: Int            // 1…100, same scale as the stages
    var confidence: Double
    var stance: String        // agree / more_cautious / disagree
    var action: String        // take / reduce_size / wait / avoid
    var summary: String
    var deciding: [String]
    var risks: [String]
    var changeMind: String
    var model: String?
    var costUSD: Double
    var rawOutput: String

    var stanceTitle: String {
        switch stance {
        case "agree": "Agrees with the analysis"
        case "disagree": "Disagrees with the analysis"
        default: "More cautious than the analysis"
        }
    }

    var actionTitle: String {
        switch action {
        case "take": "Take the trade"
        case "reduce_size": "Take it smaller"
        case "avoid": "Avoid"
        default: "Wait"
        }
    }
}

nonisolated struct ExtraSearchResult: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var runID: UUID
    var instrumentID: String
    var createdAt: Date
    var normalComposite: Int
    var normalVerdict: String
    var spread: Int?
    var leans: [ExtraConflicts.Lean]
    var conflicts: [ExtraConflicts.Conflict]
    var memory: [DecisionMemory.Item]
    var bull: ExtraCase?
    var bear: ExtraCase?
    var judge: ExtraJudgement?
    var failures: [String]
    var totalCostUSD: Double
    var promptVersion: String

    /// The judge's score on the 10–1000 scale, for a side-by-side with the normal score.
    var extraScore: Int? { judge.map { $0.score * 10 } }

    /// Where the judge points: long ≥ 530, short ≤ 470, otherwise no direction.
    var extraSide: String? {
        guard let s = extraScore else { return nil }
        return s >= 530 ? "long" : s <= 470 ? "short" : nil
    }
}

// MARK: - Prompts (Extra Search only — the normal stage prompts are not touched)

nonisolated enum ExtraPrompts {
    static let version = "x1-2026-11-07"

    static func advocateSystem(bull: Bool) -> String {
        """
        You are one side of a structured debate inside Third Eye's Extra Search, a private analysis tool used by \
        one person who makes their own trading decisions. You receive a finished 10-stage analysis of one product: \
        each stage's score, confidence, summary and evidence, the computed checks and the trade plan.

        Your job: make the honest \(bull ? "BULL case — why the price is more likely to go UP" : "BEAR case — why the price is more likely to go DOWN") \
        over the stated holding period, as strongly as the evidence allows and no further.

        Rules — follow all of them:
        1. Use only facts in the material provided. Never invent numbers, prices, dates, news or quotes.
        2. Point to where each argument comes from: a stage ("S6") or a feature ID exactly as given (e.g. "D.RSI14").
        3. If the evidence for your side is weak, say so plainly and give a low strength. A weak honest case beats a strong invented one.
        4. "strength" is an integer 1–100: how convincing your side's case honestly is (50 = as strong as the other side could be).
        5. "summary" at most 60 words. "points": 3–5 items, each under 30 words.
        6. Output ONLY one JSON object: {"summary": "<text>", "points": ["<text>", ...], "strength": <int>}
        """
    }

    static let judgeSystem = """
    You are the judge in Third Eye's Extra Search, a private analysis tool used by one person who makes their own \
    trading decisions and asked for a second opinion before a large trade. You receive: a finished 10-stage \
    analysis, a bull case and a bear case written by two other analysts, disagreements between stage groups \
    computed in code, and this person's track record of earlier analyses of the same product.

    Weigh the two cases by the quality of their evidence, not by how confident they sound. Rules — follow all of them:
    1. Use only facts in the material provided. Never invent numbers, prices, dates or news.
    2. "score" is an integer 1–100 for the direction of the price over the holding period, same anchors as the \
    analysis: 50 = no edge; 60/40 slight lean; 70/30 clear lean, a typical tradable setup; 80/20 strong; 90+/10− rare. \
    Do not pull the score toward 50 because you are unsure — put doubt in "confidence" (0.0–1.0).
    3. "stance": "agree" if you would keep the analysis's verdict, "more_cautious" if the direction is right but the \
    case is weaker than it looks, "disagree" if you think the verdict points the wrong way.
    4. "action": "take", "reduce_size", "wait" or "avoid" — for this person, for this trade, now.
    5. "deciding": 2–4 short points that decided it. "risks": 1–3 biggest risks. "change_mind": one sentence — \
    the observable thing that would change your decision.
    6. Treat the track record as context. A handful of past results proves little; say so if you rely on it.
    7. "summary" at most 60 words, plain English.
    8. Output ONLY one JSON object with exactly these fields.
    """

    static let advocateSchema: JSONValue = .object([
        ("type", .string("object")),
        ("properties", .object([
            ("summary", .object([("type", .string("string"))])),
            ("points", .object([("type", .string("array")), ("items", .object([("type", .string("string"))]))])),
            ("strength", .object([("type", .string("integer"))])),
        ])),
        ("required", .array([.string("summary"), .string("points"), .string("strength")])),
        ("additionalProperties", .bool(false)),
    ])

    static let judgeSchema: JSONValue = .object([
        ("type", .string("object")),
        ("properties", .object([
            ("score", .object([("type", .string("integer"))])),
            ("confidence", .object([("type", .string("number"))])),
            ("stance", .object([("type", .string("string")), ("enum", .array(["agree", "more_cautious", "disagree"].map { .string($0) }))])),
            ("action", .object([("type", .string("string")), ("enum", .array(["take", "reduce_size", "wait", "avoid"].map { .string($0) }))])),
            ("summary", .object([("type", .string("string"))])),
            ("deciding", .object([("type", .string("array")), ("items", .object([("type", .string("string"))]))])),
            ("risks", .object([("type", .string("array")), ("items", .object([("type", .string("string"))]))])),
            ("change_mind", .object([("type", .string("string"))])),
        ])),
        ("required", .array(["score", "confidence", "stance", "action", "summary", "deciding", "risks", "change_mind"].map { .string($0) })),
        ("additionalProperties", .bool(false)),
    ])

    /// The finished analysis as text: what both advocates and the judge read.
    static func analysisBrief(_ run: AnalysisRun) -> String {
        var l: [String] = []
        let i = run.instrument
        l.append("Product: \(i.symbol) (\(i.name)) · \(i.kind.title) · \(i.exchange) · quoted in \(i.currency)")
        l.append("Holding profile: \(run.profile.title) (\(run.profile.subtitle))")
        if let p = run.lastPrice { l.append("Last price when analysed: \(p)") }
        l.append("Analysed: \(run.startedAt.formatted(.iso8601))")
        let verdict = Verdict(rawValue: run.verdict ?? "")?.title ?? "No trade"
        l.append("Analysis result: score \(run.composite ?? 500) of 1000 → \(verdict)\(run.grade.map { ", grade \($0)" } ?? "")\(run.lean.map { ", leans \($0)" } ?? "")")
        if let checks = run.checks, !checks.isEmpty {
            l.append("Checks:")
            for c in checks { l.append("- [\(c.passed ? "pass" : "FAIL")\(c.blocking ? "" : ", info")] \(c.title): \(c.detail)") }
        }
        if let cautions = run.cautions, !cautions.isEmpty { l.append("Cautions: " + cautions.joined(separator: " | ")) }
        if let plan = run.plan {
            let tps = plan.takeProfits.compactMap(\.price).map { String($0) }.joined(separator: ", ")
            l.append("Trade plan: \(plan.side), entry \(plan.entryLow)–\(plan.entryHigh), stop \(plan.stopLoss), targets \(tps), \(plan.holdingDays) days. Invalidation: \(plan.invalidation)")
            if !plan.issues.isEmpty { l.append("Plan issues: " + plan.issues.joined(separator: " | ")) }
        } else {
            l.append("Trade plan: none proposed.")
        }
        if let base = run.baseRate {
            l.append("History check of this plan shape on this product (not a forecast): \(base.independent) independent past trades, "
                     + "stop hit first \(Int((base.stopFirstPct * 100).rounded()))%, TP1 \(Int((base.tp1Pct * 100).rounded()))%, "
                     + "win after costs \(Int((base.winPct * 100).rounded()))%, average \(String(format: "%+.2f", base.averageR))R, "
                     + "longest losing streak \(base.longestLosingStreak).")
        }
        l.append("")
        l.append("STAGES (score 1 bearish … 50 neutral … 100 bullish; weight is this profile's share of 100):")
        for s in run.stages.sorted(by: { $0.stage < $1.stage }) {
            let w = run.profile.weights[max(min(s.stage, 10), 1) - 1]
            switch s.status {
            case .done:
                l.append("S\(s.stage) \(s.name) · score \(s.score) · confidence \(String(format: "%.2f", s.confidence)) · weight \(Int(w))\(s.usedWebSearch ? "" : " · no web search")")
                l.append("  Summary: \(s.summary)")
                for r in s.reasons { l.append("  • \(r.point) [impact \(r.impact); evidence: \(r.evidence.joined(separator: ", "))]") }
            case .skipped:
                l.append("S\(s.stage) \(s.name) · skipped by the user")
            default:
                l.append("S\(s.stage) \(s.name) · unavailable")
            }
        }
        return l.joined(separator: "\n")
    }

    static func advocateUser(_ run: AnalysisRun, bull: Bool) -> String {
        "Write the \(bull ? "BULL" : "BEAR") case for this analysis.\n\n" + analysisBrief(run)
    }

    static func judgeUser(_ run: AnalysisRun, bull: ExtraCase?, bear: ExtraCase?, conflicts: [ExtraConflicts.Conflict],
                          leans: [ExtraConflicts.Lean], memory: String) -> String {
        var l: [String] = [analysisBrief(run), ""]
        l.append("STAGE GROUPS (computed in code):")
        for g in leans { l.append("- \(g.title) (S\(g.stages.map(String.init).joined(separator: ",S"))): \(g.score) → \(g.direction)") }
        l.append(conflicts.isEmpty ? "No disagreements between stage groups." : "DISAGREEMENTS:")
        for c in conflicts { l.append("- \(c.text)\(c.strong ? " (strong)" : "")") }
        l.append("")
        for (title, c) in [("BULL CASE", bull), ("BEAR CASE", bear)] {
            if let c {
                l.append("\(title) (its own strength rating \(c.strength)/100): \(c.summary)")
                for p in c.points { l.append("  • \(p)") }
            } else {
                l.append("\(title): unavailable.")
            }
        }
        l.append("")
        l.append("TRACK RECORD:")
        l.append(memory)
        l.append("")
        l.append("Give your judgement as the JSON object.")
        return l.joined(separator: "\n")
    }

    // MARK: Parsing (nothing from the model reaches the screen unvalidated)

    static func strings(_ v: Any?, max count: Int, maxLength: Int = 240) -> [String] {
        ((v as? [Any]) ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(count)
            .map { String($0.prefix(maxLength)) }
    }

    static func parseCase(_ text: String, bull: Bool, model: String?, cost: Double) -> ExtraCase? {
        guard let obj = try? StageParser.extractObject(text),
              let summary = obj["summary"] as? String, !summary.isEmpty else { return nil }
        let strength = Int(StageParser.number(obj["strength"]) ?? 50)
        return ExtraCase(side: bull ? "bull" : "bear", summary: String(summary.prefix(500)),
                         points: strings(obj["points"], max: 5), strength: min(max(strength, 1), 100),
                         model: model, costUSD: cost, rawOutput: text)
    }

    static func parseJudgement(_ text: String, model: String?, cost: Double) -> ExtraJudgement? {
        guard let obj = try? StageParser.extractObject(text),
              let rawScore = StageParser.number(obj["score"]) else { return nil }
        let stance = (obj["stance"] as? String).flatMap { ["agree", "more_cautious", "disagree"].contains($0) ? $0 : nil } ?? "more_cautious"
        let action = (obj["action"] as? String).flatMap { ["take", "reduce_size", "wait", "avoid"].contains($0) ? $0 : nil } ?? "wait"
        let confidence = min(max(StageParser.number(obj["confidence"]) ?? 0.3, 0), 1)
        return ExtraJudgement(score: min(max(Int(rawScore.rounded()), 1), 100), confidence: confidence,
                              stance: stance, action: action,
                              summary: String(((obj["summary"] as? String) ?? "").prefix(500)),
                              deciding: strings(obj["deciding"], max: 4), risks: strings(obj["risks"], max: 3),
                              changeMind: String(((obj["change_mind"] as? String) ?? "").prefix(300)),
                              model: model, costUSD: cost, rawOutput: text)
    }
}

// MARK: - Report card: Extra Search next to the normal analysis

nonisolated struct ExtraReportCard: Sendable {
    var searched = 0                 // Extra Searches made
    var graded = 0                   // …whose analysis has been graded
    var normalCalls = 0, normalRight = 0
    var extraCalls = 0, extraRight = 0
    var disagreed = 0                // judge pointed the other way, or had no direction where the analysis had one
    var extraRightWhenDisagreed = 0

    var normalRightPct: Double? { normalCalls > 0 ? Double(normalRight) / Double(normalCalls) * 100 : nil }
    var extraRightPct: Double? { extraCalls > 0 ? Double(extraRight) / Double(extraCalls) * 100 : nil }

    /// Uses only the grading the report card already does (forward return of the analysed product).
    static func build(results: [ExtraSearchResult], outcomes: [UUID: AnalysisOutcome]) -> ExtraReportCard {
        var c = ExtraReportCard()
        // One Extra Search per analysis counts: the newest.
        var latest: [UUID: ExtraSearchResult] = [:]
        for r in results where r.judge != nil {
            if let old = latest[r.runID], old.createdAt >= r.createdAt { continue }
            latest[r.runID] = r
        }
        c.searched = latest.count
        for r in latest.values {
            guard let o = outcomes[r.runID] else { continue }
            c.graded += 1
            let wentUp = o.forwardReturnPct > 0
            if let right = o.directionRight {
                c.normalCalls += 1
                if right { c.normalRight += 1 }
            }
            if let side = r.extraSide {
                c.extraCalls += 1
                let right = (side == "long") == wentUp && o.forwardReturnPct != 0
                if right { c.extraRight += 1 }
                if o.directionRight != nil, side != o.side {
                    c.disagreed += 1
                    if right { c.extraRightWhenDisagreed += 1 }
                }
            } else if o.directionRight != nil {
                c.disagreed += 1
            }
        }
        return c
    }
}
