import Foundation
import Observation

/// Markets the Hot-trades scanner can cover.
nonisolated enum HotMarket: String, CaseIterable, Identifiable, Codable, Sendable {
    case crypto, usStocks, forexMetals, india

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crypto: "Crypto (top 30 by volume)"
        case .usStocks: "US large caps (30)"
        case .forexMetals: "Forex & metals (12)"
        case .india: "India large caps (NSE, ~50)"
        }
    }

    var needs: String? {
        switch self {
        case .crypto: nil
        case .usStocks, .forexMetals: "Needs the free Twelve Data key (Settings → Market Data)."
        case .india: "Needs Upstox logged in today (Settings → Market Data)."
        }
    }

    /// Indian cash shares can only be shorted intraday, so swing scans there are long-only.
    var allowsShorts: Bool { self == .crypto || self == .forexMetals }

    /// Daily bars a product needs before it is screened: room for the 200-day average and a real history.
    /// Keeps out new listings — on Binance that includes tokenised US shares (e.g. SOXLB = a 3× leveraged ETF).
    var minimumBars: Int { self == .crypto ? 400 : 250 }

    static let usSymbols = ["AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "TSLA", "JPM", "V", "MA", "UNH", "XOM", "JNJ", "PG", "HD",
                            "COST", "AVGO", "LLY", "ORCL", "NFLX", "AMD", "CRM", "ADBE", "PEP", "KO", "WMT", "BAC", "DIS", "INTC", "CSCO"]
    static let fxSymbols = ["XAU/USD", "XAG/USD", "EUR/USD", "GBP/USD", "USD/JPY", "USD/INR", "AUD/USD", "USD/CHF", "USD/CAD",
                            "NZD/USD", "EUR/JPY", "GBP/JPY"]
    /// Large, liquid NSE names (curated; not an official index list — symbols not found are skipped).
    static let indiaSymbols = ["RELIANCE", "HDFCBANK", "ICICIBANK", "INFY", "TCS", "BHARTIARTL", "ITC", "LT", "SBIN", "KOTAKBANK",
                               "AXISBANK", "HINDUNILVR", "BAJFINANCE", "MARUTI", "SUNPHARMA", "M&M", "HCLTECH", "TITAN", "ULTRACEMCO",
                               "NTPC", "POWERGRID", "ASIANPAINT", "NESTLEIND", "ONGC", "COALINDIA", "ADANIENT", "ADANIPORTS",
                               "BAJAJFINSV", "WIPRO", "TECHM", "JSWSTEEL", "TATASTEEL", "GRASIM", "HINDALCO", "CIPLA", "DRREDDY",
                               "EICHERMOT", "HEROMOTOCO", "BRITANNIA", "APOLLOHOSP", "SBILIFE", "HDFCLIFE", "INDUSINDBK", "BEL",
                               "TRENT", "SHRIRAMFIN", "BAJAJ-AUTO", "TATACONSUM", "DIVISLAB", "LTIM"]
}

nonisolated struct ScreenRow: Codable, Hashable, Sendable, Identifiable {
    var id: String { instrument.id }
    var instrument: Instrument
    var direction: String       // long / short
    var codeScore: Double
    var summary: String         // compact features for the AI shortlist
    var roc20: Double? = nil
    var aboveSMA50: Bool? = nil
    var trend: String? = nil
    /// 20-day return minus the median of the screened list, in points.
    var relativeStrength: Double? = nil
}

