import Foundation
import Testing
@testable import ThirdEye

@Suite("Portfolio maths")
struct PortfolioTests {
    func inst(_ symbol: String, _ currency: String, kind: AssetKind = .equity, exchange: String = "NSE") -> Instrument {
        Instrument(id: "x:\(symbol)", provider: currency == "INR" ? .upstox : .binance, symbol: symbol, name: symbol,
                   exchange: exchange, segment: "", kind: kind, currency: currency)
    }

    func trade(_ i: Instrument, side: String = "long", stop: Double, fills: [Fill], status: TradeStatus = .open,
               mode: TradeMode = .paper) -> Trade {
        Trade(instrument: i, mode: mode, side: side, status: status, plannedEntryLow: 0, plannedEntryHigh: 0,
              stopLoss: stop, initialStop: stop, takeProfits: [], plannedQuantity: 0, badge: .swing,
              completeBy: Date().addingTimeInterval(86_400), fills: fills)
    }

    func fill(_ kind: Fill.Kind, _ price: Double, _ qty: Double, fees: Double = 0, daysAgo: Double = 0) -> Fill {
        Fill(kind: kind, date: Date().addingTimeInterval(-daysAgo * 86_400), price: price, quantity: qty, fees: fees)
    }

    @Test func holdingValueAndOpenRisk() throws {
        // Long 100 @ 200, stop 190 → risk 10 × 100 = 1000. Price 210 → value 21000, unrealised +1000.
        let t = trade(inst("TCS", "INR"), stop: 190, fills: [fill(.entry, 200, 100)])
        let h = try #require(PortfolioMath.holding(t, price: 210))
        #expect(h.cost == 20_000)
        #expect(h.value == 21_000)
        #expect(h.unrealized == 1_000)
        #expect(h.openRisk == 1_000)
        // Stop moved above entry (profit locked) → no open risk.
        var locked = t; locked.stopLoss = 205
        #expect(PortfolioMath.holding(locked, price: 210)?.openRisk == 0)
        // Short 10 @ 50, stop 55 → risk 5 × 10 = 50.
        let s = trade(inst("BTC", "USDT", kind: .crypto, exchange: "Binance"), side: "short", stop: 55, fills: [fill(.entry, 50, 10)])
        #expect(PortfolioMath.holding(s, price: 48)?.openRisk == 50)
        #expect(PortfolioMath.holding(s, price: 48)?.unrealized == 20)
    }

    @Test func summaryPerCurrencyWithRealisedAndRiskShare() throws {
        let tcs = trade(inst("TCS", "INR"), stop: 190, fills: [fill(.entry, 200, 100)])
        // Closed INR trade: 10 @ 100 → 10 @ 120, fees 5 → +195 realised (this month).
        let closed = trade(inst("INFY", "INR"), stop: 90, fills: [fill(.entry, 100, 10), fill(.exit, 120, 10, fees: 5)], status: .closed)
        let btc = trade(inst("BTC", "USDT", kind: .crypto, exchange: "Binance"), stop: 70_000, fills: [fill(.entry, 78_000, 0.1)])
        let realOnly = trade(inst("RELIANCE", "INR"), stop: 1, fills: [fill(.entry, 2, 1)], mode: .real)
        let prices: (Instrument) -> Double? = { $0.symbol == "TCS" ? 210 : $0.symbol == "BTC" ? 79_000 : nil }
        let sums = PortfolioMath.summaries([tcs, closed, btc, realOnly], mode: .paper, prices: prices,
                                           capital: ["INR": 100_000])
        #expect(sums.map(\.currency) == ["INR", "USDT"])
        let inr = sums[0]
        #expect(inr.holdings.count == 1)
        #expect(inr.value == 21_000)
        #expect(inr.realizedAllTime == 195)
        #expect(inr.realizedThisMonth == 195)
        #expect(inr.openRisk == 1_000)
        #expect(inr.openRiskPercentOfCapital == 1)
        #expect(sums[1].value == 7_900)
        #expect(abs((sums[1].unrealized ?? 0) - 100) < 1e-9)

        // ₹21,000 + 7,900 USDT × 84 = ₹6,84,600
        #expect(PortfolioMath.totalInINR(sums, usdInr: 84) == 684_600)
        #expect(PortfolioMath.totalInINR(sums, usdInr: nil) == nil, "never guess a rate")
    }

    @Test func allocationAndEquityCurve() {
        let a = trade(inst("TCS", "INR"), stop: 1, fills: [fill(.entry, 100, 30)])
        let b = trade(inst("INFY", "INR"), stop: 1, fills: [fill(.entry, 100, 10)])
        let holdings = [a, b].compactMap { PortfolioMath.holding($0, price: 100) }
        let slices = PortfolioMath.allocation(holdings, by: .product)
        #expect(slices.map(\.label) == ["TCS", "INFY"])
        #expect(slices.map(\.percent) == [75, 25])

        // Two closed trades on different days: +100 then −40 → curve 100, 60.
        let w = trade(inst("A", "INR"), stop: 1, fills: [fill(.entry, 10, 10, daysAgo: 5), fill(.exit, 20, 10, daysAgo: 3)], status: .closed)
        let l = trade(inst("B", "INR"), stop: 1, fills: [fill(.entry, 10, 10, daysAgo: 2), fill(.exit, 6, 10, daysAgo: 1)], status: .closed)
        let curve = PortfolioMath.equityCurve([w, l], mode: .paper, currency: "INR")
        #expect(curve.map(\.cumulative) == [100, 60])
    }
}
