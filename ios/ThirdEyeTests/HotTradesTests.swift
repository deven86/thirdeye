import Foundation
import Testing
@testable import ThirdEye

@Suite("Hot trades")
struct HotTradesTests {
    func inst(_ s: String) -> Instrument {
        Instrument(id: "binance:\(s)USDT", provider: .binance, symbol: "\(s)/USDT", name: s, exchange: "Binance",
                   segment: "CRYPTO", kind: .crypto, currency: "USDT")
    }

    @Test func topByVolumeSkipsStablecoinsAndLeveragedTokens() throws {
        let json = """
        [{"symbol":"BTCUSDT","quoteVolume":"900"},{"symbol":"USDCUSDT","quoteVolume":"5000"},
         {"symbol":"ETHUSDT","quoteVolume":"800"},{"symbol":"ETHBTC","quoteVolume":"9999"},
         {"symbol":"BTCUPUSDT","quoteVolume":"700"},{"symbol":"SOLUSDT","quoteVolume":"600"},
         {"symbol":"FDUSDUSDT","quoteVolume":"4000"},{"symbol":"XAUTUSDT","quoteVolume":"3000"},
         {"symbol":"UUSDT","quoteVolume":"2500"},{"symbol":"RWUSDUSDT","quoteVolume":"2400"}]
        """
        let list = try BinanceClient.parseTopByVolume(Data(json.utf8), limit: 2)
        #expect(list.map(\.symbol) == ["BTC/USDT", "ETH/USDT"])
        #expect(list.first?.providerKey == "BTCUSDT")
    }

    @Test func screenerRanksTrendsAndRespectsLongOnly() throws {
        // Steady uptrend vs steady downtrend.
        func series(_ slope: Double) -> [Candle] {
            (0..<220).map { i in
                let x = Double(i)
                let c = 100 + slope * x + 2 * sin(x / 3)
                return Candle(time: Date(timeIntervalSince1970: 1_700_000_000 + x * 86_400), open: c - slope, high: c + 1.5,
                              low: c - 1.5, close: c, volume: 1000)
            }
        }
        let up = try #require(HotScreener.row(inst("UP"), candles: series(0.5), allowShorts: true))
        #expect(up.direction == "long")
        #expect(up.summary.contains("RSI14"))
        let down = HotScreener.row(inst("DN"), candles: series(-0.3), allowShorts: true)
        #expect(down?.direction == "short")
        #expect(HotScreener.row(inst("DN"), candles: series(-0.3), allowShorts: false) == nil, "long-only markets drop shorts")
        #expect(HotScreener.row(inst("X"), candles: Array(series(0.5).prefix(30)), allowShorts: true) == nil, "needs 60+ bars")
    }

    func series(_ n: Int, slope: Double = 0.5, wiggle: Double = 2) -> [Candle] {
        (0..<n).map { i in
            let x = Double(i)
            let c = 100 + slope * x + wiggle * sin(x / 3)
            return Candle(time: Date(timeIntervalSince1970: 1_700_000_000 + x * 86_400), open: c - slope, high: c + 1.5,
                          low: c - 1.5, close: c, volume: 1000)
        }
    }

