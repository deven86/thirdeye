import Foundation
import Observation
import UserNotifications

/// Watches open trades: re-reads the plan's chart, compares the parameters the analysis was based on,
/// suggests where to trail the stop, asks the AI to re-check when something important changed,
/// and notifies on this iPhone. Price levels (entry, stop, targets) are watched 24×7 by the PC monitor;
/// this watches the *reasons* for the trade.
@Observable
final class TradeGuardian {
    /// Latest check per trade (also kept on the trade when it was news).
    private(set) var latest: [UUID: TradeCheck] = [:]
    private(set) var working: Set<UUID> = []
    private(set) var reviewing: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]

    func current(for trade: Trade) -> TradeCheck? {
        guard let mine = latest[trade.id] else { return trade.lastCheck }
        guard let saved = trade.lastCheck else { return mine }
        return mine.at >= saved.at ? mine : saved
    }

    nonisolated static func aiCooldown(_ tf: Timeframe) -> TimeInterval {
        tf.isIntraday ? 2 * 3600 : 12 * 3600
    }

    /// Checks every open trade whose interval has passed. Called when the app becomes active, every few
    /// minutes while it is open, and from background refresh (no AI there — too slow for the time iOS allows).
    func checkDue(trades: TradeStore, market: MarketStore, analyses: AnalysisStore, settings: AppSettings,
                  allowAI: Bool = true, now: Date = Date()) async {
        for t in trades.trades where t.status == .open {
            let run = t.analysisID.flatMap { id in analyses.runs.first { $0.id == id } }
            let tf = TradeWatch.timeframe(for: t, run: run)
            let last = current(for: t)?.at ?? .distantPast
            guard now.timeIntervalSince(last) >= TradeWatch.interval(tf) else { continue }
            await check(t.id, trades: trades, market: market, analyses: analyses, settings: settings,
                        askAI: false, allowAutoAI: allowAI)
        }
    }

    /// One trade. `askAI` forces an AI re-check (the button); otherwise the AI runs only when the
    /// parameters changed in a way that matters and automatic re-checks are on.
    func check(_ id: UUID, trades: TradeStore, market: MarketStore, analyses: AnalysisStore, settings: AppSettings,
               askAI: Bool, allowAutoAI: Bool = true) async {
        guard !working.contains(id), let t0 = trades.trade(id: id), t0.status == .open else { return }
        working.insert(id)
        defer { working.remove(id) }
        let run = t0.analysisID.flatMap { rid in analyses.runs.first { $0.id == rid } }
        let tf = TradeWatch.timeframe(for: t0, run: run)
        let candles: [Candle]
        do {
            candles = try await market.candles(for: t0.instrument, timeframe: tf)
        } catch {
            errors[id] = error.localizedDescription
            return
        }
        guard let last = candles.last,
              let snap = await Task.detached(priority: .utility, operation: { FeatureEngine.snapshot(candles, timeframe: tf) }).value else {
            errors[id] = "Not enough \(tf.label) bars to read the chart yet."
            return
        }
        errors[id] = nil
        let price = last.close
        var baselineIsNew = false
        let baseline: WatchParams
        if let b = t0.watchBaseline, b.timeframe == tf { baseline = b }
        else if let b = run?.watchBaseline, b.timeframe == tf { baseline = b }
        else { baseline = WatchParams(snap, price: t0.fills.first(where: { $0.kind == .entry })?.price ?? price); baselineIsNew = true }

        var result = TradeWatch.check(t0, baseline: baseline, snapshot: snap, price: price, candles: candles)
        let previous = current(for: t0)
        let news = TradeWatch.isNews(result, previous: previous)
        let lastAI = t0.lastAIReview?.at ?? .distantPast
        let autoAI = allowAutoAI && settings.autoAIReview && news && result.status != .intact
            && Date().timeIntervalSince(lastAI) >= Self.aiCooldown(tf)
        if askAI || autoAI {
            reviewing.insert(id)
            let ref = settings.tierAssignments[.balanced] ?? settings.tierAssignments[.fast]
            let review = await TradeReviewer.review(t0, run: run, baseline: baseline, now: WatchParams(snap, price: price),
                                                     check: result, snapshot: snap, ref: ref)
            reviewing.remove(id)
            switch review {
            case .success(let r): result.ai = r
            case .failure(let e): errors[id] = "AI re-check: \(e.localizedDescription)"
            }
        }
        if (news || result.ai != nil) && settings.watchNotifications && !askAI {
            await Self.notify(t0, check: result)
            result.notified = true
        }
        latest[id] = result
        // Persist (and sync to the iPad) only what matters: news, AI answers, a new baseline.
        if news || result.ai != nil || baselineIsNew, var t = trades.trade(id: id) {
            if t.watchBaseline == nil || baselineIsNew { t.watchBaseline = baseline }
            if news || result.ai != nil {
                t.watchLog = Array(([result] + (t.watchLog ?? [])).prefix(TradeWatch.keepChecks))
            }
            trades.save(t)
        }
    }

    /// Applies the suggested trailing stop (only ever tightens).
    func applyStop(_ price: Double, to id: UUID, trades: TradeStore) {
        guard var t = trades.trade(id: id) else { return }
        let tighter = t.isLong ? price > t.stopLoss : price < t.stopLoss
        guard tighter else { return }
        t.stopLoss = price
        trades.save(t)
    }

    private static func notify(_ t: Trade, check: TradeCheck) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        let icon = check.status == .broken ? "⛔" : check.status == .weakened ? "⚠️" : check.status == .strengthened ? "📈" : "👁"
        content.title = "\(icon) \(t.instrument.symbol) · trade \(check.status.title.lowercased())"
        var lines: [String] = []
        if let ai = check.ai {
            lines.append("AI: \(ai.actionTitle)\(ai.newStop.map { " → stop \(FeatureEngine.plain($0))" } ?? ""). \(ai.summary)")
        }
        if let top = check.changes.first { lines.append("\(top.title): \(top.before) → \(top.now). \(top.advice)") }
        if let trail = check.trail { lines.append("Trail stop to \(FeatureEngine.plain(trail.price)) (\(String(format: "%+.1fR", trail.lockedR)) locked).") }
        content.body = lines.joined(separator: "\n")
        content.sound = .default
        content.userInfo = ["tradeID": t.id.uuidString]
        content.threadIdentifier = t.id.uuidString
        if check.status == .broken { content.interruptionLevel = .timeSensitive }
        let request = UNNotificationRequest(identifier: "watch.\(t.id.uuidString).\(Int(check.at.timeIntervalSince1970))",
                                            content: content, trigger: nil)
        try? await center.add(request)
    }
}

