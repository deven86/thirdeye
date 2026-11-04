import Foundation
import Testing
@testable import ThirdEye

private let btc = Instrument(id: "binance:BTCUSDT", provider: .binance, symbol: "BTC/USDT", name: "BTC", exchange: "Binance",
                             segment: "CRYPTO", kind: .crypto, currency: "USDT")
private let eth = Instrument(id: "binance:ETHUSDT", provider: .binance, symbol: "ETH/USDT", name: "ETH", exchange: "Binance",
                             segment: "CRYPTO", kind: .crypto, currency: "USDT")
private let aapl = Instrument(id: "twelve:AAPL", provider: .twelveData, symbol: "AAPL", name: "AAPL", exchange: "US",
                              segment: "EQUITY", kind: .equity, currency: "USD")

private func stage(_ n: Int, _ score: Int, extra: [String: String] = [:]) -> StageResult {
    StageResult(stage: n, name: "S\(n)", status: .done, score: score, direction: "neutral", confidence: 0.6,
                summary: "", reasons: [], sources: [], warnings: [], provider: .anthropic, model: "m",
                usedWebSearch: true, usage: AIUsage(), costUSD: 0.05, rawOutput: "", extra: extra)
}

private func run(_ instrument: Instrument, _ profile: HoldingProfile, at: Date, scores: [Int] = Array(repeating: 60, count: 10),
                 plan: TradePlan? = nil, price: Double = 100, verdict: Verdict = .noTrade) -> AnalysisRun {
    AnalysisRun(id: UUID(), instrument: instrument, profile: profile, startedAt: at, finishedAt: at.addingTimeInterval(300),
                lastPrice: price, stages: (1...10).map { stage($0, scores[$0 - 1]) }, composite: nil, verdict: verdict.rawValue,
                vetoes: [], plan: plan, verifierNotes: [], totalCostUSD: 0.5, promptVersion: StageSpec.promptVersion,
                featurePackHash: "")
}

@Suite("Stage reuse")
struct StageReuseTests {
    let now = Date(timeIntervalSince1970: 1_793_900_000)

    @Test func reusesSlowStagesFromARecentRunOfTheSameProductAndProfile() {
        var recent = run(btc, .swing, at: now.addingTimeInterval(-3 * 3600))
        recent.stages[1] = stage(2, 60, extra: ["next_major_event_days": "5", "next_macro_event_days": "1"])
        let old = run(btc, .swing, at: now.addingTimeInterval(-20 * 3600))
        let otherProfile = run(btc, .positional, at: now.addingTimeInterval(-3600))
        let reused = AnalysisEngine.reusableStages(for: btc, profile: .swing, hours: 12, runs: [old, otherProfile, recent], now: now)
        #expect(Set(reused.keys) == [1, 2, 3, 4, 7, 8], "technical stages 5, 6, 9 and the final stage always run fresh")
        let allFree = reused.values.allSatisfy { $0.costUSD == 0 && $0.extra["reusedFrom"] == recent.id.uuidString }
        #expect(allFree)
        #expect(reused[2]?.extra["next_major_event_days"] == "5", "same day: unchanged")
        #expect(reused[1]?.warnings.first?.hasPrefix("Reused from") == true)
    }

    @Test func respectsTheWindowTheSettingAndNoChaining() {
        let stale = run(btc, .swing, at: now.addingTimeInterval(-13 * 3600))
        #expect(AnalysisEngine.reusableStages(for: btc, profile: .swing, hours: 12, runs: [stale], now: now).isEmpty)
        #expect(AnalysisEngine.reusableStages(for: btc, profile: .swing, hours: 0, runs: [stale], now: now).isEmpty, "Off")
        var chained = run(btc, .swing, at: now.addingTimeInterval(-3600))
        for i in chained.stages.indices { chained.stages[i].extra["reusedFrom"] = UUID().uuidString }
        #expect(AnalysisEngine.reusableStages(for: btc, profile: .swing, hours: 12, runs: [chained], now: now).isEmpty)
    }

    @Test func eventCountdownsMoveOnWithTime() {
        var source = run(btc, .swing, at: now.addingTimeInterval(-26 * 3600))
        source.stages[1] = stage(2, 60, extra: ["next_major_event_days": "5"])
        let reused = AnalysisEngine.reusableStages(for: btc, profile: .swing, hours: 48, runs: [source], now: now)
        #expect(reused[2]?.extra["next_major_event_days"] == "4")
    }
}

@Suite("Risk guard")
struct RiskGuardTests {
    let now = Date(timeIntervalSince1970: 1_793_900_000)

