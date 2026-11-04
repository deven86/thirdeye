import Foundation
import Testing
@testable import ThirdEye

/// Golden values come from the Python reference (research/replay_ref.py), which mirrors PlanReplay line by line.
@Suite("Plan replay")
struct PlanReplayTests {
    /// Deterministic price path from an integer LCG — identical in Swift and Python (no libm calls).
    static func lcgSeries(_ n: Int, seed: UInt64 = 42) -> [Candle] {
        var x = seed
        func u() -> Double {
            x = (1_103_515_245 &* x &+ 12_345) % 2_147_483_648
            return Double(x) / 2_147_483_648
        }
        var out: [Candle] = []
        var prev = 100.0
        for i in 0..<n {
            let o = prev
            let c = o * (1 + 0.03 * (u() - 0.5))
            let h = max(o, c) * (1 + 0.01 * u())
            let l = min(o, c) * (1 - 0.01 * u())
            out.append(Candle(time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400), open: o, high: h, low: l, close: c, volume: 1000))
            prev = c
        }
        return out
    }

    func bar(_ o: Double, _ h: Double, _ l: Double, _ c: Double, _ i: Int) -> Candle {
        Candle(time: Date(timeIntervalSince1970: Double(i) * 86_400), open: o, high: h, low: l, close: c, volume: 1)
    }

    @Test func ladderBooksPartialsAndStepsTheStop() throws {
        // Entry 100, risk 2: TP1 102 (30 %), stop → 100; TP2 104 (25 %), stop → 102; then the stop at 102 takes the rest (+1R).
        let c = [bar(100, 100, 100, 100, 0), bar(100, 102.5, 99, 102, 1), bar(102, 104.5, 101, 104, 2), bar(104, 104.2, 101.5, 102, 3)]
        let o = try #require(PlanReplay.simulate(c, entry: 0, side: 1, risk: 2, horizon: 10, costPct: 0))
        #expect(abs(o.r - 1.25) < 1e-12)   // 0.30×1 + 0.25×2 + 0.45×1
        #expect(o.targetsHit == 2)
        #expect(o.bars == 3)
        #expect(!o.stoppedBeforeTP1)
    }

    @Test func gapThroughTheStopFillsAtTheOpen() throws {
        let c = [bar(100, 100, 100, 100, 0), bar(97, 97.5, 96, 96.5, 1)]
        let o = try #require(PlanReplay.simulate(c, entry: 0, side: 1, risk: 2, horizon: 5, costPct: 0))
        #expect(abs(o.r - (-1.5)) < 1e-12, "opened at 97, below the 98 stop")
        #expect(o.stoppedBeforeTP1)
        let s = try #require(PlanReplay.simulate(c, entry: 0, side: -1, risk: 2, horizon: 5, costPct: 0))
        // Short: the gap fills TP1 (98) at the open 97, and the low of 96 reaches TP2.
        #expect(s.targetsHit == 2)
        #expect(abs(s.r - (0.30 * 1.5 + 0.25 * 2 + 0.45 * 1.75)) < 1e-12, "rest closes at 96.5 after the time limit")
    }

    @Test func matchesPythonReference() throws {
        let k = Self.lcgSeries(300)
        #expect(abs(k.last!.close - 100.13140344142974) < 1e-9)
        let atr = Indicators.atr(k)
        #expect(abs(atr[14]! - 1.7821634085860023) < 1e-12)

        let long = try #require(PlanReplay.simulate(k, entry: 50, side: 1, risk: 1.5 * atr[50]!, horizon: 10, costPct: 0.2))
        #expect(abs(long.r - (-1.0786832886557471)) < 1e-9)
        #expect(long.bars == 3 && long.targetsHit == 0 && long.stoppedBeforeTP1)
        let short = try #require(PlanReplay.simulate(k, entry: 50, side: -1, risk: 1.5 * atr[50]!, horizon: 10, costPct: 0.2))
        #expect(abs(short.r - 0.22131671134425016) < 1e-9)
        #expect(short.bars == 9 && short.targetsHit == 1 && !short.stoppedBeforeTP1)

        let bl = try #require(PlanReplay.baseRate(k, side: "long", stopATR: 1.5, horizon: 10, costPct: 0.2))
        #expect(bl.entries == 276)
        #expect(bl.independent == 32)
        #expect(abs(bl.stopFirstPct - 0.37681159420289856) < 1e-12)
        #expect(abs(bl.tp1Pct - 0.39855072463768115) < 1e-12)
        #expect(abs(bl.tp2Pct - 0.09057971014492754) < 1e-12)
        #expect(abs(bl.winPct - 0.4782608695652174) < 1e-12)
        #expect(abs(bl.averageR - (-0.10100052033362619)) < 1e-9)
        #expect(bl.longestLosingStreak == 5)

        let bs = try #require(PlanReplay.baseRate(k, side: "short", stopATR: 1.5, horizon: 10, costPct: 0.2))
        #expect(bs.entries == 276)
        #expect(bs.independent == 31)
        #expect(abs(bs.stopFirstPct - 0.39855072463768115) < 1e-12)
        #expect(abs(bs.tp2Pct - 0.06159420289855073) < 1e-12)
        #expect(abs(bs.averageR - (-0.12882220500396482)) < 1e-9)
        #expect(bs.longestLosingStreak == 4)
    }

    @Test func tooLittleHistoryGivesNothing() {
        #expect(PlanReplay.baseRate(Self.lcgSeries(35), side: "long", stopATR: 1.5, horizon: 10, costPct: 0.2) == nil)
    }

    @Test func holdingPeriodInBars() {
        let btc = Instrument(id: "binance:BTCUSDT", provider: .binance, symbol: "BTC/USDT", name: "BTC", exchange: "Binance",
                             segment: "CRYPTO", kind: .crypto, currency: "USDT")
        let nse = Instrument(id: "NSE_EQ|X", provider: .upstox, symbol: "X", name: "X", exchange: "NSE", segment: "NSE_EQ",
                             kind: .equity, currency: "INR")
        #expect(PlanReplay.horizonBars(days: 30, timeframe: .d1, instrument: btc) == 30, "crypto trades every day")
        #expect(PlanReplay.horizonBars(days: 30, timeframe: .d1, instrument: nse) == 21)
        #expect(PlanReplay.horizonBars(days: 365, timeframe: .w1, instrument: nse) == 52)
        #expect(PlanReplay.horizonBars(days: 1, timeframe: .m15, instrument: btc) == 96)
        #expect(PlanReplay.horizonBars(days: 1, timeframe: .m15, instrument: nse) == 25)
        #expect(PlanReplay.roundTripCostPct(btc) == 0.2)
        #expect(PlanReplay.roundTripCostPct(nse) == 0.25)
    }
}