nonisolated struct HotPick: Codable, Hashable, Sendable {
    var instrument: Instrument
    var direction: String
    var reason: String
    var runID: UUID?
    var composite: Int?
    var verdict: String?
    var grade: String? = nil
    var lean: String? = nil
    /// First blocking check that failed (why it is not a trade).
    var blocker: String? = nil
    var error: String? = nil

    nonisolated enum Status: Int, Comparable, Sendable {
        case hot, watch, wait, failed, pending
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    var status: Status {
        if error != nil { return .failed }
        guard let verdict else { return .pending }
        if (Verdict(rawValue: verdict) ?? .noTrade) != .noTrade { return .hot }
        return lean == nil ? .wait : .watch
    }

    var conviction: Int { abs((composite ?? 505) - 505) }
    var gradeRank: Int { grade == "A+" ? 0 : grade == "A" ? 1 : 2 }
}

nonisolated struct HotScan: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var market: HotMarket
    var profile: HoldingProfile
    var startedAt = Date()
    var finishedAt: Date?
    var screened: [ScreenRow] = []
    var skipped: [String] = []
    var picks: [HotPick] = []
    var costUSD = 0.0
    var shortlistNote: String? = nil
    var regime: String? = nil

    /// Picks whose full analysis passed every check (Buy/Strong Buy/Sell/Strong Sell), best first.
    var hotTrades: [HotPick] { ranked.filter { $0.status == .hot } }

    /// Not tradable now, but the score leans clearly one way.
    var watchList: [HotPick] { ranked.filter { $0.status == .watch } }

    /// Hot (by grade, then conviction), then Watch, then the rest.
    var ranked: [HotPick] {
        picks.sorted {
            if $0.status != $1.status { return $0.status < $1.status }
            if $0.gradeRank != $1.gradeRank { return $0.gradeRank < $1.gradeRank }
            return $0.conviction > $1.conviction
        }
    }
}

/// Code-only screening (free, no AI). It finds clean, liquid candidates for the AI to analyse; it does not
/// predict. A walk-forward test (DECISIONS #39) found no simple chart rule with a stable edge.
nonisolated enum HotScreener {
    /// Why a product should not be screened at all, or nil if it is fine.
    static func ineligibility(_ c: [Candle], minimumBars: Int, checkPeg: Bool = true) -> String? {
        if c.count < minimumBars { return "new listing (\(c.count) days of history, needs \(minimumBars))" }
        if checkPeg && isPegged(c) { return "price is pegged (stablecoin-like)" }
        return nil
    }

    /// A coin whose daily changes average under 0.1 % is a stablecoin or fiat token, whatever its name.
    /// (Real coins move 1.5 %+ a day.) Only used for crypto — managed currencies like USD/INR move little too.
    static func isPegged(_ c: [Candle]) -> Bool {
        let closes = Array(c.suffix(31).map(\.close))
        guard closes.count >= 10 else { return false }
        let rets = zip(closes.dropFirst(), closes).map { $0 / $1 - 1 }
        return Indicators.stdev(rets) < 0.001
    }

    static func row(_ instrument: Instrument, candles: [Candle], allowShorts: Bool) -> ScreenRow? {
        guard candles.count >= 60, let snap = FeatureEngine.snapshot(candles, timeframe: .d1) else { return nil }
        let bias = snap.bias
        let lean = bias.bullish - bias.bearish
        let direction = lean >= 0 ? "long" : "short"
        if direction == "short" && !allowShorts { return nil }
        func feature(_ id: String) -> FeatureEngine.Feature? { snap.features.first { $0.id == "D.\(id)" } }
        func v(_ id: String) -> Double? { feature(id)?.value }
        let adx = min(v("ADX14") ?? 15, 45)
        let relVol = min(v("RELVOL20") ?? 1, 3)
        let rsi = v("RSI14") ?? 50
        // Avoid chasing: penalise RSI beyond 75/25 and closes far (> 2.5 ATR) from the 20-day average.
        let stretch = direction == "long" ? max(rsi - 75, 0) : max(25 - rsi, 0)
        let closes = candles.map(\.close)
        var extension = 0.0
        if let a = Indicators.atr(candles).last ?? nil, let m = Indicators.sma(closes, 20).last ?? nil, a > 0, let last = closes.last {
            extension = (last - m) / a * (direction == "long" ? 1 : -1)
        }
        let score = Double(abs(lean)) * 8 + adx * 0.6 + (relVol - 1) * 4 - stretch * 2 - max(extension - 2.5, 0) * 6
        let keys = ["RSI14", "MACD", "ADX14", "SMA50", "SMA200", "CROSS50_200", "RANGE.POS", "ROC20", "RELVOL20", "STRUCTURE"]
        let parts = keys.compactMap { k in feature(k).map { "\(k): \($0.display)" } }

        var trend: String?
        if let s50 = feature("SMA50")?.signal, let cross = feature("CROSS50_200")?.signal {
            switch (s50 > 0, cross > 0) {
            case (true, true): trend = "uptrend (above the 50-day average, 50 above 200)"
            case (false, true): trend = "pullback inside an uptrend"
            case (true, false): trend = "rebound inside a downtrend"
            case (false, false): trend = "downtrend (below the 50-day average, 50 below 200)"
            }
        }
        return ScreenRow(instrument: instrument, direction: direction, codeScore: score,
                         summary: "lean \(lean) · " + parts.joined(separator: "; "),
                         roc20: v("ROC20"), aboveSMA50: feature("SMA50").map { $0.signal > 0 }, trend: trend)
    }

    /// Relative strength against the median of the list (market-neutral): strong names for longs, weak for shorts.
    static func applyRelativeStrength(_ rows: [ScreenRow]) -> [ScreenRow] {
        let rocs = rows.compactMap(\.roc20).sorted()
        guard !rocs.isEmpty else { return rows }
        let median = rocs.count % 2 == 1 ? rocs[rocs.count / 2] : (rocs[rocs.count / 2 - 1] + rocs[rocs.count / 2]) / 2
        return rows.map { r in
            guard let roc = r.roc20 else { return r }
            var out = r
            let rs = roc - median
            out.relativeStrength = rs
            out.codeScore += min(max(rs * (r.direction == "long" ? 1 : -1) * 0.5, -8), 8)
            return out
        }
    }

    /// One line of market context for the shortlist and the results screen.
    static func regime(_ rows: [ScreenRow], benchmark: String?) -> String? {
        let flags = rows.compactMap(\.aboveSMA50)
        guard !flags.isEmpty else { return nil }
        let up = flags.filter { $0 }.count
        let share = Double(up) / Double(flags.count)
        let tone = share >= 0.6 ? "broadly rising market" : share <= 0.4 ? "broadly falling market" : "mixed market"
        var text = "\(up) of \(flags.count) products are above their 50-day average (\(tone))."
        if let benchmark, let b = rows.first(where: { $0.instrument.symbol == benchmark }), let t = b.trend {
            text += " \(benchmark): \(t)."
        }
        return text
    }

    /// Matches a symbol the AI wrote ("PEPE", "PEPEUSDT", "pepe/usdt") to a screened row.
    static func match(_ raw: String, in rows: [ScreenRow]) -> ScreenRow? {
        func norm(_ s: String) -> String { s.uppercased().filter { $0.isLetter || $0.isNumber } }
        let k = norm(raw)
        guard !k.isEmpty else { return nil }
        return rows.first { norm($0.instrument.symbol) == k } ?? rows.first { norm($0.instrument.name) == k }
    }
}