    func closed(_ instrument: Instrument, exit: Double, daysAgo: Double) -> Trade {
        Trade(instrument: instrument, mode: .paper, side: "long", status: .closed, plannedEntryLow: 99, plannedEntryHigh: 101,
              stopLoss: 95, initialStop: 95, takeProfits: [], plannedQuantity: 1, badge: .swing, completeBy: now,
              fills: [Fill(kind: .entry, date: now.addingTimeInterval(-(daysAgo + 1) * 86_400), price: 100, quantity: 1),
                      Fill(kind: .exit, date: now.addingTimeInterval(-daysAgo * 86_400), price: exit, quantity: 1)],
              closedAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func open(_ instrument: Instrument, side: String = "long") -> Trade {
        Trade(instrument: instrument, mode: .paper, side: side, status: .open, plannedEntryLow: 99, plannedEntryHigh: 101,
              stopLoss: side == "long" ? 95 : 105, initialStop: side == "long" ? 95 : 105, takeProfits: [], plannedQuantity: 2,
              badge: .swing, completeBy: now, fills: [Fill(kind: .entry, date: now, price: 100, quantity: 2)])
    }

    @Test func losingWeekSaysPause() {
        let trades = [closed(btc, exit: 95, daysAgo: 1), closed(eth, exit: 95, daysAgo: 2), closed(btc, exit: 95, daysAgo: 3),
                      closed(btc, exit: 80, daysAgo: 10)]   // older than 7 days: ignored
        let week = RiskGuard.lastSevenDays(trades, mode: .paper, now: now)
        #expect(week.count == 3)
        #expect(abs(week.r - (-3)) < 1e-9)
        #expect(RiskGuard.weeklyCheck(trades, mode: .paper, limitR: 3, now: now).level == .stop)
        #expect(RiskGuard.weeklyCheck(trades, mode: .paper, limitR: 5, now: now).level == .ok)
        #expect(RiskGuard.weeklyCheck(trades, mode: .real, limitR: 3, now: now).level == .ok, "modes are separate")
    }

    @Test func openRiskIncludesTheNewTrade() throws {
        // Open: 2 units × 5 risk = 10. New trade risks 30. Capital 1000 → 4 %.
        let c = try #require(RiskGuard.openRiskCheck([open(btc)], mode: .paper, currency: "USDT", newRisk: 30, capital: 1000, capPercent: 6))
        #expect(c.level == .ok && c.detail.hasPrefix("4.0%"))
        let over = try #require(RiskGuard.openRiskCheck([open(btc)], mode: .paper, currency: "USDT", newRisk: 60, capital: 1000, capPercent: 6))
        #expect(over.level == .caution)
        #expect(RiskGuard.openRiskCheck([], mode: .paper, currency: "USDT", newRisk: 10, capital: nil, capPercent: 6) == nil)
    }

    @Test func sameBetUsesCorrelationOrTheCryptoRule() throws {
        let sol = Instrument(id: "binance:SOLUSDT", provider: .binance, symbol: "SOL/USDT", name: "SOL", exchange: "Binance",
                             segment: "CRYPTO", kind: .crypto, currency: "USDT")
        let crypto = try #require(RiskGuard.sameBetCheck(newInstrument: sol, side: "long", trades: [open(btc), open(eth)],
                                                         mode: .paper, correlations: [:]))
        #expect(crypto.level == .caution && crypto.title.contains("2"))
        #expect(RiskGuard.sameBetCheck(newInstrument: sol, side: "short", trades: [open(btc)], mode: .paper, correlations: [:]) == nil,
                "opposite directions hedge rather than add up")
        let msft = Instrument(id: "twelve:MSFT", provider: .twelveData, symbol: "MSFT", name: "MSFT", exchange: "US",
                              segment: "EQUITY", kind: .equity, currency: "USD")
        #expect(RiskGuard.sameBetCheck(newInstrument: msft, side: "long", trades: [open(aapl)], mode: .paper,
                                       correlations: [aapl.id: 0.4]) == nil)
        #expect(RiskGuard.sameBetCheck(newInstrument: msft, side: "long", trades: [open(aapl)], mode: .paper,
                                       correlations: [aapl.id: 0.8]) != nil)
    }

    @Test func correlationOfDailyReturns() throws {
        let days = (0..<80).map { Date(timeIntervalSince1970: 1_790_000_000 + Double($0) * 86_400) }
        let a = days.enumerated().map { i, d in Candle(time: d, open: 1, high: 1, low: 1, close: 100 + Double(i % 7) * 2, volume: 1) }
        let b = days.enumerated().map { i, d in Candle(time: d, open: 1, high: 1, low: 1, close: 50 + Double(i % 7), volume: 1) }
        let rho = try #require(RiskGuard.returnCorrelation(a, b))
        #expect(rho > 0.95)
        #expect(RiskGuard.returnCorrelation(Array(a.prefix(10)), Array(b.prefix(10))) == nil, "needs 3+ weeks of shared days")
    }
}

