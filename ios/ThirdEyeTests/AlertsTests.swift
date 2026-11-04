import Foundation
import Testing
@testable import ThirdEye

@Suite("PC monitor sync")
struct AlertsTests {
    func trade(status: TradeStatus, fills: [Fill] = []) -> Trade {
        let btc = Instrument(id: "binance:BTCUSDT", provider: .binance, symbol: "BTC/USDT", name: "BTC", exchange: "Binance",
                             segment: "CRYPTO", kind: .crypto, currency: "USDT")
        let plan = TradePlanner.build(.init(side: "long", entryLow: 99, entryHigh: 101, stopLoss: 95, holdingDays: 20,
                                            invalidation: "", rationale: ""), lastPrice: 100, atr: 3, tick: 0.01)
        return Trade(instrument: btc, mode: .paper, side: "long", status: status, plannedEntryLow: 99, plannedEntryHigh: 101,
                     stopLoss: 95, initialStop: 95, takeProfits: plan.takeProfits, plannedQuantity: 1, badge: .swing,
                     completeBy: Date(timeIntervalSince1970: 1_796_000_000), fills: fills)
    }

    @Test func onlyUpcomingAndOpenTradesAreWatched() {
        #expect(MonitorWatchTrade.from(trade(status: .upcoming)) != nil)
        #expect(MonitorWatchTrade.from(trade(status: .closed)) == nil)
        #expect(MonitorWatchTrade.from(trade(status: .cancelled)) == nil)
    }

    @Test func mapsTheFieldsTheMonitorNeeds() throws {
        let fills = [Fill(kind: .entry, date: Date(), price: 100, quantity: 2),
                     Fill(kind: .exit, date: Date(), price: 105, quantity: 0.6, takeProfitStage: 1)]
        let w = try #require(MonitorWatchTrade.from(trade(status: .open, fills: fills)))
        #expect(w.provider == "binance" && w.providerKey == "BTCUSDT" && w.kind == "crypto")
        #expect(w.status == "open" && w.side == "long" && w.mode == "paper")
        #expect(w.avgEntry == 100)
        #expect(abs(w.openQuantity - 1.4) < 1e-9)
        #expect(w.targets.first?.booked == true, "TP1 was recorded as an exit")
        let laterTargetsOpen = w.targets.dropFirst().allSatisfy { !$0.booked }
        #expect(laterTargetsOpen)
        #expect(w.targets.first?.price == 105)
        #expect(w.cadenceSeconds == 300)

        // The Go monitor parses RFC 3339 dates and these exact keys.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let json = String(decoding: try enc.encode(w), as: UTF8.self)
        for key in ["\"providerKey\"", "\"entryLow\"", "\"initialStop\"", "\"avgEntry\"", "\"cadenceSeconds\"", "\"bookPercent\"", "\"booked\""] {
            #expect(json.contains(key), "missing \(key)")
        }
        #expect(json.contains("\"completeBy\":\"2026-11-30T"))
    }

    @Test func readsGoTimestamps() throws {
        let nano = try #require(parseMonitorDate("2026-11-05T01:53:05.123456789+05:30"))
        #expect(abs(nano.timeIntervalSince1970 - 1_793_823_785.123) < 0.001)
        #expect(parseMonitorDate("2026-11-05T01:53:05Z") != nil)
        #expect(parseMonitorDate("0001-01-01T00:00:00Z") != nil)
        #expect(parseMonitorDate("nonsense") == nil)
    }

    @Test func addressIsNormalised() {
        #expect(MonitorStore.normalize(" https://My-PC.tail1234.ts.net/ ") == "my-pc.tail1234.ts.net")
        #expect(MonitorStore.normalize("my-pc.tail1234.ts.net.") == "my-pc.tail1234.ts.net")
    }

    @Test func cadenceFollowsTheHoldingStyle() {
        #expect(MonitorWatchTrade.cadence(.scalp) == 30)
        #expect(MonitorWatchTrade.cadence(.positional) == 1800)
        #expect(MonitorWatchTrade.cadence(.longTerm) == 3600)
    }
}