@Observable
final class HotTradesEngine {
    enum Phase: Equatable {
        case idle
        case screening(done: Int, total: Int)
        case shortlisting
        case analysing(index: Int, total: Int, symbol: String)
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var scan: HotScan?
    let analysis = AnalysisEngine()
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .screening, .shortlisting, .analysing: true
        default: false
        }
    }

    /// Rough cost: full analyses of the candidates + one cheap shortlist call.
    static func estimate(settings: AppSettings, picks: Int? = nil) -> Double {
        AnalysisEngine.estimate(settings: settings) * Double(picks ?? settings.hotCandidates) + 0.01
    }

    func start(market: HotMarket, profile: HoldingProfile, candidates: Int, context: AnalysisEngine.Context, store: HotScanStore) {
        guard !isRunning else { return }
        task = Task { await run(market: market, profile: profile, count: candidates, context: context, store: store) }
    }

    func cancel() {
        task?.cancel()
        analysis.cancel()
        phase = .failed("Stopped.")
    }

    private func universe(_ market: HotMarket, store: MarketStore) async throws -> (instruments: [Instrument], skipped: [String]) {
        switch market {
        case .crypto:
            // Extra names so that 30 remain after new listings and pegged tokens are screened out.
            return (try await BinanceClient().topByVolume(limit: 45), [])
        case .usStocks:
            return (HotMarket.usSymbols.map { Instrument(id: "twelve:\($0)", provider: .twelveData, symbol: $0, name: $0,
                                                         exchange: "US", segment: "EQUITY", kind: .equity, currency: "USD") }, [])
        case .forexMetals:
            return (HotMarket.fxSymbols.map { s in
                let metal = s.hasPrefix("XAU") || s.hasPrefix("XAG")
                return Instrument(id: "twelve:\(s)", provider: .twelveData, symbol: s, name: s, exchange: "FX",
                                  segment: "FOREX", kind: metal ? .commodity : .forex,
                                  currency: String(s.split(separator: "/").last ?? "USD"))
            }, [])
        case .india:
            await store.loadUniverse()
            var found: [Instrument] = []
            var missing: [String] = []
            for sym in HotMarket.indiaSymbols {
                if let i = store.index.search(sym, filter: .indiaStocks, limit: 5)
                    .first(where: { $0.symbol.caseInsensitiveCompare(sym) == .orderedSame && $0.exchange == "NSE" }) {
                    found.append(i)
                } else { missing.append("\(sym) — not in the instrument list") }
            }
            return (found, missing)
        }
    }

    private func run(market: HotMarket, profile: HoldingProfile, count: Int, context: AnalysisEngine.Context, store: HotScanStore) async {
        var scan = HotScan(market: market, profile: profile)
        self.scan = scan
        let n = min(max(count, 1), 5)

        // 1. Universe + code screen.
        let list: [Instrument]
        do {
            let u = try await universe(market, store: context.market)
            list = u.instruments
            scan.skipped = u.skipped
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let wanted = market == .crypto ? 30 : list.count
        // Twelve Data's free plan allows 8 requests a minute — pace accordingly.
        let pause: Duration = list.first?.provider == .twelveData ? .milliseconds(7_600) : .milliseconds(120)
        var rows: [ScreenRow] = []
        var eligible = 0
        for (i, instrument) in list.enumerated() {
            if Task.isCancelled { return }
            if eligible >= wanted { break }
            phase = .screening(done: i, total: list.count)
            do {
                let candles = try await context.market.candles(for: instrument, timeframe: .d1)
                if let why = HotScreener.ineligibility(candles, minimumBars: market.minimumBars, checkPeg: market == .crypto) {
                    scan.skipped.append("\(instrument.symbol) — \(why)")
                } else {
                    eligible += 1
                    if let r = await Task.detached(priority: .userInitiated, operation: {
                        HotScreener.row(instrument, candles: candles, allowShorts: market.allowsShorts)
                    }).value { rows.append(r) }
                }
            } catch MarketDataError.loginRequired {
                phase = .failed(MarketDataError.loginRequired.localizedDescription); return
            } catch MarketDataError.notConfigured(let what) {
                phase = .failed(MarketDataError.notConfigured(what).localizedDescription); return
            } catch {
                scan.skipped.append("\(instrument.symbol) — \(error.localizedDescription)")
            }
            try? await Task.sleep(for: pause)
        }
        rows = HotScreener.applyRelativeStrength(rows).sorted { $0.codeScore > $1.codeScore }
        scan.screened = rows
        scan.regime = HotScreener.regime(rows, benchmark: market == .crypto ? "BTC/USDT" : nil)
        self.scan = scan
        guard !rows.isEmpty else { phase = .failed("No product had enough price history to screen."); return }

        // 2. AI shortlist from the top 15 (Fast tier). Falls back to the chart ranking, and says so.
        phase = .shortlisting
        let top = Array(rows.prefix(15))
        var picks = top.prefix(n).map { HotPick(instrument: $0.instrument, direction: $0.direction, reason: "Chart ranking") }
        if let ref = context.settings.tierAssignments[.fast], let key = try? KeychainStore().get(ref.provider.keychainAccount) {
            let request = AIRequest(system: HotPrompts.system,
                                    user: HotPrompts.user(top, count: n, profile: profile, market: market, regime: scan.regime),
                                    maxTokens: 1500, jsonSchema: HotPrompts.schema(symbols: top.map(\.instrument.symbol)))
            do {
                let response = try await ref.provider.chatClient.complete(request, model: ref.modelID, apiKey: key)
                scan.costUSD += Pricing.cost(response.usage, model: ref.modelID)
                let obj = try StageParser.extractObject(response.text)
                var chosen: [HotPick] = []
                for p in (obj["picks"] as? [[String: Any]]) ?? [] {
                    guard let sym = p["symbol"] as? String, let row = HotScreener.match(sym, in: top),
                          !chosen.contains(where: { $0.instrument.id == row.instrument.id }) else { continue }
                    chosen.append(HotPick(instrument: row.instrument, direction: row.direction, reason: (p["reason"] as? String) ?? ""))
                }
                if chosen.isEmpty {
                    scan.shortlistNote = "The AI shortlist named no product from the list — used the chart ranking instead."
                } else {
                    for row in top where chosen.count < n && !chosen.contains(where: { $0.instrument.id == row.instrument.id }) {
                        chosen.append(HotPick(instrument: row.instrument, direction: row.direction, reason: "Chart ranking"))
                    }
                    picks = Array(chosen.prefix(n))
                }
            } catch {
                scan.shortlistNote = "AI shortlist unavailable (\(error.localizedDescription)) — used the chart ranking instead."
            }
        } else {
            scan.shortlistNote = "No Fast model or key — used the chart ranking instead."
        }
        scan.picks = Array(picks)
        self.scan = scan

        // 3. Full 10-stage analysis on each pick, one at a time.
        for i in scan.picks.indices {
            if Task.isCancelled { return }
            phase = .analysing(index: i + 1, total: scan.picks.count, symbol: scan.picks[i].instrument.symbol)
            if let run = await analysis.runAndWait(instrument: scan.picks[i].instrument, profile: profile, context: context) {
                scan.picks[i].runID = run.id
                scan.picks[i].composite = run.composite
                scan.picks[i].verdict = run.verdict
                scan.picks[i].grade = run.grade
                scan.picks[i].lean = run.lean
                scan.picks[i].blocker = run.checks?.first { $0.blocking && !$0.passed }.map { "\($0.title): \($0.detail)" }
                    ?? run.vetoes.first
                scan.costUSD += run.totalCostUSD
            } else {
                if case .failed(let message) = analysis.phase { scan.picks[i].error = message }
                else { scan.picks[i].error = "The analysis did not finish." }
                scan.costUSD += analysis.runningCost
            }
            self.scan = scan
        }
        scan.finishedAt = Date()
        self.scan = scan
        store.save(scan)
        phase = .done
    }
}

