import Foundation
import Testing
@testable import ThirdEye

/// Every expected number here is worked out by hand in the comments.
@Suite("Trade maths")
struct TradeMathTests {
    let reliance = Instrument(id: "NSE_EQ|INE002A01018", provider: .upstox, symbol: "RELIANCE", name: "Reliance",
                              exchange: "NSE", segment: "NSE_EQ", kind: .equity, currency: "INR", lotSize: 1, tickSize: 0.1)

    func trade(side: String = "long", stop: Double = 95, fills: [Fill] = [], status: TradeStatus = .open,
               mode: TradeMode = .paper, completeBy: Date = Date().addingTimeInterval(86_400 * 10)) -> Trade {
        let tps = [TakeProfit(stage: 1, price: side == "long" ? 105 : 95, rMultiple: 1, bookPercent: 50, then: ""),
                   TakeProfit(stage: 2, price: side == "long" ? 110 : 90, rMultiple: 2, bookPercent: 50, then: "")]
        return Trade(instrument: reliance, mode: mode, side: side, status: status, plannedEntryLow: 99, plannedEntryHigh: 101,
                     stopLoss: stop, initialStop: stop, takeProfits: tps, plannedQuantity: 100, badge: .swing,
                     completeBy: completeBy, fills: fills)
    }

    func f(_ kind: Fill.Kind, _ price: Double, _ qty: Double, fees: Double = 0, tp: Int? = nil) -> Fill {
        Fill(kind: kind, date: Date(), price: price, quantity: qty, fees: fees, takeProfitStage: tp)
    }

    @Test func longPartialExitWithFees() throws {
        // Entries: 60 @ 100 and 40 @ 102.5 → invested 6000 + 4100 = 10100, avg 101.
        // Exit 50 @ 105 → realized 50 × (105 − 101) = 200, minus fees 20 + 15 = 165.
        // Open 50, last 103 → unrealized 50 × 2 = 100. Total 265.
        // Return 265 / 10100 = 2.6238 %. Risk/unit = 101 − 95 = 6 → R = 265 / (6 × 100) = 0.441666…
        let t = trade(fills: [f(.entry, 100, 60, fees: 20), f(.entry, 102.5, 40), f(.exit, 105, 50, fees: 15, tp: 1)])
        let s = TradeMath.summary(t, lastPrice: 103)
        #expect(s.invested == 10_100)
        #expect(s.averageEntry == 101)
        #expect(s.openQuantity == 50)
        #expect(abs(s.realized - 165) < 1e-9)
        #expect(abs((s.unrealized ?? 0) - 100) < 1e-9)
        #expect(abs((s.total ?? 0) - 265) < 1e-9)
        #expect(abs((s.returnPercent ?? 0) - 2.623762376) < 1e-6)
        #expect(abs((s.rMultiple ?? 0) - 0.4416666667) < 1e-9)
    }

    @Test func shortTradeProfitsWhenPriceFalls() {
        // Short 100 @ 100, cover 100 @ 92 → +800. Risk/unit = 105 − 100 = 5 → R = 800 / 500 = 1.6
        let t = trade(side: "short", stop: 105, fills: [f(.entry, 100, 100), f(.exit, 92, 100)], status: .closed)
        let s = TradeMath.summary(t, lastPrice: nil)
        #expect(s.realized == 800)
        #expect(s.total == 800)
        #expect(s.rMultiple == 1.6)
    }

    @Test func positionSizing() {
        // ₹2,00,000 × 1 % = ₹2,000 risk; entry 100, stop 95 → 400 shares.
        #expect(TradeMath.positionSize(capital: 200_000, riskPercent: 1, entry: 100, stop: 95, lotSize: 1) == 400)
        // F&O lot 65: raw 400 → 6 lots = 390.
        #expect(TradeMath.positionSize(capital: 200_000, riskPercent: 1, entry: 100, stop: 95, lotSize: 65) == 390)
        // Crypto, fractional: $5,000 × 1 % = $50; risk $1,500 per BTC → 0.033333 BTC.
        #expect(TradeMath.positionSize(capital: 5_000, riskPercent: 1, entry: 78_000, stop: 76_500, lotSize: nil) == 0.033333)
        #expect(TradeMath.positionSize(capital: 5_000, riskPercent: 1, entry: 100, stop: 100, lotSize: nil) == 0)
    }

    @Test func signals() {
        let upcoming = trade(status: .upcoming)
        #expect(TradeMath.signal(upcoming, lastPrice: 100) == .inEntryZone)
        if case .nearEntryZone(let pct) = TradeMath.signal(upcoming, lastPrice: 103.02) {
            #expect(abs(pct - 2) < 1e-9) // 103.02 / 101 − 1 = 2 %
        } else { Issue.record("expected nearEntryZone") }

        let open = trade(fills: [f(.entry, 100, 100)])
        #expect(TradeMath.signal(open, lastPrice: 94.9) == .stopHit)
        #expect(TradeMath.signal(open, lastPrice: 111) == .takeProfitReached(stage: 2))
        #expect(TradeMath.signal(open, lastPrice: 104) == TradeMath.Signal.none)

        let booked = trade(fills: [f(.entry, 100, 100), f(.exit, 105, 50, tp: 1)])
        #expect(TradeMath.signal(booked, lastPrice: 106) == TradeMath.Signal.none, "TP1 already booked")

        let overdue = trade(completeBy: Date().addingTimeInterval(-60))
        #expect(TradeMath.signal(overdue, lastPrice: 100) == .pastCompleteBy)
    }

    @Test func journalStatsPerCurrencyAndMode() {
        // Win: +800 (1.6R). Loss: entry 100 → exit 95, 100 qty = −500, R = −500 / (5 × 100) = −1.
        let win = trade(side: "short", stop: 105, fills: [f(.entry, 100, 100), f(.exit, 92, 100)], status: .closed)
        let loss = trade(fills: [f(.entry, 100, 100), f(.exit, 95, 100)], status: .closed)
        let real = trade(fills: [f(.entry, 100, 10), f(.exit, 120, 10)], status: .closed, mode: .real)
        let stats = TradeMath.stats([win, loss, real], mode: .paper)
        let inr = stats["INR"]!
        #expect(inr.closedCount == 2)
        #expect(inr.wins == 1)
        #expect(inr.totalPnL == 300)
        #expect(abs((inr.averageR ?? 0) - 0.3) < 1e-9) // (1.6 + −1) / 2
        #expect(TradeMath.stats([win, loss, real], mode: .real)["INR"]?.totalPnL == 200)
    }
}
