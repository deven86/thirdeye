import Foundation

nonisolated enum TradeMode: String, Codable, Sendable, CaseIterable {
    case paper, real
    var title: String { self == .paper ? "Paper" : "Real" }
}

nonisolated enum TradeStatus: String, Codable, Sendable {
    case upcoming   // waiting for the entry zone
    case open       // entered (fully or partly still open)
    case closed     // all quantity exited
    case cancelled  // never entered
}

nonisolated struct Fill: Codable, Hashable, Sendable, Identifiable {
    nonisolated enum Kind: String, Codable, Sendable { case entry, exit }
    var id: UUID = UUID()
    var kind: Kind
    var date: Date
    var price: Double
    var quantity: Double
    var fees: Double = 0
    /// Which take-profit this exit was (1…5), or nil for stop/manual.
    var takeProfitStage: Int?
    var note: String?
}

/// One trade from idea to close. Synced between devices; `updatedAt` decides conflicts.
nonisolated struct Trade: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var instrument: Instrument
    var analysisID: UUID?
    var analysisScore: Int?
    var analysisVerdict: String?
    var mode: TradeMode
    var side: String                 // long / short
    var status: TradeStatus
    var plannedEntryLow: Double
    var plannedEntryHigh: Double
    var stopLoss: Double             // current stop (can be moved)
    var initialStop: Double          // for R-multiples
    var takeProfits: [TakeProfit]
    var plannedQuantity: Double
    var badge: HoldingBadge
    var completeBy: Date
    var fills: [Fill] = []
    var notes: String = ""
    var againstVerdict = false       // user tracked it although the verdict was No trade
    var createdAt = Date()
    var updatedAt = Date()
    var closedAt: Date?
    // 0.9.1+ trade watch (optional so older saved trades still load)
    var watchBaseline: WatchParams?
    var watchLog: [TradeCheck]?

    var isLong: Bool { side == "long" }
    var lastCheck: TradeCheck? { watchLog?.first }
    var lastAIReview: AIReview? { watchLog?.compactMap(\.ai).first }
    var plannedEntryMid: Double { (plannedEntryLow + plannedEntryHigh) / 2 }
}

