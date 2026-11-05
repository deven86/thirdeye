import Foundation
import Testing
@testable import ThirdEye

private let btc = Instrument(id: "binance:BTCUSDT", provider: .binance, symbol: "BTC/USDT", name: "BTC", exchange: "Binance",
                             segment: "CRYPTO", kind: .crypto, currency: "USDT")

private func stage(_ n: Int, _ score: Int, confidence: Double = 0.7, status: StageStatus = .done) -> StageResult {
    StageResult(stage: n, name: "S\(n)", status: status, score: score, direction: "neutral", confidence: confidence,
                summary: "", reasons: [], sources: [], warnings: [], provider: .anthropic, model: "m",
                usedWebSearch: true, usage: AIUsage(), costUSD: 0, rawOutput: "",
                extra: n == 2 ? ["next_major_event_checked": "1"] : [:])
}

private func trade(long: Bool = true, entry: Double = 100, stop: Double = 90, open: Bool = true,
                   booked: [Int] = [], now: Date = Date(timeIntervalSince1970: 1_793_900_000)) -> Trade {
    let dir = long ? 1.0 : -1.0
    let risk = abs(entry - stop)
    var t = Trade(instrument: btc, mode: .paper, side: long ? "long" : "short", status: open ? .open : .upcoming,
                  plannedEntryLow: entry - 1, plannedEntryHigh: entry + 1, stopLoss: stop, initialStop: stop,
                  takeProfits: (1...3).map { TakeProfit(stage: $0, price: entry + dir * Double($0) * risk, rMultiple: Double($0), bookPercent: 30, then: "") },
                  plannedQuantity: 10, badge: .swing, completeBy: now.addingTimeInterval(30 * 86_400))
    if open { t.fills.append(Fill(kind: .entry, date: now.addingTimeInterval(-86_400), price: entry, quantity: 10)) }
    for s in booked { t.fills.append(Fill(kind: .exit, date: now, price: entry + dir * Double(s) * risk, quantity: 3, takeProfitStage: s)) }
    return t
}

private func params(price: Double, vs50: Int = 1, structure: Int = 1, macd: Int = 1, rsi: Double = 58, atr: Double = 4,
                    support: Double? = 95, resistance: Double? = 110, bias: String = "Bullish") -> WatchParams {
    WatchParams(timeframe: .d1, at: Date(timeIntervalSince1970: 1_793_000_000), price: price, vs20: vs50, vs50: vs50,
                structure: structure, macd: macd, rsi: rsi, adx: 25, atr: atr, support: support, resistance: resistance, bias: bias)
}

@Suite("Skipped stages")
struct SkippedStageTests {
    @Test func skippedWeightGoesToTheOthersAndCountsAsNotRun() {
        var stages = (1...10).map { stage($0, 70) }
        let all = Scoring.composite(stages, profile: .swing).value
        stages[2] = stage(3, 10, status: .skipped)   // a bearish-looking score that must be ignored
        stages[3] = stage(4, 10, status: .skipped)
        #expect(Scoring.composite(stages, profile: .swing).value == all, "every kept stage scores 70, so 700 either way")
        let cons = Scoring.consensus(stages, profile: .swing, side: "long")
        #expect(cons.skipped == 2 && cons.active == 8)
        #expect(abs(cons.evidence - 0.7) < 1e-9, "evidence is measured against the weight that was run")
        #expect(abs(cons.skippedWeightShare - 0.07) < 1e-9, "swing weights 3 + 4 of 100")
    }

    @Test func stageCountCheckScalesWithWhatWasKept() {
        #expect(Scoring.requiredStages(active: 10) == 7)
        #expect(Scoring.requiredStages(active: 8) == 6)
        #expect(Scoring.requiredStages(active: 4) == 3)
        var stages = (1...10).map { stage($0, 72) }
        for i in [2, 3] { stages[i].status = .skipped }
        stages[4].status = .unavailable
        stages[5].status = .unavailable
        let e = Scoring.evaluate(stages: stages, plan: nil, lastCandleAge: 60, profile: .swing, instrument: btc)
        let check = e.checks.first { $0.id == "stages" }
        #expect(check?.passed == true, "6 of the 8 kept = enough")
        #expect(check?.detail.contains("6 of the 8 you kept") == true)
        #expect(e.checks.contains { $0.id == "skipped" && !$0.blocking })
    }

