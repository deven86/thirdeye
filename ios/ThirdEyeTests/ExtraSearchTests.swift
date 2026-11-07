import Foundation
import Testing
@testable import ThirdEye

private let reliance = Instrument(id: "NSE_EQ|INE002A01018", provider: .upstox, symbol: "RELIANCE", name: "Reliance Industries",
                                  exchange: "NSE", segment: "NSE_EQ", kind: .equity, currency: "INR", lotSize: 1)
private let btc = Instrument(id: "binance:BTCUSDT", provider: .binance, symbol: "BTC/USDT", name: "BTC", exchange: "Binance",
                             segment: "CRYPTO", kind: .crypto, currency: "USDT")

private func stage(_ n: Int, _ score: Int, confidence: Double = 0.6) -> StageResult {
    StageResult(stage: n, name: "S\(n)", status: .done, score: score, direction: "neutral", confidence: confidence,
                summary: "summary \(n)", reasons: [StageReason(point: "point \(n)", impact: 1, evidence: ["D.RSI14"])],
                sources: [], warnings: [], provider: .anthropic, model: "m", usedWebSearch: true,
                usage: AIUsage(), costUSD: 0.05, rawOutput: "")
}

private func run(_ scores: [Int], instrument: Instrument = reliance, at: Date = Date(timeIntervalSince1970: 1_793_900_000),
                 composite: Int? = nil, verdict: Verdict = .noTrade) -> AnalysisRun {
    let stages = (1...10).map { stage($0, scores[$0 - 1]) }
    return AnalysisRun(id: UUID(), instrument: instrument, profile: .swing, startedAt: at, finishedAt: at.addingTimeInterval(300),
                       lastPrice: 100, stages: stages,
                       composite: composite ?? Scoring.composite(stages, profile: .swing).value, verdict: verdict.rawValue,
                       vetoes: [], plan: nil, verifierNotes: [], totalCostUSD: 0.5, promptVersion: StageSpec.promptVersion,
                       featurePackHash: "")
}

private func outcome(_ runID: UUID, side: String, right: Bool?, ret: Double) -> AnalysisOutcome {
    AnalysisOutcome(runID: runID, gradedAt: Date(), horizonDays: 10, composite: 650, startPrice: 100, endPrice: 100 + ret,
                    forwardReturnPct: ret, side: side, directionRight: right, bestPct: max(ret, 0), worstPct: min(ret, 0),
                    entered: nil, planR: nil, targetsHit: nil, stopHit: nil)
}

private func result(for r: AnalysisRun, judgeScore: Int?) -> ExtraSearchResult {
    ExtraSearchResult(id: UUID(), runID: r.id, instrumentID: r.instrument.id, createdAt: Date(), normalComposite: r.composite ?? 500,
                      normalVerdict: r.verdict ?? "", spread: nil, leans: [], conflicts: [], memory: [], bull: nil, bear: nil,
                      judge: judgeScore.map {
                          ExtraJudgement(score: $0, confidence: 0.6, stance: "agree", action: "take", summary: "", deciding: [],
                                         risks: [], changeMind: "", model: nil, costUSD: 0, rawOutput: "")
                      },
                      failures: [], totalCostUSD: 0.1, promptVersion: ExtraPrompts.version)
}

@MainActor
@Suite("Extra Search — does not touch the normal analysis")
struct ExtraSearchIsolationTests {
    @Test func normalPromptsAndScoringAreUnchanged() {
        #expect(StageSpec.promptVersion == "p4-2026-11-04", "Extra Search must not change the stage prompts")
        #expect(Scoring.version == 2)
        #expect(ExtraPrompts.version != StageSpec.promptVersion, "Extra Search has its own prompt version")
    }

