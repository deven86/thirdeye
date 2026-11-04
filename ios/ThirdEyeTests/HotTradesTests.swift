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
         {"symbol":"FDUSDUSDT","quoteVolume":"4000"}]
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
        let json = String(decoding: try HotPrompts.schema.data(), as: UTF8.self)
        #expect(json.contains("\"additionalProperties\":false"))
        #expect(!json.contains("maxItems"))
    }
}