    @Test func skippingMuchOfTheWeightCapsTheGrade() {
        let strong = Scoring.Consensus(completed: 6, evidence: 0.8, support: 1, opposition: 0)
        #expect(Scoring.grade(composite: 800, consensus: strong) == "A+")
        var some = strong; some.skipped = 2; some.skippedWeightShare = 0.2
        #expect(Scoring.grade(composite: 800, consensus: some) == "A")
        var many = strong; many.skipped = 4; many.skippedWeightShare = 0.4
        #expect(Scoring.grade(composite: 800, consensus: many) == "B")
    }

    @Test func skippingTheEventsStageWarnsInsteadOfBlocking() {
        var stages = (1...10).map { stage($0, 72) }
        stages[1] = stage(2, 50, status: .skipped)
        let e = Scoring.evaluate(stages: stages, plan: nil, lastCandleAge: 60, profile: .swing, instrument: btc)
        let event = e.checks.first { $0.id == "event" }
        #expect(event?.blocking == false)
        #expect(event?.detail.contains("skipped") == true)
    }

    @Test func theFinalStageCannotBeSkipped() {
        #expect(AnalysisEngine.cleanSkip([1, 5, 10, 11]) == [1, 5])
    }
}

@Suite("Trade watch")
struct TradeWatchTests {
    @Test func brokenSupportIsCriticalForALong() {
        let t = trade()
        let changes = TradeWatch.compare(baseline: params(price: 100), now: params(price: 94, support: 90), trade: t, decimals: 2)
        #expect(changes.first?.id == "keylevel")
        #expect(TradeWatch.status(changes, r: -0.6) == .broken)
    }

    @Test func breakoutAndTrendConfirmationStrengthenALong() {
        let t = trade()
        let base = params(price: 100, vs50: -1, structure: 0, bias: "Mixed")
        let changes = TradeWatch.compare(baseline: base, now: params(price: 111, resistance: 120), trade: t, decimals: 2)
        #expect(changes.contains { $0.id == "breakout" && $0.effect == .favourable })
        #expect(changes.contains { $0.id == "vs50" && $0.effect == .favourable })
        #expect(TradeWatch.status(changes, r: 1.1) == .strengthened)
    }

    @Test func trendTurningAgainstWeakens() {
        let t = trade()
        let now = params(price: 99, vs50: -1, structure: -1, macd: -1, rsi: 42, bias: "Mixed")
        let changes = TradeWatch.compare(baseline: params(price: 100), now: now, trade: t, decimals: 2)
        #expect(changes.allSatisfy { $0.effect != .favourable })
        #expect([WatchStatus.weakened, .broken].contains(TradeWatch.status(changes, r: -0.1)))
    }

    @Test func mirrorsForAShort() {
        let t = trade(long: false, entry: 100, stop: 110)
        let changes = TradeWatch.compare(baseline: params(price: 100, vs50: -1, structure: -1, macd: -1, resistance: 105, bias: "Bearish"),
                                         now: params(price: 106, vs50: -1, structure: -1, macd: -1, resistance: 112, bias: "Bearish"),
                                         trade: t, decimals: 2)
        #expect(changes.contains { $0.id == "keylevel" }, "price went above the 105 resistance the short rested on")
        #expect(changes.first { $0.id == "keylevel" }?.effect == .adverse)
    }

    @Test func nothingChangedIsIntact() {
        let changes = TradeWatch.compare(baseline: params(price: 100), now: params(price: 102), trade: trade(), decimals: 2)
        #expect(changes.isEmpty)
        #expect(TradeWatch.status(changes, r: 0.2) == .intact)
    }