    @Test func switchIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "extra-search-test-\(UUID().uuidString)")!
        let s = AppSettings(defaults: defaults)
        #expect(s.extraSearchEnabled == false)
        #expect(s.showExtraVIX == false && s.showExtraConflicts == false, "sub-options do nothing while the main switch is off")
        s.extraSearchEnabled = true
        #expect(s.showExtraVIX && s.showExtraConflicts)
        #expect(AppSettings(defaults: defaults).extraSearchEnabled, "remembered")
    }
}

@Suite("Extra Search — conflicts and spread")
struct ExtraConflictTests {
    @Test func chartsUpAndNewsDownIsAConflict() {
        // news 1–2 bearish, business 3,4,7,8 neutral, charts 5,6,9 bullish, final neutral
        let r = run([30, 32, 50, 50, 75, 78, 50, 50, 74, 55])
        let conflicts = ExtraConflicts.conflicts(r.stages, profile: .swing)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.id == "chart-news")
        #expect(conflicts.first?.strong == true, "charts ~76 vs news ~31 is 30+ points apart")
    }

    @Test func agreementHasNoConflict() {
        let r = run(Array(repeating: 70, count: 10))
        #expect(ExtraConflicts.conflicts(r.stages, profile: .swing).isEmpty)
        #expect(ExtraConflicts.leans(r.stages, profile: .swing).allSatisfy { $0.score == 70 && $0.direction == "up" })
    }

    @Test func finalStageAgainstTheRestIsAConflict() {
        let r = run([35, 35, 35, 35, 35, 35, 35, 35, 35, 80])
        #expect(ExtraConflicts.conflicts(r.stages, profile: .swing).contains { $0.id == "final-rest" })
    }

    @Test func skippedAndFailedStagesAreIgnored() {
        var r = run([30, 30, 50, 50, 75, 75, 50, 50, 75, 55])
        r.stages[0] = .skipped(1, name: "S1")
        r.stages[1] = .unavailable(2, name: "S2", reason: "x")
        #expect(ExtraConflicts.conflicts(r.stages, profile: .swing).isEmpty, "no news group left to disagree with")
    }

    @Test func spreadIsSmallWhenStagesAgreeAndLargeWhenTheyDont() {
        let agree = ExtraSpread.points(run(Array(repeating: 70, count: 10)).stages, profile: .swing)
        let split = ExtraSpread.points(run([20, 20, 80, 80, 20, 80, 20, 80, 20, 80]).stages, profile: .swing)
        #expect(agree == 5, "minimum shown")
        #expect((split ?? 0) >= 80)
    }
}

@Suite("Extra Search — India VIX sizing")
struct VIXSizingTests {
    @Test func multiplierBands() {
        #expect(VIXSizing.multiplier(vix: 12) == 1)
        #expect(VIXSizing.multiplier(vix: 15) == 0.85)
        #expect(VIXSizing.multiplier(vix: 22.5) == 0.65)
        #expect(VIXSizing.multiplier(vix: 31) == 0.5)
    }

    @Test func roundsDownToLots() {
        #expect(VIXSizing.adjusted(quantity: 100, multiplier: 0.85, lotSize: 1) == 85)
        #expect(VIXSizing.adjusted(quantity: 7, multiplier: 0.65, lotSize: 1) == 4)
        #expect(VIXSizing.adjusted(quantity: 750, multiplier: 0.65, lotSize: 75) == 450, "F&O: whole lots only")
        #expect(VIXSizing.adjusted(quantity: 0, multiplier: 0.5, lotSize: 1) == 0)
    }

    @Test func onlyIndianProducts() {
        #expect(VIXSizing.applies(to: reliance))
        #expect(!VIXSizing.applies(to: btc))
        #expect(!VIXSizing.applies(to: VIXSizing.instrument))
    }
}