/// The AI half of the watch: one call (Balanced model, web search on Claude) that re-reads the original
/// reasons against today's chart and news, and says what to do. Its answer is checked in code.
nonisolated enum TradeReviewer {
    nonisolated struct ReviewError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static let actions = ["hold", "tighten_stop", "book_partial", "exit", "add"]

    static let system = """
    You monitor ONE open trade for its owner. You are given the parameters the original analysis relied on, \
    the same parameters now (computed in code), the changes code detected, and the current chart facts. \
    Judge only whether the reasons for the trade still hold and what the owner should do now. \
    Rules: never suggest widening the stop or averaging down a losing trade; "add" only if the trade is in \
    profit and clearly stronger; a new stop must be on the protective side of the price and tighter than the \
    current one. Be concrete: prices, percentages, and the condition that would change your answer. \
    Return only JSON: {"status": "strengthened|intact|weakened|broken", "action": "hold|tighten_stop|book_partial|exit|add", \
    "new_stop": number or null, "book_percent": number or null, "summary": "<one or two sentences>", \
    "points": ["<short reason>", ...], "sources": [{"title": "<text>", "url": "<url>"}]}
    """

    static let schema: JSONValue = .object([
        ("type", .string("object")),
        ("properties", .object([
            ("status", .object([("type", .string("string")), ("enum", .array(WatchStatus.allCases.map { JSONValue.string($0.rawValue) }))])),
            ("action", .object([("type", .string("string")), ("enum", .array(actions.map { JSONValue.string($0) }))])),
            ("new_stop", .object([("anyOf", .array([.object([("type", .string("number"))]), .object([("type", .string("null"))])]))])),
            ("book_percent", .object([("anyOf", .array([.object([("type", .string("number"))]), .object([("type", .string("null"))])]))])),
            ("summary", .object([("type", .string("string"))])),
            ("points", .object([("type", .string("array")), ("items", .object([("type", .string("string"))]))])),
            ("sources", .object([("type", .string("array")), ("items", .object([
                ("type", .string("object")),
                ("properties", .object([("title", .object([("type", .string("string"))])), ("url", .object([("type", .string("string"))]))])),
                ("required", .array([.string("title"), .string("url")])),
                ("additionalProperties", .bool(false)),
            ]))])),
        ])),
        ("required", .array(["status", "action", "new_stop", "book_percent", "summary", "points", "sources"].map { JSONValue.string($0) })),
        ("additionalProperties", .bool(false)),
    ])

    static func prompt(_ t: Trade, run: AnalysisRun?, baseline b: WatchParams, now n: WatchParams, check: TradeCheck,
                       pack: String, today: Date) -> String {
        let s = TradeMath.summary(t, lastPrice: check.price)
        let booked = Set(t.fills.compactMap(\.takeProfitStage))
        func p(_ v: Double?) -> String { v.map { FeatureEngine.plain($0) } ?? "—" }
        func params(_ x: WatchParams) -> String {
            "price \(p(x.price)), vs20 \(x.vs20.map { String($0) } ?? "—"), vs50 \(x.vs50.map { String($0) } ?? "—"), structure \(x.structure.map { String($0) } ?? "—"), MACD \(x.macd.map { String($0) } ?? "—"), RSI \(x.rsi.map { String(format: "%.0f", $0) } ?? "—"), ADX \(x.adx.map { String(format: "%.0f", $0) } ?? "—"), ATR \(p(x.atr)), support \(p(x.support)), resistance \(p(x.resistance)), lean \(x.bias)"
        }
        var lines: [String] = []
        lines.append("Today: \(today.formatted(.iso8601.year().month().day()))")
        lines.append("Product: \(t.instrument.symbol) (\(t.instrument.name)) · \(t.instrument.kind.title) · \(t.instrument.exchange) · \(t.instrument.currency)")
        lines.append("Trade: \(t.side.uppercased()), opened \(t.fills.first(where: { $0.kind == .entry })?.date.formatted(.iso8601.year().month().day()) ?? "—"), average entry \(p(s.averageEntry)), current stop \(p(t.stopLoss)) (initial \(p(t.initialStop))), price now \(p(check.price)), result \(s.rMultiple.map { String(format: "%+.2fR", $0) } ?? "—"), complete by \(t.completeBy.formatted(.iso8601.year().month().day())).")
        lines.append("Targets: " + t.takeProfits.map { "TP\($0.stage) \(p($0.price)) book \(Int($0.bookPercent))%\(booked.contains($0.stage) ? " (BOOKED)" : "")" }.joined(separator: "; "))
        if let run {
            lines.append("\nORIGINAL ANALYSIS (\(run.startedAt.formatted(.iso8601.year().month().day())), score \(run.composite ?? 0), \(run.verdict ?? "—")):")
            for st in run.stages where st.status == .done {
                lines.append("- \(st.stage). \(st.name): \(st.score) — \(st.summary.prefix(220))")
            }
            if let plan = run.plan {
                lines.append("Invalidation: \(plan.invalidation)")
                lines.append("Rationale: \(plan.rationale.prefix(400))")
            }
        } else {
            lines.append("\nNo saved analysis: the owner's own idea.")
        }
        lines.append("\nPARAMETERS THEN (\(b.timeframe.label), \(b.at.formatted(.iso8601.year().month().day()))): \(params(b))")
        lines.append("PARAMETERS NOW: \(params(n))")
        lines.append("CHANGES DETECTED BY CODE (\(check.status.rawValue)):")
        if check.changes.isEmpty { lines.append("- none") }
        for c in check.changes { lines.append("- [\(c.effect.rawValue), weight \(c.weight)] \(c.title): \(c.before) → \(c.now)") }
        if let trail = check.trail { lines.append("Code's trailing-stop suggestion: \(p(trail.price)) (\(trail.reason)).") }
        lines.append("\nCHART FACTS NOW:\n\(pack)")
        return lines.joined(separator: "\n")
    }

    static func review(_ t: Trade, run: AnalysisRun?, baseline: WatchParams, now: WatchParams, check: TradeCheck,
                       snapshot: FeatureEngine.Snapshot, ref: ModelRef?) async -> Result<AIReview, ReviewError> {
        guard let ref else {
            return .failure(ReviewError(message: "Choose a Balanced model in Settings → Model Tiers."))
        }
        guard let key = try? KeychainStore().get(ref.provider.keychainAccount) else {
            return .failure(ReviewError(message: "No \(ref.provider.displayName) key."))
        }
        let search = ref.provider == .anthropic
        var user = prompt(t, run: run, baseline: baseline, now: now, check: check,
                          pack: FeatureEngine.featurePackJSON(snapshot, instrument: t.instrument), today: Date())
        user += search
            ? "\n\nSearch the web once or twice for news about \(t.instrument.symbol) since the trade opened. List pages you rely on in \"sources\"."
            : "\n\nNo web access: judge from the chart facts only and say so; \"sources\" must be []."
        let request = AIRequest(system: system, user: user, maxTokens: 1500, webSearch: search, maxSearches: 2,
                                jsonSchema: search ? nil : schema)
        do {
            let response = try await ref.provider.chatClient.complete(request, model: ref.modelID, apiKey: key)
            let obj = try StageParser.extractObject(response.text)
            return .success(validate(obj, trade: t, price: check.price, model: ref.modelID,
                                     cost: Pricing.cost(response.usage, model: ref.modelID), searched: response.searchedSources))
        } catch {
            return .failure(ReviewError(message: error.localizedDescription))
        }
    }

    /// Code has the last word: refuses a looser stop, a stop past the price, and adding to a losing or weak trade.
    static func validate(_ obj: [String: Any], trade t: Trade, price: Double, model: String, cost: Double,
                         searched: [AISource] = [], now: Date = Date()) -> AIReview {
        var warnings: [String] = []
        let status = WatchStatus(rawValue: obj["status"] as? String ?? "") ?? .intact
        var action = obj["action"] as? String ?? "hold"
        if !actions.contains(action) { action = "hold" }
        var newStop = (obj["new_stop"] as? NSNumber)?.doubleValue
        if let ns = newStop {
            let tighter = t.isLong ? ns > t.stopLoss : ns < t.stopLoss
            let safe = t.isLong ? ns < price : ns > price
            if !tighter || !safe {
                warnings.append(!tighter ? "Ignored a suggested stop that was looser than your current one." : "Ignored a suggested stop on the wrong side of the price.")
                newStop = nil
                if action == "tighten_stop" { action = "hold" }
            }
        } else if action == "tighten_stop" {
            warnings.append("The AI said tighten but gave no price — use the trailing suggestion.")
        }
        let r = TradeMath.summary(t, lastPrice: price).rMultiple ?? 0
        if action == "add", !(status == .strengthened && r >= 0.5) {
            warnings.append("Adding refused: only when the trade is clearly stronger and at least +0.5R.")
            action = "hold"
        }
        var book = (obj["book_percent"] as? NSNumber)?.doubleValue
        if let b = book { book = min(max(b, 0), 100) }
        let points = ((obj["points"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(6).map { String($0.prefix(240)) }
        var sources: [StageSourceRef] = []
        for (i, any) in ((obj["sources"] as? [Any]) ?? []).enumerated() {
            guard let d = any as? [String: Any], let url = d["url"] as? String, url.hasPrefix("http") else { continue }
            sources.append(StageSourceRef(id: "src:\(i + 1)", title: (d["title"] as? String) ?? url, url: url, publishedAt: nil))
        }
        if sources.isEmpty {
            sources = searched.prefix(4).enumerated().map { StageSourceRef(id: "src:\($0.offset + 1)", title: $0.element.title, url: $0.element.url, publishedAt: nil) }
        }
        return AIReview(at: now, status: status, action: action, newStop: newStop, bookPercent: book,
                        summary: String((obj["summary"] as? String ?? "").prefix(400)), points: Array(points),
                        sources: Array(sources.prefix(4)), warnings: warnings, model: model, costUSD: cost)
    }
}