    @Test func trailMovesToBreakevenAtOneR() {
        let t = trade()
        let s = TradeWatch.trail(t, price: 111, candlesSinceEntry: [], atr: 4)
        #expect(s?.price == 100)
        #expect(s?.lockedR == 0)
    }

    @Test func trailUsesTheATRBehindTheHighOnceWellInProfit() {
        let t = trade(booked: [1])
        var u = t; u.stopLoss = 100   // already at breakeven after TP1
        let bars = [Candle(time: Date(), open: 120, high: 128, low: 119, close: 126, volume: 1)]
        let s = TradeWatch.trail(u, price: 126, candlesSinceEntry: bars, atr: 4)
        #expect(s?.price == 118, "128 − 2.5 × 4")
        #expect(abs((s?.lockedR ?? 0) - 1.8) < 1e-9)
    }

    @Test func trailNeverLoosensOrCrowdsThePrice() {
        var t = trade()
        t.stopLoss = 105
        #expect(TradeWatch.trail(t, price: 111, candlesSinceEntry: [], atr: 4) == nil, "breakeven 100 is looser than 105")
        #expect(TradeWatch.trail(trade(), price: 101, candlesSinceEntry: [], atr: 4) == nil, "below +1R: no move yet")
    }

    @Test func newsWhenStatusChangesOrANewMajorChangeAppears() {
        let base = TradeCheck(at: Date(), price: 100, r: 0, status: .intact, changes: [])
        var worse = base; worse.status = .weakened
        #expect(TradeWatch.isNews(worse, previous: base))
        #expect(!TradeWatch.isNews(base, previous: base))
        #expect(!TradeWatch.isNews(base, previous: nil), "first check with nothing changed is quiet")
    }
}

@Suite("AI re-check validation")
struct ReviewValidationTests {
    @Test func refusesALooserStopOrOneBeyondThePrice() {
        let t = trade()
        let looser = TradeReviewer.validate(["status": "weakened", "action": "tighten_stop", "new_stop": 85, "summary": "x"],
                                            trade: t, price: 104, model: "m", cost: 0)
        #expect(looser.newStop == nil && looser.action == "hold" && !looser.warnings.isEmpty)
        let beyond = TradeReviewer.validate(["status": "weakened", "action": "tighten_stop", "new_stop": 106, "summary": "x"],
                                            trade: t, price: 104, model: "m", cost: 0)
        #expect(beyond.newStop == nil)
        let ok = TradeReviewer.validate(["status": "intact", "action": "tighten_stop", "new_stop": 97, "summary": "x"],
                                        trade: t, price: 104, model: "m", cost: 0)
        #expect(ok.newStop == 97 && ok.action == "tighten_stop")
    }

    @Test func refusesAddingToAWeakOrLosingTrade() {
        let t = trade()
        let losing = TradeReviewer.validate(["status": "strengthened", "action": "add", "summary": "x"], trade: t, price: 98, model: "m", cost: 0)
        #expect(losing.action == "hold")
        let fine = TradeReviewer.validate(["status": "strengthened", "action": "add", "summary": "x"], trade: t, price: 108, model: "m", cost: 0)
        #expect(fine.action == "add")
        let junk = TradeReviewer.validate(["status": "??", "action": "yolo", "book_percent": 250], trade: t, price: 100, model: "m", cost: 0)
        #expect(junk.status == .intact && junk.action == "hold" && junk.bookPercent == 100)
    }
}

@Suite("Action plan")
struct ActionPlanTests {
    private func tradable(grade: String = "A", event: Bool = false) -> AnalysisRun {
        let plan = TradePlanner.build(.init(side: "long", entryLow: 99, entryHigh: 101, stopLoss: 95, holdingDays: 10,
                                            invalidation: "a close below 96", rationale: ""), lastPrice: 102, atr: 3, tick: 0.01)
        var r = AnalysisRun(id: UUID(), instrument: btc, profile: .swing, startedAt: Date(), finishedAt: Date(), lastPrice: 102,
                            stages: (1...10).map { stage($0, 75) }, composite: 700, verdict: Verdict.buy.rawValue, vetoes: [],
                            plan: plan, verifierNotes: [], totalCostUSD: 0, promptVersion: "p", featurePackHash: "")
        r.grade = grade
        r.atr = 3
        if event { r.checks = [ScoreCheck(id: "event", title: "No product event soon", detail: "results in 5 days", passed: false, blocking: false)] }
        return r
    }