@Suite("Extra Search — parsing and memory")
struct ExtraParsingTests {
    @Test func judgementIsClampedAndValidated() {
        let text = #"Thinking… {"score": 140, "confidence": 3, "stance": "maybe", "action": "yolo", "summary": "s", "deciding": ["a","b","c","d","e"], "risks": [], "change_mind": "c"}"#
        let j = ExtraPrompts.parseJudgement(text, model: "m", cost: 0.02)
        #expect(j?.score == 100)
        #expect(j?.confidence == 1)
        #expect(j?.stance == "more_cautious", "unknown stance falls back to cautious")
        #expect(j?.action == "wait", "unknown action falls back to wait")
        #expect(j?.deciding.count == 4)
        #expect(ExtraPrompts.parseJudgement("no json here", model: nil, cost: 0) == nil)
    }

    @Test func caseParses() {
        let c = ExtraPrompts.parseCase(#"{"summary": "Up", "points": ["S6 strong trend", ""], "strength": 0}"#, bull: true, model: nil, cost: 0)
        #expect(c?.side == "bull")
        #expect(c?.points == ["S6 strong trend"])
        #expect(c?.strength == 1)
    }

    @Test func extraScoreAndSide() {
        let r = run(Array(repeating: 70, count: 10))
        #expect(result(for: r, judgeScore: 65).extraScore == 650)
        #expect(result(for: r, judgeScore: 65).extraSide == "long")
        #expect(result(for: r, judgeScore: 50).extraSide == nil)
        #expect(result(for: r, judgeScore: 30).extraSide == "short")
    }

    @Test func memoryListsPastRunsOfTheSameProductWithTheirGrades() {
        let now = Date(timeIntervalSince1970: 1_793_900_000)
        let current = run(Array(repeating: 70, count: 10), at: now)
        let past = run(Array(repeating: 70, count: 10), at: now.addingTimeInterval(-20 * 86_400))
        let other = run(Array(repeating: 70, count: 10), instrument: btc, at: now.addingTimeInterval(-86_400))
        let items = DecisionMemory.items(for: reliance, excluding: current.id, runs: [current, past, other],
                                         outcomes: [past.id: outcome(past.id, side: "long", right: true, ret: 4.2)], extras: [])
        #expect(items.count == 1)
        #expect(items.first?.directionRight == true)
        let text = DecisionMemory.promptText(items, card: ReportCard())
        #expect(text.contains("+4.2%"))
        #expect(text.contains("too small"))
    }

    @Test func analysisBriefCarriesStagesAndChecks() {
        let brief = ExtraPrompts.analysisBrief(run(Array(repeating: 70, count: 10)))
        #expect(brief.contains("S10"))
        #expect(brief.contains("D.RSI14"))
        #expect(brief.contains("RELIANCE"))
    }
}

@Suite("Extra Search — report card")
struct ExtraReportCardTests {
    @Test func comparesExtraWithNormalOnTheSameGradedRuns() {
        let a = run(Array(repeating: 70, count: 10)), b = run(Array(repeating: 70, count: 10))
        let results = [result(for: a, judgeScore: 70), result(for: b, judgeScore: 30)]
        let outcomes = [a.id: outcome(a.id, side: "long", right: true, ret: 3),
                        b.id: outcome(b.id, side: "long", right: false, ret: -2)]
        let c = ExtraReportCard.build(results: results, outcomes: outcomes)
        #expect(c.searched == 2 && c.graded == 2)
        #expect(c.normalRight == 1 && c.normalCalls == 2)
        #expect(c.extraRight == 2 && c.extraCalls == 2, "Extra said long on A (up) and short on B (down)")
        #expect(c.disagreed == 1 && c.extraRightWhenDisagreed == 1)
    }

    @Test func onlyTheNewestSearchPerAnalysisCounts() {
        let a = run(Array(repeating: 70, count: 10))
        var older = result(for: a, judgeScore: 30)
        older.createdAt = Date(timeIntervalSince1970: 0)
        let newer = result(for: a, judgeScore: 70)
        let c = ExtraReportCard.build(results: [older, newer], outcomes: [a.id: outcome(a.id, side: "long", right: true, ret: 3)])
        #expect(c.searched == 1 && c.extraRight == 1)
    }
}
