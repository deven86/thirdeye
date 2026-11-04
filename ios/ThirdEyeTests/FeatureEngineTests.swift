import Foundation
import Testing
@testable import ThirdEye

/// Deterministic test series. Expected values come from TA-Lib 0.8.3 (the industry reference),
/// computed on exactly this series — not from our own code.
enum GoldenSeries {
    static let candles: [Candle] = {
        let n = 300
        let c = (0..<n).map { i -> Double in
            let x = Double(i)
            return 100 + 10 * sin(x / 7) + 0.3 * x + 2 * sin(x * 1.3)
        }
        return (0..<n).map { i in
            let x = Double(i)
            let o = i > 0 ? c[i - 1] : c[0] - 0.5
            let h = max(o, c[i]) + 1 + 0.5 * abs(sin(x * 0.7))
            let l = min(o, c[i]) - 1 - 0.5 * abs(cos(x * 0.9))
            return Candle(time: Date(timeIntervalSince1970: 1_700_000_000 + x * 86_400),
                          open: o, high: h, low: l, close: c[i], volume: 1000 + 100 * Double(i % 7))
        }
    }()

    static var closes: [Double] { candles.map(\.close) }
    static let at = [60, 150, 299]
}

@Suite("Indicators match TA-Lib")
struct IndicatorGoldenTests {
    let tol = 1e-8

    func check(_ values: [Double?], _ expected: [Double], firstIndex: Int, _ name: String) {
        #expect(values.firstIndex { $0 != nil } == firstIndex, "\(name) first value index")
        for (i, e) in zip(GoldenSeries.at, expected) {
            guard let v = values[i] else { Issue.record("\(name)[\(i)] is nil"); continue }
            #expect(abs(v - e) < tol, "\(name)[\(i)] = \(v), TA-Lib = \(e)")
        }
    }

    @Test func movingAverages() {
        check(Indicators.sma(GoldenSeries.closes, 20), [120.73603413075632, 148.69673251032037, 183.38396168456717], firstIndex: 19, "SMA20")
        check(Indicators.ema(GoldenSeries.closes, 20), [120.99282529007783, 147.75460120012733, 181.90426300918966], firstIndex: 19, "EMA20")
    }

    @Test func rsiAndATR() {
        check(Indicators.rsi(GoldenSeries.closes), [68.89226343128627, 61.81380114899069, 41.477981326734145], firstIndex: 14, "RSI14")
        check(Indicators.atr(GoldenSeries.candles), [4.2866603715599245, 4.31858206407763, 4.249555532567971], firstIndex: 14, "ATR14")
    }

    @Test func macd() {
        let m = Indicators.macd(GoldenSeries.closes)
        check(m.macd, [5.109333860456317, 4.368569076288253, -1.6097393161697937], firstIndex: 25, "MACD")
        check(m.signal, [4.922320981108782, 4.916901929535081, -0.7822332416742565], firstIndex: 33, "MACD signal")
    }

    @Test func bollinger() {
        check(Indicators.bollinger(GoldenSeries.closes).upper, [133.61043054215511, 158.0807319492022, 192.69695700930112], firstIndex: 19, "BB upper")
    }

    @Test func adx() {
        let d = Indicators.adx(GoldenSeries.candles)
        check(d.adx, [44.47305597986395, 43.43963750318638, 25.304792710811295], firstIndex: 27, "ADX14")
        check(d.plusDI, [23.442647884553384, 21.66572604481012, 10.91727537973448], firstIndex: 14, "+DI")
        check(d.minusDI, [7.6322650509729115, 11.426495373706025, 17.50825769685915], firstIndex: 14, "−DI")
    }

    @Test func correlationBasics() {
        let a: [Double] = [1, 2, 3, 4, 5]
        #expect(abs((Indicators.correlation(a, a.map { $0 * 2 + 1 }) ?? 0) - 1) < 1e-12)
        #expect(abs((Indicators.correlation(a, a.map { -$0 }) ?? 0) + 1) < 1e-12)
        #expect(Indicators.correlation(a, [1, 1, 1, 1, 1]) == nil)
    }
}

@Suite("Structure, patterns, history")
struct StructureTests {
    func bar(_ i: Int, _ o: Double, _ h: Double, _ l: Double, _ c: Double, v: Double = 100) -> Candle {
        Candle(time: Date(timeIntervalSince1970: Double(i) * 86_400), open: o, high: h, low: l, close: c, volume: v)
    }

