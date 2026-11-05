import Foundation

/// "What to do" after an analysis, in plain steps: when and where to enter, how much to risk, which target
/// to take, how to trail, and what to do if the market goes the other way. Built entirely in code from the
/// plan, the checks and your risk settings — so the numbers always match the plan.
nonisolated struct ActionPlan: Sendable {
    nonisolated struct Step: Hashable, Sendable, Identifiable {
        var id: String
        var icon: String        // SF Symbol
        var title: String       // WHEN / HOW MUCH / ...
        var lines: [String]
    }

    var headline: String
    var tone: Tone
    var steps: [Step]

    nonisolated enum Tone: String, Sendable { case trade, wait, avoid }
}

nonisolated enum ActionPlanner {
    /// Share of your normal risk per trade, by grade: A+ full, A ¾, B ½.
    static func gradeFactor(_ grade: String?) -> Double {
        switch grade {
        case "A+": 1
        case "A": 0.75
        default: 0.5
        }
    }

    nonisolated struct Inputs: Sendable {
        var capital: Double?           // in the product's currency
        var riskPercent: Double        // normal risk per trade, % of capital
        var paperMode: Bool
        var now: Date = Date()
    }

    static func build(_ run: AnalysisRun, inputs: Inputs) -> ActionPlan {
        let verdict = Verdict(rawValue: run.verdict ?? "") ?? .noTrade
        let i = run.instrument
        let cur = symbol(i.currency)
        func px(_ v: Double) -> String { cur + FeatureEngine.plain(v) }
        func amt(_ v: Double) -> String {
            cur + v.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: i.currency == "INR" ? "en_IN" : "en_US")))
        }
        let atr = run.atr ?? run.baseRate.flatMap { b in run.plan.map { $0.riskPerUnit / max(b.stopATR, 0.01) } }
        let price = run.lastPrice

        guard verdict != .noTrade, let plan = run.plan else {
            return waitPlan(run, plan: run.plan, px: px)
        }

        let long = plan.side == "long"
        let buy = long ? "buy" : "sell"
        let entry = plan.entryMid
        let risk = plan.riskPerUnit
        var steps: [ActionPlan.Step] = []

        // 1. WHEN and WHERE to enter
        var when: [String] = []
        if let price {
            let inZone = price >= plan.entryLow && price <= plan.entryHigh
            let edge = price < plan.entryLow ? plan.entryLow : plan.entryHigh
            when.append(inZone
                        ? "Price \(px(price)) is inside the entry zone \(px(plan.entryLow))–\(px(plan.entryHigh)) now."
                        : "Price \(px(price)) is \(String(format: "%.1f", abs(price / edge - 1) * 100))% \(price > edge ? "above" : "below") the entry zone \(px(plan.entryLow))–\(px(plan.entryHigh)) — wait for it to come to the zone.")
        }
        when.append("Place a LIMIT \(buy) order at \(px(entry)) (middle of the zone). Don't use a market order and don't chase: if price runs \(long ? "above \(px(plan.entryHigh))" : "below \(px(plan.entryLow))") without filling, skip it and re-analyse later.")
        when.append("Cancel the order if price trades \(long ? "below" : "above") \(px(plan.stopLoss)) before you are filled — the setup is then invalid.")
        when.append("The plan is valid until \(plan.completeBy.formatted(date: .abbreviated, time: .omitted)).")
        steps.append(.init(id: "when", icon: "clock", title: "When to \(buy)", lines: when))

        steps.append(.init(id: "where", icon: "building.columns", title: "Where", lines: whereLines(i, long: long, plan: plan, px: px)))

        // 2. HOW MUCH
        let factor = gradeFactor(run.grade)
        let eventSoon = run.checks?.contains { $0.id == "event" && !$0.passed } ?? false
        let cautions = !(run.cautions ?? []).isEmpty
        var riskPct = inputs.riskPercent * factor
        if eventSoon || cautions { riskPct /= 2 }
        var size: [String] = []
        size.append("Risk \(String(format: "%.2g", riskPct))% of your capital on this trade (your normal \(String(format: "%.2g", inputs.riskPercent))% × \(factor == 1 ? "1 for grade A+" : factor == 0.75 ? "¾ for grade A" : "½ for grade \(run.grade ?? "B")")\(eventSoon || cautions ? ", halved again for the event/volatility warning" : "")).")
        if let capital = inputs.capital, capital > 0 {
            let riskAmount = capital * riskPct / 100
            let qty = TradeMath.positionSize(capital: capital, riskPercent: riskPct, entry: entry, stop: plan.stopLoss, lotSize: i.lotSize,
                                                  contractSize: i.contractSize)
            if qty > 0 {
                let cs = i.contractSize
                let value = qty * entry * cs
                let unit = cs > 1 ? " lot\(qty == 1 ? "" : "s") (1 lot = \(Int(cs).formatted()) units)" : ""
                size.append("Quantity \(qty.formatted(.number.precision(.fractionLength(0...6))))\(unit) — if the stop is hit you lose about \(amt(qty * risk * cs)) (\(amt(riskAmount)) allowed).")
                size.append("Position value \(amt(value)) = \(String(format: "%.0f", value / capital * 100))% of your \(amt(capital)) capital.")
                if value > capital {
                    size.append("That is more than your capital: it needs margin/leverage. Without it, buy at most \(Int((capital / entry).rounded(.down))) — the risk is then smaller than planned, which is fine.")
                }
            } else {
                size.append("At this stop distance your capital can't take even one \(i.lotSize.map { $0 > 1 ? "lot of \(Int($0))" : "unit" } ?? "unit") within the risk limit — skip this trade or use paper mode.")
            }
        } else {
            size.append("Set your capital in Settings → Risk to see the exact quantity. Rule: quantity = (capital × \(String(format: "%.2g", riskPct))%) ÷ \(px(risk)) (entry − stop).")
        }
        if inputs.paperMode { size.append("You are in Paper mode — track it without real money first.") }
        steps.append(.init(id: "size", icon: "scalemass", title: "How much to risk", lines: size))

        // 3. STOP
        var stopLines = ["Right after the order fills, place a STOP-LOSS order at \(px(plan.stopLoss)) at your broker (SL-M / stop-market). Never trade without it — app alerts can be late."]
        stopLines.append("Risk per unit \(px(risk)) = \(String(format: "%.1f", risk / entry * 100))% from entry\(atr.map { $0 > 0 ? String(format: ", %.1f × the normal daily swing (ATR)", risk / $0) : "" } ?? "").")
        steps.append(.init(id: "stop", icon: "shield.lefthalf.filled", title: "Stop-loss", lines: stopLines))

        // 4. TARGETS
        var tpLines: [String] = []
        for tp in plan.takeProfits {
            if let p = tp.price {
                let move = abs(p / entry - 1) * 100
                tpLines.append("TP\(tp.stage) \(px(p)) (\(tp.rMultiple.map { String(format: "+%gR", $0) } ?? ""), \(String(format: "%.1f", move))%): \(long ? "sell" : "buy back") \(Int(tp.bookPercent))% → \(tp.then.lowercased()).")
            } else {
                tpLines.append("TP\(tp.stage) runner (\(Int(tp.bookPercent))%): no fixed price — let it run with a trailing stop.")
            }
        }
        if let tp2 = plan.takeProfits.first(where: { $0.stage == 2 })?.price {
            tpLines.append("Main target: TP2 \(px(tp2)). Booking TP1 and TP2 already makes the trade clearly profitable even if the rest stops out at TP1.")
        }
        steps.append(.init(id: "targets", icon: "flag.checkered", title: "Which profit to take", lines: tpLines))

        // 5. TRAILING
        var trail: [String] = []
        trail.append("After TP1: move the stop to breakeven (\(px(entry))) — from then the trade can't lose.")
        if let tp1 = plan.takeProfits.first(where: { $0.stage == 1 })?.price {
            trail.append("After TP2: move the stop to TP1 (\(px(tp1))). After each later target, move it to the previous target.")
        }
        if let atr, atr > 0 {
            trail.append("Runner: keep the stop \(px(2.5 * atr)) (2.5 ATR) \(long ? "below the highest high" : "above the lowest low") since entry, and only ever move it \(long ? "up" : "down").")
        }
        trail.append("The trade watch suggests the exact trailing level after you record your entry.")
        steps.append(.init(id: "trail", icon: "arrow.up.and.down.circle", title: "How to trail the profit", lines: trail))

        // 6. OPPOSITE DIRECTION
        var against: [String] = []
        against.append("Never move the stop further away and never average down (\(long ? "buy more" : "sell more") while losing).")
        if !plan.invalidation.isEmpty { against.append("Exit early, even before the stop, if: \(plan.invalidation)") }
        if let s = long ? run.watchBaseline?.support : run.watchBaseline?.resistance,
           (long && s > plan.stopLoss && s < entry) || (!long && s < plan.stopLoss && s > entry) {
            against.append("A close \(long ? "below the support" : "above the resistance") at \(px(s)) is the first warning: halve the position or tighten the stop.")
        }
        against.append("If the trade watch says \"Weakened\" while you are at −0.5R or worse, cut half. \"Broken\" → exit.")
        if let capital = inputs.capital, capital > 0 {
            let qty = TradeMath.positionSize(capital: capital, riskPercent: riskPct, entry: entry, stop: plan.stopLoss, lotSize: i.lotSize,
                                                  contractSize: i.contractSize)
            if qty > 0 { against.append("Stop hit → exit everything; the loss is about \(amt(qty * risk * i.contractSize)), as planned. No revenge trade — wait for a fresh analysis.") }
        } else {
            against.append("Stop hit → exit everything; the loss is the planned 1R. No revenge trade — wait for a fresh analysis.")
        }
        steps.append(.init(id: "against", icon: "exclamationmark.arrow.triangle.2.circlepath", title: "If it goes the other way", lines: against))

        // 7. TIME
        var time: [String] = []
        let half = max(plan.holdingDays / 2, 1)
        let halfDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: half, to: run.startedAt) ?? plan.completeBy
        if plan.holdingDays >= 2 {
            time.append("If TP1 isn't reached by \(halfDate.formatted(date: .abbreviated, time: .omitted)), the idea is too slow: tighten the stop to halfway or exit.")
        }
        time.append("Close whatever is left by \(plan.completeBy.formatted(date: .abbreviated, time: .omitted)) and re-analyse if you still like it.")
        if eventSoon, let detail = run.checks?.first(where: { $0.id == "event" })?.detail {
            time.append("Event: \(detail). Book most of the position before it or keep the size small — results can gap past any stop.")
        }
        if let c = run.cautions { time.append(contentsOf: c) }
        steps.append(.init(id: "time", icon: "calendar", title: "Time limit", lines: time))

        let headline = "\(verdict.title)\(run.grade.map { " · grade \($0)" } ?? ""): \(buy) \(i.symbol) at \(px(plan.entryLow))–\(px(plan.entryHigh)), stop \(px(plan.stopLoss)), main target \(plan.takeProfits.first(where: { $0.stage == 2 })?.price.map(px) ?? "TP2")."
        return ActionPlan(headline: headline, tone: .trade, steps: steps)
    }

    private static func waitPlan(_ run: AnalysisRun, plan: TradePlan?, px: (Double) -> String) -> ActionPlan {
        var steps: [ActionPlan.Step] = []
        let failed = (run.checks ?? []).filter { $0.blocking && !$0.passed && $0.id != "score" }
        var wait: [String] = []
        if let c = run.composite, Verdict(composite: c) == .noTrade {
            wait.append("The score \(c) is in the No-trade band (381–619): the evidence doesn't point clearly one way.")
        }
        for f in failed.prefix(4) { wait.append("\(f.title): \(f.detail).") }
        if wait.isEmpty { wait.append("The checks did not support a trade.") }
        steps.append(.init(id: "why", icon: "hand.raised", title: "Why not now", lines: wait))

        var watch = run.watchLevels ?? []
        if watch.isEmpty { watch.append("Re-run the analysis in a few days or after a big move.") }
        else { watch.append("Re-run the analysis when one of these happens — that is the moment the picture can change.") }
        steps.append(.init(id: "watch", icon: "binoculars", title: "What to wait for", lines: watch))

        var holding: [String] = []
        let long = (run.composite ?? 500) >= 500
        if let s = run.watchBaseline?.support, !long || (run.composite ?? 500) < 470 {
            holding.append("Already holding it? Keep a stop below \(px(s)) (nearest support). A close below it is a reason to exit.")
        } else if let s = run.watchBaseline?.support {
            holding.append("Already holding it? Keep your stop below \(px(s)) (nearest support).")
        }
        if (run.composite ?? 500) <= 430 { holding.append("The analysis leans down: if you hold it, consider reducing rather than adding.") }
        if let plan {
            holding.append("Reference plan (not a recommendation): \(plan.side) \(px(plan.entryLow))–\(px(plan.entryHigh)), stop \(px(plan.stopLoss)). If you take it anyway, use paper mode or half your normal risk.")
        }
        if !holding.isEmpty { steps.append(.init(id: "holding", icon: "briefcase", title: "If you already hold it", lines: holding)) }

        let lean = run.lean
        return ActionPlan(headline: lean == nil ? "No trade — wait." : "No trade yet — on watch, leaning \(lean == "short" ? "down" : "up").",
                          tone: .wait, steps: steps)
    }

    private static func whereLines(_ i: Instrument, long: Bool, plan: TradePlan, px: (Double) -> String) -> [String] {
        let intraday = plan.holdingDays < 1 || plan.badge == .intraday || plan.badge == .scalp
        switch i.provider {
        case .upstox:
            switch i.kind {
            case .equity, .etf:
                return [intraday
                        ? "Upstox app → \(i.symbol) → \(long ? "Buy" : "Sell") → Intraday → Limit \(px(plan.entryMid)). Intraday positions are squared off by the broker before the close."
                        : "Upstox app → \(i.symbol) → Buy → Delivery → Limit \(px(plan.entryMid)).",
                        "Then add a Stop-loss order (SL-M, trigger \(px(plan.stopLoss))). For several targets use a GTT/OCO order: target and stop together."]
            case .future, .option:
                return ["Upstox app → \(i.symbol) → \(long ? "Buy" : "Sell") → \(intraday ? "Intraday" : "Normal (NRML)") → Limit \(px(plan.entryMid)), in whole lots\(i.lotSize.map { " of \(Int($0))" } ?? "").",
                        "Then a Stop-loss order (SL-M) at \(px(plan.stopLoss)). Watch the expiry date\(i.expiry.map { " (\(Instrument.expiryFormatter.string(from: $0)))" } ?? "")."]
            default:
                return ["In your Upstox app: Limit \(long ? "buy" : "sell") at \(px(plan.entryMid)), then a stop-loss order at \(px(plan.stopLoss))."]
            }
        case .binance:
            return [long
                    ? "Binance → Spot → \(i.symbol) → Buy → Limit \(px(plan.entryMid)). After the fill, add a Stop-Limit (or OCO: take-profit + stop together) at \(px(plan.stopLoss))."
                    : "Shorting crypto needs Margin or Futures on Binance — only if you use them already. Otherwise treat this as \"don't buy now / sell if you hold\"."]
        default:
            return ["At your broker: LIMIT \(long ? "buy" : "sell") at \(px(plan.entryMid)), then a stop order at \(px(plan.stopLoss)). Use an OCO/bracket order if your broker offers one."]
        }
    }

    static func symbol(_ currency: String) -> String {
        switch currency {
        case "INR": "₹"
        case "USD", "USDT", "USDC": "$"
        case "EUR": "€"
        case "GBP": "£"
        case "JPY": "¥"
        default: ""
        }
    }
}
