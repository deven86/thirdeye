import Foundation

// Read-only view of your Upstox account: fills, positions, holdings and stop orders. Nothing here can place,
// change or cancel an order (that would need a registered static IP under the April 2026 rules).

nonisolated struct BrokerFill: Hashable, Sendable, Identifiable {
    var id: String              // "upstox:<trade_id>" (exchange trade ID)
    var instrumentKey: String   // NSE_EQ|INE849A01020 — the same key Third Eye uses for the product
    var symbol: String
    var exchange: String
    var isBuy: Bool
    var quantity: Double
    var price: Double
    var date: Date
    var product: String?        // D (delivery) / I (intraday) / CO …
}

nonisolated struct BrokerPosition: Hashable, Sendable, Identifiable {
    var id: String { "\(source):\(instrumentKey):\(product ?? "")" }
    var instrumentKey: String
    var symbol: String
    var exchange: String
    var quantity: Double        // signed: + long, − short
    var averagePrice: Double
    var lastPrice: Double?
    var pnl: Double?
    var product: String?
    var source: String          // position / holding
}

nonisolated struct BrokerStop: Hashable, Sendable {
    var instrumentKey: String
    var isBuy: Bool             // a buy stop protects a short
    var trigger: Double
    var quantity: Double
    var kind: String            // SL order / GTT
}

/// A buy/sell order waiting at Upstox (placed, scheduled for the next session, or open) — not a stop-loss.
nonisolated struct BrokerOrder: Hashable, Sendable, Identifiable {
    var id: String
    var instrumentKey: String
    var symbol: String
    var exchange: String
    var isBuy: Bool
    var quantity: Double        // still to fill
    var price: Double?          // nil = market
    var status: String          // "scheduled" (after-market order) / "open" …
}

nonisolated struct BrokerSnapshot: Sendable {
    var fills: [BrokerFill]
    var positions: [BrokerPosition]
    var stops: [BrokerStop]
    var warnings: [String]
    var orders: [BrokerOrder] = []
}

nonisolated enum UpstoxPortfolioError: LocalizedError {
    case notLoggedIn
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Log in to Upstox first (Settings → Market Data). The session ends every morning around 3:30 AM."
        case .http(let code, let msg): code == 401 ? "Upstox session expired — log in again in Settings → Market Data." : "Upstox \(code): \(msg)"
        }
    }
}