    @Test func newListingsAndPeggedCoinsAreNotScreened() {
        #expect(HotScreener.ineligibility(series(450, wiggle: 6), minimumBars: 400) == nil)
        #expect(HotScreener.ineligibility(series(147), minimumBars: 400)?.contains("new listing") == true,
                "tokenised shares such as SOXLB have ~4 months of history")
        let pegged = (0..<450).map { i in
            let c = 1 + 0.0004 * sin(Double(i))
            return Candle(time: Date(timeIntervalSince1970: Double(i) * 86_400), open: c, high: c + 0.0002, low: c - 0.0002, close: c, volume: 1)
        }
        #expect(HotScreener.ineligibility(pegged, minimumBars: 400)?.contains("pegged") == true)
        #expect(HotScreener.ineligibility(pegged, minimumBars: 400, checkPeg: false) == nil, "forex is never treated as pegged")
    }

    @Test func shortsFollowMarketAndStyle() {
        #expect(HotMarket.crypto.allowsShorts(.swing))
        #expect(!HotMarket.india.allowsShorts(.swing), "no overnight shorts in Indian cash shares")
        #expect(HotMarket.india.allowsShorts(.scalpIntraday))
        #expect(!HotMarket.usStocks.allowsShorts(.swing))
    }

    @Test func aiSymbolsMatchLeniently() {
        let rows = ["PEPE", "ADA", "BTC"].map { ScreenRow(instrument: inst($0), direction: "long", codeScore: 1, summary: "") }
        #expect(HotScreener.match("PEPE/USDT", in: rows)?.instrument.name == "PEPE")
        #expect(HotScreener.match("pepeusdt", in: rows)?.instrument.name == "PEPE")
        #expect(HotScreener.match("ADA", in: rows)?.instrument.name == "ADA")
        #expect(HotScreener.match("DOGE", in: rows) == nil)
        #expect(HotScreener.match("", in: rows) == nil)
    }

    @Test func relativeStrengthRewardsLeadersForLongsAndLaggardsForShorts() {
        var a = ScreenRow(instrument: inst("A"), direction: "long", codeScore: 10, summary: ""); a.roc20 = 12
        var b = ScreenRow(instrument: inst("B"), direction: "long", codeScore: 10, summary: ""); b.roc20 = 2
        var c = ScreenRow(instrument: inst("C"), direction: "short", codeScore: 10, summary: ""); c.roc20 = -6
        let out = HotScreener.applyRelativeStrength([a, b, c])   // median 2
        #expect(out[0].relativeStrength == 10)
        #expect(out[0].codeScore == 15, "+10 points × 0.5")
        #expect(out[1].codeScore == 10)
        #expect(out[2].codeScore == 14, "a laggard helps a short: −8 × −0.5")
    }

    @Test func rankingPutsHotThenWatchThenWait() {
        var scan = HotScan(market: .crypto, profile: .swing)
        scan.picks = [
            HotPick(instrument: inst("W"), direction: "long", reason: "", composite: 600, verdict: "noTrade", lean: "long"),
            HotPick(instrument: inst("B"), direction: "long", reason: "", composite: 640, verdict: "buy", grade: "B"),
            HotPick(instrument: inst("X"), direction: "long", reason: "", composite: 510, verdict: "noTrade"),
            HotPick(instrument: inst("A"), direction: "long", reason: "", composite: 630, verdict: "buy", grade: "A+"),
            HotPick(instrument: inst("F"), direction: "long", reason: "", error: "Cancelled."),
        ]
        #expect(scan.ranked.map(\.instrument.name) == ["A", "B", "W", "X", "F"])
        #expect(scan.hotTrades.map(\.instrument.name) == ["A", "B"])
        #expect(scan.watchList.map(\.instrument.name) == ["W"])
        #expect(scan.picks[2].status == .wait)
    }

    @Test func onlyPassingVerdictsAreHot() {
        var scan = HotScan(market: .crypto, profile: .swing)
        scan.picks = [
            HotPick(instrument: inst("A"), direction: "long", reason: "", composite: 480, verdict: "noTrade"),
            HotPick(instrument: inst("B"), direction: "long", reason: "", composite: 660, verdict: "buy"),
            HotPick(instrument: inst("C"), direction: "short", reason: "", composite: 230, verdict: "strongSell"),
        ]
        #expect(scan.hotTrades.map(\.instrument.symbol) == ["C/USDT", "B/USDT"], "strongest conviction first")
        scan.picks[1].verdict = "noTrade"
        scan.picks[2].verdict = "noTrade"
        #expect(scan.hotTrades.isEmpty)
    }

    @Test func shortlistSchemaIsValidForStructuredOutputs() throws {
        let json = String(decoding: try HotPrompts.schema(symbols: ["BTC/USDT", "ETH/USDT"]).data(), as: UTF8.self)
        #expect(json.contains("\"additionalProperties\":false"))
        #expect(json.contains("\"enum\":[\"BTC\\/USDT\",\"ETH\\/USDT\"]") || json.contains("\"enum\":[\"BTC/USDT\",\"ETH/USDT\"]"))
        #expect(!json.contains("maxItems"))
        let prompt = HotPrompts.user([ScreenRow(instrument: inst("BTC"), direction: "long", codeScore: 31.6, summary: "lean 5", relativeStrength: 2.25)],
                                     count: 3, profile: .swing, market: .crypto, regime: "9 of 28 products are above their 50-day average.")
        #expect(prompt.contains("BTC/USDT [long · score 32 · RS +2.2]") || prompt.contains("BTC/USDT [long · score 32 · RS +2.3]"))
        #expect(prompt.contains("Pick the 3 best"))
    }
}