@Suite("Report card")
struct ReportCardTests {
    let t0 = Date(timeIntervalSince1970: 1_793_900_000)

    func bars(_ closes: [(Double, Double, Double)]) -> [Candle] {   // (high, low, close), one per day after t0
        closes.enumerated().map { i, x in
            Candle(time: t0.addingTimeInterval(Double(i + 1) * 86_400), open: x.2, high: x.0, low: x.1, close: x.2, volume: 1)
        }
    }

    @Test func levelReplayFollowsTheLadder() throws {
        // Entry 100 on bar 0, stop 95 (R 5). TP1 105 then TP2 110, then back to the stop at TP1 (105) → +0.3 +0.5 +0.45×1.
        let c = [Candle(time: t0, open: 100, high: 100, low: 100, close: 100, volume: 0)]
            + bars([(106, 99, 105), (111, 104, 109), (108, 104.5, 105)])
        let r = try #require(PlanReplay.simulateLevels(c, side: 1, entry: 100, stop: 95,
                                                       targets: [(105, 0.3), (110, 0.25), (115, 0.2), (120, 0.15)]))
        #expect(abs(r.r - 1.25) < 1e-12)
        #expect(r.targetsHit == 2 && r.stopHit)
    }

    @Test func gradesDirectionAndThePlan() throws {
        let plan = TradePlanner.build(.init(side: "long", entryLow: 99, entryHigh: 101, stopLoss: 95, holdingDays: 5,
                                            invalidation: "", rationale: ""), lastPrice: 100, atr: 3, tick: 0.01)
        let a = run(btc, .swing, at: t0, scores: Array(repeating: 70, count: 10), plan: plan, verdict: .buy)
        #expect(OutcomeGrader.horizonDays(a) == 5)
        #expect(!OutcomeGrader.isDue(a, now: t0.addingTimeInterval(4 * 86_400)))
        #expect(OutcomeGrader.isDue(a, now: t0.addingTimeInterval(5 * 86_400 + 3600)))
        let candles = bars([(101, 99.5, 100.5), (106, 100, 105.5), (107, 104, 106), (107, 105.5, 106.5), (108, 106, 107), (130, 120, 125)])
        let o = try #require(OutcomeGrader.grade(a, candles: candles, now: t0.addingTimeInterval(6 * 86_400)))
        #expect(o.composite == 700 && o.side == "long")
        #expect(abs(o.forwardReturnPct - 7) < 1e-9, "the 6th day is after the horizon")
        #expect(o.directionRight == true)
        #expect(o.entered == true && o.targetsHit == 1)
        #expect(o.planR != nil && o.planR! > 0)

        let flat = run(btc, .swing, at: t0, scores: Array(repeating: 50, count: 10))
        let f = try #require(OutcomeGrader.grade(flat, candles: candles, now: t0.addingTimeInterval(20 * 86_400)))
        #expect(f.directionRight == nil, "a score near 500 makes no direction call")
    }

    @Test func cardAggregates() {
        let up = run(btc, .swing, at: t0, scores: Array(repeating: 70, count: 10))
        let down = run(eth, .swing, at: t0, scores: Array(repeating: 30, count: 10))
        func outcome(_ r: AnalysisRun, end: Double) -> AnalysisOutcome {
            let c = Scoring.composite(r.stages, profile: r.profile).value
            return AnalysisOutcome(runID: r.id, gradedAt: t0, horizonDays: 10, composite: c, startPrice: 100, endPrice: end,
                                   forwardReturnPct: end - 100, side: c >= 500 ? "long" : "short",
                                   directionRight: c >= 500 ? end > 100 : end < 100, bestPct: 0, worstPct: 0)
        }
        let card = ReportCard.build(runs: [up, down], outcomes: [up.id: outcome(up, end: 110), down.id: outcome(down, end: 104)])
        #expect(card.graded == 2)
        #expect(card.directionRightPct == 50)
        #expect(card.bands.first { $0.label.hasPrefix("Buy") }?.rightPct == 100)
        #expect(card.bands.first { $0.label.hasPrefix("Sell") }?.avgMovePct == -4, "short call, price rose 4 %")
        #expect(card.stages.first?.count == 2 && card.stages.first?.rightPct == 50)
    }
}