    @Test func tradablePlanHasEveryStepAndTheRightQuantity() {
        let p = ActionPlanner.build(tradable(), inputs: .init(capital: 100_000, riskPercent: 1, paperMode: false))
        #expect(p.tone == .trade)
        #expect(p.steps.map(\.id) == ["when", "where", "size", "stop", "targets", "trail", "against", "time"])
        let size = p.steps.first { $0.id == "size" }!.lines.joined(separator: " ")
        // Grade A → 0.75 % of 100 000 = 750 at risk; risk per unit 100 − 95 = 5 → 150 units.
        #expect(size.contains("Quantity 150"))
        #expect(p.steps.first { $0.id == "against" }!.lines.contains { $0.contains("a close below 96") })
    }

    @Test func eventsHalveTheRiskAndShowInTheTimeStep() {
        let p = ActionPlanner.build(tradable(grade: "A+", event: true), inputs: .init(capital: 100_000, riskPercent: 1, paperMode: true))
        let size = p.steps.first { $0.id == "size" }!.lines.joined(separator: " ")
        #expect(size.contains("Quantity 100"), "A+ 1 % halved → 500 / 5")
        #expect(size.contains("Paper"))
        #expect(p.steps.first { $0.id == "time" }!.lines.contains { $0.contains("results in 5 days") })
    }

    @Test func noTradeGivesAWaitPlan() {
        var r = tradable()
        r.verdict = Verdict.noTrade.rawValue
        r.composite = 540
        r.watchLevels = ["Long case improves on a close above 110."]
        let p = ActionPlanner.build(r, inputs: .init(capital: nil, riskPercent: 1, paperMode: false))
        #expect(p.tone == .wait)
        #expect(p.steps.contains { $0.id == "watch" && $0.lines.first == "Long case improves on a close above 110." })
    }

    @Test func gradeFactors() {
        #expect(ActionPlanner.gradeFactor("A+") == 1)
        #expect(ActionPlanner.gradeFactor("A") == 0.75)
        #expect(ActionPlanner.gradeFactor("B") == 0.5)
    }
}

@Suite("Monitor address")
struct MonitorAddressTests {
    @Test func tailscaleIPUsesTheHTTPFallbackPort() {
        #expect(MonitorStore.isTailscaleIP("100.108.39.72"))
        #expect(!MonitorStore.isTailscaleIP("192.168.1.5"))
        #expect(!MonitorStore.isTailscaleIP("100.200.1.1"), "outside 100.64.0.0/10")
        #expect(!MonitorStore.isTailscaleIP("deven-pc.taildd20dc.ts.net"))
        #expect(MonitorStore.url("100.108.39.72", "/healthz")?.absoluteString == "http://100.108.39.72:8788/healthz")
        #expect(MonitorStore.url("deven-pc.taildd20dc.ts.net", "/healthz")?.absoluteString == "https://deven-pc.taildd20dc.ts.net/healthz")
    }
}

@Suite("Lock Screen card")
struct LiveActivityStateTests {
    @Test func matchesThePCMonitorsMaths() {
        let t = trade()   // long, entry 100, stop 90, TP1 110 / TP2 120 / TP3 130
        let s = LiveActivityManager.state(t, price: 105)
        #expect(s.status == "open" && s.r == 0.5 && s.nextTargetStage == 1)
        #expect(s.progress == 0.75, "(105 − 90) / (110 − 90), same as monitor/live.go")
        #expect(LiveActivityManager.state(t, price: 111).status == "target")
        #expect(LiveActivityManager.state(t, price: 92).status == "nearStop")
        #expect(LiveActivityManager.state(t, price: 89).status == "stop")
        #expect(LiveActivityManager.state(trade(open: false), price: 100).status == "inZone")
    }
}