nonisolated struct UpstoxPortfolioClient: Sendable {
    let accessToken: String
    var session: URLSession = .shared

    static let ist = TimeZone(identifier: "Asia/Kolkata")!

    private func get(_ path: String, query: [String: String] = [:]) async throws -> Any {
        var c = URLComponents(string: "https://api.upstox.com\(path)")!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!, timeoutInterval: 20)
        r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: data)
        guard code == 200 else {
            let msg = ((obj as? [String: Any])?["errors"] as? [[String: Any]])?.first?["message"] as? String ?? "request failed"
            throw UpstoxPortfolioError.http(code, msg)
        }
        return (obj as? [String: Any])?["data"] ?? []
    }

    /// Everything at once; a part that fails becomes a warning instead of failing the whole sync.
    func snapshot(historyDays: Int = 30, now: Date = Date()) async throws -> BrokerSnapshot {
        var warnings: [String] = []
        var fills: [String: BrokerFill] = [:]
        // Today's fills carry exact times; older ones come from trade history (date only).
        do {
            for f in Self.parseTradesToday(try await get("/v2/order/trades/get-trades-for-day")) { fills[f.id] = f }
        } catch let e as UpstoxPortfolioError {
            if case .http(401, _) = e { throw e }
            warnings.append("Today's trades: \(e.localizedDescription)")
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = Self.ist
        let start = f.string(from: now.addingTimeInterval(-Double(historyDays) * 86_400))
        // History up to yesterday only: today's fills come from the endpoint above (Upstox lists them in both,
        // with different IDs, which would add them twice).
        let end = f.string(from: now.addingTimeInterval(-86_400))
        for segment in ["EQ", "FO"] {
            do {
                let data = try await get("/v2/charges/historical-trades",
                                         query: ["segment": segment, "start_date": start, "end_date": end, "page_number": "1", "page_size": "500"])
                for h in Self.parseHistory(data) where fills[h.id] == nil && !fills.values.contains(where: { Self.sameFill($0, h) }) {
                    fills[h.id] = h
                }
            } catch {
                warnings.append("Trade history (\(segment)): \(error.localizedDescription)")
            }
        }
        var positions: [BrokerPosition] = []
        do { positions += Self.parsePositions(try await get("/v2/portfolio/short-term-positions")) }
        catch { warnings.append("Positions: \(error.localizedDescription)") }
        do { positions += Self.parseHoldings(try await get("/v2/portfolio/long-term-holdings")) }
        catch { warnings.append("Holdings: \(error.localizedDescription)") }
        var stops: [BrokerStop] = []
        var orders: [BrokerOrder] = []
        do {
            let all = try await get("/v2/order/retrieve-all")
            stops += Self.parseStopOrders(all)
            orders = Self.parsePendingOrders(all)
        } catch { warnings.append("Orders: \(error.localizedDescription)") }
        do { stops += Self.parseGTT(try await get("/v3/order/gtt")) }
        catch { warnings.append("GTT orders: \(error.localizedDescription)") }
        return BrokerSnapshot(fills: fills.values.sorted { $0.date < $1.date }, positions: positions, stops: stops, warnings: warnings, orders: orders)
    }

    // MARK: Parsing (tolerant: Upstox uses both trading_symbol and tradingsymbol)

    private static func rows(_ any: Any) -> [[String: Any]] {
        if let a = any as? [[String: Any]] { return a }
        if let d = any as? [String: Any] {
            for k in ["trades", "data", "trade_data"] { if let a = d[k] as? [[String: Any]] { return a } }
        }
        return []
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func str(_ d: [String: Any], _ keys: String...) -> String? {
        for k in keys { if let s = d[k] as? String, !s.isEmpty { return s } }
        return nil
    }

    /// The same execution reported twice (today's list and trade history): same share, side, size, price and day.
    static func sameFill(_ a: BrokerFill, _ b: BrokerFill) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ist
        return UpstoxReconciler.productKey(a.instrumentKey) == UpstoxReconciler.productKey(b.instrumentKey) && a.isBuy == b.isBuy
            && abs(a.quantity - b.quantity) < 1e-9 && abs(a.price - b.price) < 0.01 && cal.isDate(a.date, inSameDayAs: b.date)
    }

    static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = ist
        for format in ["yyyy-MM-dd HH:mm:ss", "dd-MM-yyyy HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func parseTradesToday(_ data: Any) -> [BrokerFill] {
        rows(data).compactMap { r in
            guard let tradeID = str(r, "trade_id"), let key = str(r, "instrument_token", "instrument_key"),
                  let q = num(r["quantity"]), q > 0, let p = num(r["average_price"] ?? r["price"]), p > 0 else { return nil }
            return BrokerFill(id: "upstox:\(tradeID)", instrumentKey: key, symbol: str(r, "trading_symbol", "tradingsymbol") ?? key,
                              exchange: str(r, "exchange") ?? "", isBuy: (str(r, "transaction_type") ?? "").uppercased() == "BUY",
                              quantity: q, price: p,
                              date: parseTimestamp(str(r, "exchange_timestamp", "order_timestamp")) ?? Date(),
                              product: str(r, "product"))
        }
    }

    static func parseHistory(_ data: Any) -> [BrokerFill] {
        rows(data).compactMap { r in
            guard let tradeID = str(r, "trade_id"), let key = str(r, "instrument_token", "instrument_key"),
                  let q = num(r["quantity"]), q > 0, let p = num(r["price"]), p > 0 else { return nil }
            // Date only: place it at the market open (09:15 IST) of that day.
            let day = parseTimestamp(str(r, "trade_date")) ?? Date()
            return BrokerFill(id: "upstox:\(tradeID)", instrumentKey: key, symbol: str(r, "symbol", "scrip_name") ?? key,
                              exchange: str(r, "exchange") ?? "", isBuy: (str(r, "transaction_type") ?? "").uppercased() == "BUY",
                              quantity: q, price: p, date: day.addingTimeInterval(9 * 3600 + 15 * 60), product: nil)
        }
    }

    static func parsePositions(_ data: Any) -> [BrokerPosition] {
        rows(data).compactMap { r in
            guard let key = str(r, "instrument_token", "instrument_key"), let q = num(r["quantity"]), q != 0 else { return nil }
            // Upstox can send average_price 0 for a delivery bought today: fall back to the buy/sell price, then the last price.
            let sideKeys = q > 0 ? ["buy_price", "day_buy_price", "overnight_buy_price"] : ["sell_price", "day_sell_price", "overnight_sell_price"]
            let avg = (["average_price"] + sideKeys + ["last_price", "close_price"]).lazy.compactMap { num(r[$0]) }.first { $0 > 0 } ?? 0
            return BrokerPosition(instrumentKey: key, symbol: str(r, "trading_symbol", "tradingsymbol") ?? key, exchange: str(r, "exchange") ?? "",
                                  quantity: q, averagePrice: avg, lastPrice: num(r["last_price"]), pnl: num(r["pnl"]),
                                  product: str(r, "product"), source: "position")
        }
    }

    static func parseHoldings(_ data: Any) -> [BrokerPosition] {
        rows(data).compactMap { r in
            guard let key = str(r, "instrument_token", "instrument_key"), let q = num(r["quantity"]), q > 0 else { return nil }
            return BrokerPosition(instrumentKey: key, symbol: str(r, "trading_symbol", "tradingsymbol") ?? key, exchange: str(r, "exchange") ?? "",
                                  quantity: q, averagePrice: ["average_price", "last_price", "close_price"].lazy.compactMap { num(r[$0]) }.first { $0 > 0 } ?? 0,
                                  lastPrice: num(r["last_price"]),
                                  pnl: num(r["pnl"]), product: "D", source: "holding")
        }
    }

    /// Pending stop-loss orders (SL / SL-M with a trigger price).
    static func parseStopOrders(_ data: Any) -> [BrokerStop] {
        rows(data).compactMap { r in
            let type = (str(r, "order_type") ?? "").uppercased()
            let status = (str(r, "status") ?? "").lowercased()
            let pendingStates = ["open", "trigger pending", "pending", "after market order req received", "modified", "put order req received"]
            guard type.hasPrefix("SL"), pendingStates.contains(status), let key = str(r, "instrument_token", "instrument_key"),
                  let trig = num(r["trigger_price"]), trig > 0 else { return nil }
            let q = num(r["pending_quantity"]) ?? num(r["quantity"]) ?? 0
            return BrokerStop(instrumentKey: key, isBuy: (str(r, "transaction_type") ?? "").uppercased() == "BUY",
                              trigger: trig, quantity: q, kind: "SL order")
        }
    }

    /// Buy/sell orders still waiting to fill (including after-market orders scheduled for the next session).
    static func parsePendingOrders(_ data: Any) -> [BrokerOrder] {
        rows(data).compactMap { r in
            let type = (str(r, "order_type") ?? "").uppercased()
            let status = (str(r, "status") ?? "").lowercased()
            let waiting = ["open", "open pending", "validation pending", "put order req received", "after market order req received",
                           "modify pending", "modified", "not modified", "pending"]
            guard !type.hasPrefix("SL"), waiting.contains(status), let key = str(r, "instrument_token", "instrument_key") else { return nil }
            let q = num(r["pending_quantity"]) ?? num(r["quantity"]) ?? 0
            guard q > 0 else { return nil }
            let price = num(r["price"]).flatMap { $0 > 0 ? $0 : nil }
            return BrokerOrder(id: str(r, "order_id") ?? UUID().uuidString, instrumentKey: key,
                               symbol: str(r, "trading_symbol", "tradingsymbol") ?? key, exchange: str(r, "exchange") ?? "",
                               isBuy: (str(r, "transaction_type") ?? "").uppercased() == "BUY", quantity: q,
                               price: type == "MARKET" ? nil : price,
                               status: status.contains("after market") || (r["is_amo"] as? Bool) == true ? "scheduled" : "open")
        }
    }

    /// Active GTT orders with a STOPLOSS leg.
    static func parseGTT(_ data: Any) -> [BrokerStop] {
        rows(data).compactMap { r in
            let status = (str(r, "status") ?? "active").lowercased()
            guard status == "active" || status == "scheduled", let key = str(r, "instrument_token", "instrument_key"),
                  let rules = r["rules"] as? [[String: Any]],
                  let sl = rules.first(where: { ($0["strategy"] as? String)?.uppercased() == "STOPLOSS" }),
                  let trig = num(sl["trigger_price"]), trig > 0 else { return nil }
            return BrokerStop(instrumentKey: key, isBuy: (str(r, "transaction_type") ?? "").uppercased() == "BUY",
                              trigger: trig, quantity: num(r["quantity"]) ?? 0, kind: "GTT")
        }
    }
}