nonisolated enum HotPrompts {
    static let system = "You shortlist trade candidates for a deeper analysis, using only the computed chart summaries given. Output only JSON."

    static func user(_ rows: [ScreenRow], count: Int, profile: HoldingProfile, market: HotMarket, regime: String?) -> String {
        var lines = [
            "Holding profile: \(profile.title) (\(profile.subtitle)). Market: \(market.title).",
            "Market context: \(regime ?? "not available")",
            "",
            "Pick the \(count) best candidates for a full 10-stage analysis. Prefer clean trends or setups with room to the next level, "
                + "a direction that fits the market context (or clear relative strength for longs / weakness for shorts), and moves that are "
                + "not stretched far from the 20-day average. Avoid erratic charts and one-candle spikes. Use each symbol exactly as written. "
                + "Each reason under 20 words.",
            "",
            "Candidates (direction from the chart screen; RS = 20-day return minus the list's median, in points):",
        ]
        for r in rows {
            let rs = r.relativeStrength.map { String(format: "%+.1f", $0) } ?? "n/a"
            lines.append("- \(r.instrument.symbol) [\(r.direction) · score \(Int(r.codeScore.rounded())) · RS \(rs)] \(r.trend ?? "") · \(r.summary)")
        }
        return lines.joined(separator: "\n")
    }

    private static func symbolSchema(_ symbols: [String]) -> JSONValue {
        var fields: [(String, JSONValue)] = [("type", JSONValue.string("string"))]
        if !symbols.isEmpty { fields.append(("enum", JSONValue.array(symbols.map { JSONValue.string($0) }))) }
        return JSONValue.object(fields)
    }

    /// Structured-output schema; `enum` makes the model copy a symbol exactly from the list.
    static func schema(symbols: [String]) -> JSONValue {
        .object([
            ("type", .string("object")),
            ("properties", .object([
                ("picks", .object([("type", .string("array")), ("items", .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("symbol", symbolSchema(symbols)),
                        ("reason", .object([("type", .string("string"))])),
                    ])),
                    ("required", .array([.string("symbol"), .string("reason")])),
                    ("additionalProperties", .bool(false)),
                ]))])),
            ])),
            ("required", .array([.string("picks")])),
            ("additionalProperties", .bool(false)),
        ])
    }
}

@Observable
final class HotScanStore {
    private(set) var scans: [HotScan] = []

    private static var dir: URL {
        let d = URL.applicationSupportDirectory.appending(path: "hot", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        scans = files.compactMap { try? decoder.decode(HotScan.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ scan: HotScan) {
        scans.removeAll { $0.id == scan.id }
        scans.insert(scan, at: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(scan) {
            try? data.write(to: Self.dir.appending(path: "\(scan.id.uuidString).json"), options: [.atomic, .completeFileProtection])
        }
    }
}
