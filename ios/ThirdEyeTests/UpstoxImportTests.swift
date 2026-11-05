import Foundation
import Testing
@testable import ThirdEye

private let trentKey = "NSE_EQ|INE849A01020"
private let trent = Instrument(id: trentKey, provider: .upstox, symbol: "TRENT", name: "Trent", exchange: "NSE",
                               segment: "NSE_EQ", kind: .equity, currency: "INR")
private let t0 = Date(timeIntervalSince1970: 1_793_900_000)

private func trade(long: Bool = true, open: Bool = true, qty: Double = 10) -> Trade {
    let dir = long ? 1.0 : -1.0
    var t = Trade(instrument: trent, mode: .real, side: long ? "long" : "short", status: open ? .open : .upcoming,
                  plannedEntryLow: 3040, plannedEntryHigh: 3070, stopLoss: long ? 2940 : 3170, initialStop: long ? 2940 : 3170,
                  takeProfits: (1...3).map { TakeProfit(stage: $0, price: 3055 + dir * Double($0) * 115, rMultiple: Double($0), bookPercent: 30, then: "") },
                  plannedQuantity: qty, badge: .swing, completeBy: t0.addingTimeInterval(30 * 86_400))
    if open { t.fills.append(Fill(kind: .entry, date: t0.addingTimeInterval(-86_400), price: 3055, quantity: qty)) }
    return t
}

private func fill(_ id: String, buy: Bool, qty: Double, price: Double) -> BrokerFill {
    BrokerFill(id: "upstox:\(id)", instrumentKey: trentKey, symbol: "TRENT", exchange: "NSE", isBuy: buy, quantity: qty,
               price: price, date: t0, product: "D")
}

private func position(_ qty: Double, key: String = trentKey) -> BrokerPosition {
    BrokerPosition(instrumentKey: key, symbol: "TRENT", exchange: "NSE", quantity: qty, averagePrice: 3055, lastPrice: 3100,
                   pnl: 450, product: "D", source: "position")
}

@Suite("Upstox parsers")
struct UpstoxParserTests {
    @Test func tradesForDay() {
        let json: [String: Any] = ["status": "success", "data": [[
            "trade_id": "50000123", "instrument_token": trentKey, "trading_symbol": "TRENT", "exchange": "NSE",
            "transaction_type": "BUY", "quantity": 5, "average_price": 3052.5, "exchange_timestamp": "2026-11-05 10:12:30", "product": "D",
        ]]]
        let f = UpstoxPortfolioClient.parseTradesToday(json)
        #expect(f.count == 1)
        #expect(f[0].id == "upstox:50000123" && f[0].isBuy && f[0].quantity == 5 && f[0].price == 3052.5)
        #expect(f[0].instrumentKey == trentKey)
    }

    @Test func historyAndPositions() {
        let hist: [String: Any] = ["data": [["trade_id": "9", "instrument_token": trentKey, "symbol": "TRENT", "exchange": "NSE",
                                            "transaction_type": "SELL", "quantity": "3", "price": "3170", "trade_date": "2026-11-03"]]]
        let h = UpstoxPortfolioClient.parseHistory(hist)
        #expect(h.count == 1 && !h[0].isBuy && h[0].quantity == 3 && h[0].price == 3170)
        let pos: [String: Any] = ["data": [["instrument_token": trentKey, "trading_symbol": "TRENT", "exchange": "NSE",
                                           "quantity": -4, "average_price": 3100, "product": "I"],
                                          ["instrument_token": "NSE_EQ|X", "quantity": 0]]]
        let p = UpstoxPortfolioClient.parsePositions(pos)
        #expect(p.count == 1 && p[0].quantity == -4)
    }