    @Test func detectsEngulfingAndHammer() {
        // Downtrend, then a bearish bar fully engulfed by a bullish bar.
        var c = (0..<6).map { i in bar(i, 110 - Double(i) * 2, 111 - Double(i) * 2, 107 - Double(i) * 2, 108 - Double(i) * 2) }
        c.append(bar(6, 98, 98.5, 96, 96.5))   // bearish
        c.append(bar(7, 96, 100, 95.5, 99.5))  // bullish engulfing
        #expect(Patterns.detect(c, at: 7).contains(.bullishEngulfing))

        var h = (0..<6).map { i in bar(i, 110 - Double(i) * 2, 111 - Double(i) * 2, 107 - Double(i) * 2, 108 - Double(i) * 2) }
        h.append(bar(6, 97, 97.3, 92, 97.2))   // small body at top, long lower wick, after a fall
        #expect(Patterns.detect(h, at: 6).contains(.hammer))
        #expect(!Patterns.detect(h, at: 6).contains(.shootingStar))
    }

    @Test func backtestCountsOutcomes() throws {
        // A bullish engulfing every 10 bars, each followed by a rise → 100 % hit rate.
        var c: [Candle] = []
        var price = 100.0
        for i in 0..<200 {
            switch i % 10 {
            case 3: c.append(bar(i, price, price + 0.2, price - 2, price - 1.8)); price -= 1.8
            case 4: c.append(bar(i, price - 0.1, price + 3, price - 0.2, price + 2.5)); price += 2.5
            default:
                let next = price + (i % 10 < 3 ? -0.5 : 0.6)
                c.append(bar(i, price, max(price, next) + 0.1, min(price, next) - 0.1, next)); price = next
            }
        }
        let stats = Patterns.backtest(c, horizon: 3)
        let s = try #require(stats[.bullishEngulfing])
        #expect(s.occurrences >= 15)
        #expect(s.hitRate == 1)
        #expect(s.avgReturnPct > 0)
    }

    @Test func zonesSplitAroundPrice() {
        let c = GoldenSeries.candles
        let zones = Levels.zones(c, atr: Indicators.atr(c).last ?? nil)
        let last = c.last!.close
        #expect(!zones.isEmpty)
        for z in zones {
            #expect(z.kind == (z.price <= last ? .support : .resistance))
            #expect(z.low <= z.price && z.price <= z.high)
        }
    }

    @Test func drawdownAndRegimes() throws {
        // 100 → 200 (bull) → 120 (bear, −40 %) → 180 (bull)
        let up1: [Double] = (0...10).map { Double(100 + $0 * 10) }
        let down: [Double] = (1...8).map { Double(200 - $0 * 10) }
        let up2: [Double] = (1...6).map { Double(120 + $0 * 10) }
        let path: [Double] = up1 + down + up2
        var c: [Candle] = []
        for (i, p) in path.enumerated() { c.append(bar(i, p, p + 1, p - 1, p)) }
        let dd = try #require(History.maxDrawdown(c))
        #expect(abs(dd.percent - (-40)) < 1e-9)
        #expect(dd.recovered == nil)
        let kinds = History.regimes(c).map(\.kind)
        #expect(kinds == [.bull, .bear, .bull])
    }

    @Test func snapshotHasStableIDsAndCompactPack() throws {
        let snap = try #require(FeatureEngine.snapshot(GoldenSeries.candles, timeframe: .d1))
        let ids = Set(snap.features.map(\.id))
        for required in ["D.RSI14", "D.MACD", "D.ATR14", "D.SMA20", "D.ADX14", "D.BB.POS", "D.HIST.TOTAL"] {
            #expect(ids.contains(required), "missing \(required)")
        }
        #expect(ids.count == snap.features.count, "feature IDs must be unique")
        let rsi = try #require(snap.features.first { $0.id == "D.RSI14" }?.value)
        #expect(abs(rsi - 41.477981326734145) < 1e-8)

        let instrument = Instrument(id: "binance:TEST", provider: .binance, symbol: "TEST/USDT", name: "TEST",
                                    exchange: "Binance", segment: "CRYPTO", kind: .crypto, currency: "USDT")
        let json = FeatureEngine.featurePackJSON(snap, instrument: instrument)
        #expect(json.contains("\"D.RSI14\""))
        #expect(json.count < 8_000, "feature pack must stay small for the AI (\(json.count) chars)")
        #expect(FeatureEngine.snapshot(Array(GoldenSeries.candles.prefix(10)), timeframe: .d1) == nil)
    }
}
