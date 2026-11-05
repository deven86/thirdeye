import ActivityKit
import Foundation

/// One trade on the Lock Screen and in the Dynamic Island. Shared by the app and the widget extension.
/// The PC monitor sends ContentState as JSON — keep these keys in step with monitor/live.go (LiveState).
nonisolated struct TradeActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var price: Double
        var r: Double?
        var pnlPercent: Double?
        var pnl: Double?            // money: booked + open, in the product's currency
        var stop: Double
        var nextTarget: Double?
        var nextTargetStage: Int?
        var progress: Double        // 0 = at the stop … 1 = at the next target
        var status: String          // waiting · inZone · open · nearStop · stop · target
        var note: String?
        var updatedAt: Double       // Unix seconds

        var updated: Date { Date(timeIntervalSince1970: updatedAt) }
    }

    var tradeID: String
    var symbol: String
    var side: String                // long / short
    var entry: Double
    var currency: String
    var decimals: Int
    var paper: Bool
    var hideMoney: Bool? = nil      // Settings → Hide P&L on Lock Screen

    var isLong: Bool { side != "short" }

    func money(_ v: Double) -> String {
        let symbol = switch currency {
        case "INR": "₹"
        case "USD", "USDT", "USDC": "$"
        case "EUR": "€"
        case "GBP": "£"
        default: ""
        }
        let n = abs(v).formatted(.number.precision(.fractionLength(abs(v) >= 1000 ? 0 : 2)).grouping(.automatic)
            .locale(Locale(identifier: currency == "INR" ? "en_IN" : "en_US")))
        return (v >= 0 ? "+" : "−") + symbol + n
    }

    func format(_ v: Double) -> String {
        let symbol = switch currency {
        case "INR": "₹"
        case "USD", "USDT", "USDC": "$"
        case "EUR": "€"
        case "GBP": "£"
        default: ""
        }
        return symbol + v.formatted(.number.precision(.fractionLength(decimals)).grouping(.automatic)
            .locale(Locale(identifier: currency == "INR" ? "en_IN" : "en_US")))
    }
}