// MARK: - Matching Upstox to Third Eye

nonisolated enum UpstoxReconciler {
    nonisolated struct Match: Hashable, Sendable, Identifiable {
        var id: String { fill.id }
        var fill: BrokerFill
        var tradeID: UUID
        var isEntry: Bool
        var takeProfitStage: Int?
        /// A fill you typed in yourself that this Upstox fill is (same side and size): it gets Upstox's real
        /// price and time instead of a second fill being added.
        var replacesFill: UUID? = nil
    }

    nonisolated struct Mismatch: Hashable, Sendable, Identifiable {
        var id: UUID { tradeID }
        var tradeID: UUID
        var name: String
        var appQuantity: Double
        var brokerQuantity: Double
        var waitingQuantity: Double = 0    // signed, in orders still to fill
        var orderNote: String? = nil       // "Market buy 1 · scheduled for next session · BSE"
    }

    nonisolated struct StopCheck: Hashable, Sendable, Identifiable {
        var id: UUID { tradeID }
        var tradeID: UUID
        var name: String
        var appStop: Double
        var brokerStop: Double?     // nil = no stop order at Upstox
        var kind: String?
    }

    nonisolated struct Plan: Sendable {
        var matches: [Match] = []
        var unmatchedFills: [BrokerFill] = []
        var untracked: [BrokerPosition] = []
        var mismatches: [Mismatch] = []
        var waiting: [Mismatch] = []       // the gap is an order at Upstox that hasn't filled yet
        var stops: [StopCheck] = []
    }

    /// Same share on NSE and BSE: Upstox keys are "NSE_EQ|<ISIN>" / "BSE_EQ|<ISIN>", so cash-market products
    /// are compared by ISIN. Everything else (F&O, MCX) must match exactly.
    static func productKey(_ key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].hasSuffix("_EQ"), parts[1].count == 12, parts[1].hasPrefix("IN") else { return key }
        return "ISIN:" + parts[1]
    }

    static func importedIDs(_ trades: [Trade]) -> Set<String> {
        Set(trades.flatMap { $0.fills.compactMap(\.brokerID) })
    }

    static func plan(trades: [Trade], snapshot: BrokerSnapshot, ignored: Set<String> = []) -> Plan {
        var plan = Plan()
        let done = importedIDs(trades).union(ignored)
        // Working copies so several fills on one trade are matched in order (entries before exits).
        var working = Dictionary(uniqueKeysWithValues: trades.map { ($0.id, $0) })
        let indian = trades.filter { $0.instrument.provider == .upstox }

        for f in snapshot.fills where !done.contains(f.id) {
            let product = productKey(f.instrumentKey)
            // First: a fill you already recorded yourself (same trade side → entry or exit, same size, within 10 days).
            let linkable = indian.compactMap { working[$0.id] }.filter { productKey($0.instrument.id) == product }
                .sorted { $0.createdAt > $1.createdAt }
            var linked = false
            for t in linkable {
                let kind: Fill.Kind = t.isLong == f.isBuy ? .entry : .exit
                if let i = t.fills.firstIndex(where: { $0.kind == kind && $0.brokerID == nil && abs($0.quantity - f.quantity) < 1e-9
                    && abs($0.date.timeIntervalSince(f.date)) < 10 * 86_400 }) {
                    plan.matches.append(Match(fill: f, tradeID: t.id, isEntry: kind == .entry, takeProfitStage: t.fills[i].takeProfitStage,
                                              replacesFill: t.fills[i].id))
                    var u = t
                    u.fills[i].brokerID = f.id
                    working[t.id] = u
                    linked = true
                    break
                }
            }
            if linked { continue }
            let candidates = indian.compactMap { working[$0.id] }
                .filter { productKey($0.instrument.id) == product && ($0.status == .open || $0.status == .upcoming) }
                .sorted { $0.createdAt > $1.createdAt }
            // An entry adds to a trade on the fill's side; an exit reduces an open one on the other side.
            let entryTrade = candidates.first { ($0.isLong == f.isBuy) && ($0.status == .upcoming || $0.status == .open) }
            let exitTrade = candidates.first { $0.isLong != f.isBuy && $0.status == .open
                && TradeMath.summary($0, lastPrice: nil).openQuantity + 1e-9 >= f.quantity }
            // Prefer closing an open position over opening a new one in the other direction.
            if let t = exitTrade {
                let stage = guessStage(t, price: f.price)
                plan.matches.append(Match(fill: f, tradeID: t.id, isEntry: false, takeProfitStage: stage))
                var u = t
                u.fills.append(Fill(kind: .exit, date: f.date, price: f.price, quantity: f.quantity, takeProfitStage: stage, brokerID: f.id))
                TradeStore.settleStatus(&u)
                working[t.id] = u
            } else if let t = entryTrade {
                plan.matches.append(Match(fill: f, tradeID: t.id, isEntry: true, takeProfitStage: nil))
                var u = t
                u.fills.append(Fill(kind: .entry, date: f.date, price: f.price, quantity: f.quantity, brokerID: f.id))
                TradeStore.settleStatus(&u)
                working[t.id] = u
            } else {
                plan.unmatchedFills.append(f)
            }
        }

        // Positions after the matches: compare quantities, find positions Third Eye doesn't track.
        var brokerQty: [String: Double] = [:]
        for p in snapshot.positions { brokerQty[productKey(p.instrumentKey), default: 0] += p.quantity }
        var pending: [String: Double] = [:]
        var orderNotes: [String: [String]] = [:]
        for o in snapshot.orders {
            let k = productKey(o.instrumentKey)
            pending[k, default: 0] += o.isBuy ? o.quantity : -o.quantity
            let how = o.price.map { "Limit \(o.isBuy ? "buy" : "sell") \(fmtQty(o.quantity)) @ \($0.formatted(.number.precision(.fractionLength(0...2))))" }
                ?? "Market \(o.isBuy ? "buy" : "sell") \(fmtQty(o.quantity))"
            orderNotes[k, default: []].append("\(how) · \(o.status == "scheduled" ? "scheduled for the next session" : "open") · \(o.exchange)")
        }
        let openAfter = working.values.filter { $0.instrument.provider == .upstox && $0.status == .open }
        var appQty: [String: Double] = [:]
        for t in openAfter {
            let q = TradeMath.summary(t, lastPrice: nil).openQuantity
            appQty[productKey(t.instrument.id), default: 0] += t.isLong ? q : -q
        }
        for t in openAfter.sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = productKey(t.instrument.id)
            let b = brokerQty[key] ?? 0, a = appQty[key] ?? 0, w = pending[key] ?? 0
            let listed = plan.mismatches.contains { $0.name == t.instrument.alertName } || plan.waiting.contains { $0.name == t.instrument.alertName }
            if abs(b - a) > 1e-6, !listed {
                var m = Mismatch(tradeID: t.id, name: t.instrument.alertName, appQuantity: a, brokerQuantity: b, waitingQuantity: w,
                                 orderNote: orderNotes[key]?.joined(separator: "\n"))
                if w != 0, abs(b + w - a) < 1e-6 { plan.waiting.append(m) } else { m.waitingQuantity = w; plan.mismatches.append(m) }
            }
            // Nothing held at Upstox yet (order not filled): a stop-loss order can't be placed, so don't nag.
            if abs(b) < 1e-9 { continue }
            let protective = snapshot.stops.filter { productKey($0.instrumentKey) == key && $0.isBuy != t.isLong }
            let nearest = protective.min { abs($0.trigger - t.stopLoss) < abs($1.trigger - t.stopLoss) }
            plan.stops.append(StopCheck(tradeID: t.id, name: t.instrument.alertName, appStop: t.stopLoss,
                                        brokerStop: nearest?.trigger, kind: nearest?.kind))
        }
        let tracked = Set(working.values.filter { $0.status == .open || $0.status == .upcoming }.map { productKey($0.instrument.id) })
        var seen = Set<String>()
        for p in snapshot.positions where !tracked.contains(productKey(p.instrumentKey)) && !ignored.contains("pos:\(p.instrumentKey)") {
            if seen.insert(productKey(p.instrumentKey)).inserted { plan.untracked.append(p) }
        }
        return plan
    }

    /// Fills counted twice (a duplicate Upstox report, or an Upstox fill added next to the one you typed in), found
    /// only where Third Eye holds more than Upstox. Returns (trade, fill) pairs to remove, never more than the excess.
    /// Fills of positions you tracked from Upstox ("pos:…") are never touched.
    static func duplicateFills(trades: [Trade], snapshot: BrokerSnapshot) -> [(trade: UUID, fill: UUID, brokerID: String?)] {
        var brokerQty: [String: Double] = [:]
        for p in snapshot.positions { brokerQty[productKey(p.instrumentKey), default: 0] += p.quantity }
        let todayIDs = Set(snapshot.fills.map(\.id))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = UpstoxPortfolioClient.ist
        let open = trades.filter { $0.instrument.provider == .upstox && $0.status == .open }
        var out: [(UUID, UUID, String?)] = []
        for key in Set(open.map { productKey($0.instrument.id) }) {
            let group = open.filter { productKey($0.instrument.id) == key }
            let app = group.reduce(0.0) { $0 + ($1.isLong ? 1 : -1) * TradeMath.summary($1, lastPrice: nil).openQuantity }
            let b = brokerQty[key] ?? 0
            guard app * b >= 0 || b == 0 else { continue }   // opposite directions: leave it to you
            var excess = abs(app) - abs(b)
            guard excess > 1e-9 else { continue }
            for t in group.sorted(by: { $0.createdAt < $1.createdAt }) {
                let isUpstox: (Fill) -> Bool = { $0.brokerID?.hasPrefix("upstox:") == true }
                var removed = Set<UUID>()
                // 1) Two fills of the same kind, size, price and day where at least one came from Upstox.
                for f in t.fills where excess > 1e-9 && !removed.contains(f.id) {
                    let twins = t.fills.filter { $0.id != f.id && !removed.contains($0.id) && $0.kind == f.kind
                        && abs($0.quantity - f.quantity) < 1e-9 && abs($0.price - f.price) < 0.01 && cal.isDate($0.date, inSameDayAs: f.date) }
                    guard !twins.isEmpty, isUpstox(f) || twins.contains(where: isUpstox) else { continue }
                    // Drop the one Upstox no longer reports (the history duplicate); keep the other.
                    let all = [f] + twins
                    guard let drop = all.first(where: { isUpstox($0) && !todayIDs.contains($0.brokerID!) }) ?? all.last(where: isUpstox),
                          drop.kind == .entry else { continue }
                    removed.insert(drop.id); excess -= drop.quantity
                    out.append((t.id, drop.id, drop.brokerID))
                }
                // 2) A typed-in entry next to an Upstox entry of the same size (added before fills were linked):
                //    the Upstox one has the real price, so the typed one goes.
                for f in t.fills where excess > 1e-9 && f.kind == .entry && f.brokerID == nil && !removed.contains(f.id) {
                    if t.fills.contains(where: { isUpstox($0) && $0.kind == .entry && !removed.contains($0.id) && abs($0.quantity - f.quantity) < 1e-9 }) {
                        removed.insert(f.id); excess -= f.quantity
                        out.append((t.id, f.id, nil))
                    }
                }
            }
        }
        return out
    }

    static func fmtQty(_ q: Double) -> String { q.formatted(.number.precision(.fractionLength(0...4))) }

    /// An exit within 0.3 % of a not-yet-booked target counts as that target.
    static func guessStage(_ t: Trade, price: Double) -> Int? {
        let booked = Set(t.fills.compactMap(\.takeProfitStage))
        return t.takeProfits.first { tp in
            guard let p = tp.price, !booked.contains(tp.stage) else { return false }
            return abs(price / p - 1) <= 0.003
        }?.stage
    }

    /// A trade for a position Third Eye doesn't track yet: entry = Upstox average, stop 5 % away as a
    /// placeholder (the note asks you to set the real one), standard target ladder.
    static func trade(for p: BrokerPosition, instrument: Instrument, now: Date = Date()) -> Trade {
        let long = p.quantity > 0
        let avg = p.averagePrice
        let stop = long ? avg * 0.95 : avg * 1.05
        let risk = abs(avg - stop)
        let tps = TradePlanner.ladder5.enumerated().map { i, step in
            TakeProfit(stage: i + 1, price: step.r.map { long ? avg + $0 * risk : avg - $0 * risk }, rMultiple: step.r,
                       bookPercent: step.pct, then: step.then)
        }
        var t = Trade(instrument: instrument, mode: .real, side: long ? "long" : "short", status: .open,
                      plannedEntryLow: avg, plannedEntryHigh: avg, stopLoss: stop, initialStop: stop, takeProfits: tps,
                      plannedQuantity: abs(p.quantity), badge: p.source == "holding" ? .positional : .swing,
                      completeBy: now.addingTimeInterval(30 * 86_400),
                      notes: "Imported from Upstox (\(p.source)). The stop-loss and targets are placeholders 5% away — tap Edit plan and set your real ones.")
        t.fills = [Fill(kind: .entry, date: now, price: avg, quantity: abs(p.quantity), brokerID: "pos:\(p.instrumentKey)")]
        return t
    }

    /// Minimal product when the instrument list isn't loaded yet.
    static func fallbackInstrument(_ p: BrokerPosition) -> Instrument {
        let segment = String(p.instrumentKey.split(separator: "|").first ?? "NSE_EQ")
        let kind: AssetKind = segment.hasSuffix("_EQ") ? .equity : segment.hasSuffix("_FO") ? .future : .equity
        return Instrument(id: p.instrumentKey, provider: .upstox, symbol: p.symbol, name: p.symbol,
                          exchange: p.exchange.isEmpty ? String(segment.prefix(3)) : p.exchange, segment: segment, kind: kind, currency: "INR")
    }
}