    @Test func stopsFromOrdersAndGTT() {
        let orders: [String: Any] = ["data": [
            ["order_type": "SL-M", "status": "trigger pending", "instrument_token": trentKey, "transaction_type": "SELL",
             "trigger_price": 2945, "pending_quantity": 10],
            ["order_type": "LIMIT", "status": "open", "instrument_token": trentKey, "trigger_price": 0],
            ["order_type": "SL", "status": "complete", "instrument_token": trentKey, "trigger_price": 2900],
        ]]
        let s = UpstoxPortfolioClient.parseStopOrders(orders)
        #expect(s.count == 1 && s[0].trigger == 2945 && !s[0].isBuy)
        let gtt: [String: Any] = ["data": [["status": "active", "instrument_token": trentKey, "transaction_type": "SELL", "quantity": 10,
                                           "rules": [["strategy": "ENTRY", "trigger_price": 3000], ["strategy": "STOPLOSS", "trigger_price": 2940]]]]]
        let g = UpstoxPortfolioClient.parseGTT(gtt)
        #expect(g.count == 1 && g[0].trigger == 2940 && g[0].kind == "GTT")
    }
}

@Suite("Upstox reconciler")
struct UpstoxReconcilerTests {
    @Test func sellNearTP1IsAnExitAtThatStage() {
        let t = trade()
        let snap = BrokerSnapshot(fills: [fill("1", buy: false, qty: 3, price: 3168)], positions: [position(7)], stops: [], warnings: [])
        let plan = UpstoxReconciler.plan(trades: [t], snapshot: snap)
        #expect(plan.matches.count == 1)
        #expect(plan.matches[0].isEntry == false && plan.matches[0].takeProfitStage == 1)
        #expect(plan.mismatches.isEmpty)
    }

    @Test func buyFillsAnUpcomingTrade() {
        let t = trade(open: false)
        let snap = BrokerSnapshot(fills: [fill("2", buy: true, qty: 10, price: 3050)], positions: [position(10)], stops: [], warnings: [])
        let plan = UpstoxReconciler.plan(trades: [t], snapshot: snap)
        #expect(plan.matches.first?.isEntry == true)
        #expect(plan.untracked.isEmpty && plan.mismatches.isEmpty)
    }

    @Test func alreadyImportedAndIgnoredAreSkipped() {
        var t = trade()
        t.fills.append(Fill(kind: .exit, date: t0, price: 3170, quantity: 3, takeProfitStage: 1, brokerID: "upstox:1"))
        let snap = BrokerSnapshot(fills: [fill("1", buy: false, qty: 3, price: 3170), fill("3", buy: true, qty: 1, price: 1)],
                                  positions: [position(7), position(5, key: "NSE_EQ|OTHER")], stops: [], warnings: [])
        let plan = UpstoxReconciler.plan(trades: [t], snapshot: snap, ignored: ["upstox:3", "pos:NSE_EQ|OTHER"])
        #expect(plan.matches.isEmpty && plan.unmatchedFills.isEmpty && plan.untracked.isEmpty)
    }

    @Test func untrackedMismatchAndStops() {
        let t = trade()
        let stop = BrokerStop(instrumentKey: trentKey, isBuy: false, trigger: 2950, quantity: 10, kind: "SL order")
        let snap = BrokerSnapshot(fills: [], positions: [position(12), position(5, key: "NSE_EQ|INFY")], stops: [stop], warnings: [])
        let plan = UpstoxReconciler.plan(trades: [t], snapshot: snap)
        #expect(plan.mismatches.first?.appQuantity == 10 && plan.mismatches.first?.brokerQuantity == 12)
        #expect(plan.untracked.map(\.instrumentKey) == ["NSE_EQ|INFY"])
        #expect(plan.stops.first?.brokerStop == 2950)
    }

    @Test func applyingMatchesIsIdempotent() {
        let t = trade(open: false)
        let snap = BrokerSnapshot(fills: [fill("2", buy: true, qty: 10, price: 3050)], positions: [], stops: [], warnings: [])
        var trades = [t]
        let plan = UpstoxReconciler.plan(trades: trades, snapshot: snap)
        trades[0].fills.append(Fill(kind: .entry, date: t0, price: 3050, quantity: 10, brokerID: plan.matches[0].fill.id))
        #expect(UpstoxReconciler.plan(trades: trades, snapshot: snap).matches.isEmpty)
    }

    @Test func placeholderTradeForUntrackedPosition() {
        let t = UpstoxReconciler.trade(for: position(-4), instrument: trent, now: t0)
        #expect(!t.isLong && t.stopLoss > 3055 && t.status == .open)
        #expect(TradeMath.summary(t, lastPrice: nil).openQuantity == 4)
    }
}