/// All money maths in one place. Prices and P&L are in the instrument's own currency — never converted.
nonisolated enum TradeMath {
    nonisolated struct Summary: Equatable {
        var entryQuantity: Double
        var exitQuantity: Double
        var openQuantity: Double
        var averageEntry: Double?
        var averageExit: Double?
        var invested: Double          // Σ entry qty × price
        var fees: Double
        var realized: Double          // after fees
        var unrealized: Double?       // needs a live price
        var total: Double?            // realized + unrealized
        var returnPercent: Double?    // total / invested
        var rMultiple: Double?        // total / (initial risk per unit × entry qty)
    }

    static func summary(_ t: Trade, lastPrice: Double?) -> Summary {
        let entries = t.fills.filter { $0.kind == .entry }
        let exits = t.fills.filter { $0.kind == .exit }
        // Quantities are in lots for forex/gold (see Instrument.contractSize); money always uses units.
        let size = t.instrument.contractSize
        let entryQty = entries.reduce(0) { $0 + $1.quantity }
        let exitQty = exits.reduce(0) { $0 + $1.quantity }
        let notional = entries.reduce(0) { $0 + $1.quantity * $1.price }
        let invested = notional * size
        let avgEntry = entryQty > 0 ? notional / entryQty : nil
        let avgExit = exitQty > 0 ? exits.reduce(0) { $0 + $1.quantity * $1.price } / exitQty : nil
        let fees = t.fills.reduce(0) { $0 + $1.fees }
        let dir: Double = t.isLong ? 1 : -1
        let openQty = max(entryQty - exitQty, 0)

        var realized = -fees
        if let avgEntry {
            realized += exits.reduce(0) { $0 + dir * ($1.price - avgEntry) * $1.quantity * size }
        }
        var unrealized: Double?
        if let avgEntry, let lastPrice, openQty > 0 { unrealized = dir * (lastPrice - avgEntry) * openQty * size }
        if openQty == 0 { unrealized = 0 }
        let total = unrealized.map { realized + $0 }
        let riskPerUnit = avgEntry.map { abs($0 - t.initialStop) } ?? 0
        let r = (total != nil && riskPerUnit > 0 && entryQty > 0) ? total! / (riskPerUnit * entryQty * size) : nil
        let pct = (total != nil && invested > 0) ? total! / invested * 100 : nil
        return Summary(entryQuantity: entryQty, exitQuantity: exitQty, openQuantity: openQty,
                       averageEntry: avgEntry, averageExit: avgExit, invested: invested, fees: fees,
                       realized: realized, unrealized: unrealized, total: total, returnPercent: pct, rMultiple: r)
    }

    /// Quantity so that hitting the stop loses `riskPercent` of `capital`; rounded down to the lot size.
    /// With a contract size (forex/gold) the result is in lots, rounded down to 0.01 lot like MetaTrader.
    static func positionSize(capital: Double, riskPercent: Double, entry: Double, stop: Double, lotSize: Double?,
                             contractSize: Double = 1) -> Double {
        let risk = abs(entry - stop)
        guard capital > 0, riskPercent > 0, risk > 0 else { return 0 }
        if contractSize > 1 {
            let lots = capital * riskPercent / 100 / (risk * contractSize)
            return (lots * 100 + 1e-9).rounded(.down) / 100
        }
        let raw = capital * riskPercent / 100 / risk
        let lot = max(lotSize ?? 0, 0)
        if lot >= 1 { return (raw / lot).rounded(.down) * lot }
        // Fractional instruments (crypto): keep 6 decimals.
        return (raw * 1_000_000).rounded(.down) / 1_000_000
    }

    /// What the live price means for this trade right now (foreground hints; background alerts come in M6).
    nonisolated enum Signal: Equatable {
        case none
        case inEntryZone
        case nearEntryZone(percentAway: Double)
        case stopHit
        case takeProfitReached(stage: Int)
        case pastCompleteBy
    }

    static func signal(_ t: Trade, lastPrice: Double?, now: Date = Date()) -> Signal {
        if (t.status == .open || t.status == .upcoming), now > t.completeBy { return .pastCompleteBy }
        guard let p = lastPrice else { return .none }
        switch t.status {
        case .upcoming:
            if p >= t.plannedEntryLow && p <= t.plannedEntryHigh { return .inEntryZone }
            let edge = p < t.plannedEntryLow ? t.plannedEntryLow : t.plannedEntryHigh
            return .nearEntryZone(percentAway: (p / edge - 1) * 100)
        case .open:
            if t.isLong ? p <= t.stopLoss : p >= t.stopLoss { return .stopHit }
            let booked = Set(t.fills.compactMap(\.takeProfitStage))
            let reached = t.takeProfits.filter { tp in
                guard let tpPrice = tp.price, !booked.contains(tp.stage) else { return false }
                return t.isLong ? p >= tpPrice : p <= tpPrice
            }
            if let highest = reached.map(\.stage).max() { return .takeProfitReached(stage: highest) }
            return .none
        case .closed, .cancelled:
            return .none
        }
    }

    nonisolated struct Stats: Equatable {
        var closedCount = 0
        var wins = 0
        var totalPnL = 0.0
        var rSum = 0.0
        var rCount = 0
        var winRate: Double? { closedCount > 0 ? Double(wins) / Double(closedCount) : nil }
        var averageR: Double? { rCount > 0 ? rSum / Double(rCount) : nil }
    }

    /// Per currency (never mixed), per mode.
    static func stats(_ trades: [Trade], mode: TradeMode) -> [String: Stats] {
        var out: [String: Stats] = [:]
        for t in trades where t.status == .closed && t.mode == mode {
            let s = summary(t, lastPrice: nil)
            var st = out[t.instrument.currency] ?? Stats()
            st.closedCount += 1
            if s.realized > 0 { st.wins += 1 }
            st.totalPnL += s.realized
            if let r = s.rMultiple { st.rSum += r; st.rCount += 1 }
            out[t.instrument.currency] = st
        }
        return out
    }
}
