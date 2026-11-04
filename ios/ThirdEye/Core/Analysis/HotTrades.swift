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
}

nonisolated struct HotPick: Codable, Hashable, Sendable {
    var instrument: Instrument
    var direction: String
    var reason: String
    var runID: UUID?
    var composite: Int?
    var verdict: String?
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

    /// Picks whose full analysis ended in Buy/Strong Buy/Sell/Strong Sell, best first.
    var hotTrades: [HotPick] {
        picks.filter { ($0.verdict.flatMap(Verdict.init(rawValue:)) ?? .noTrade) != .noTrade }
            .sorted { abs(($0.composite ?? 500) - 505) > abs(($1.composite ?? 500) - 505) }
    }
}

/// Code-only screening (free, no AI).
nonisolated enum HotScreener {
    static func row(_ instrument: Instrument, candles: [Candle], allowShorts: Bool) -> ScreenRow? {
        guard candles.count >= 60, let snap = FeatureEngine.snapshot(candles, timeframe: .d1) else { return nil }
        let bias = snap.bias
        let lean = bias.bullish - bias.bearish
        let direction = lean >= 0 ? "long" : "short"
        if direction == "short" && !allowShorts { return nil }
        func v(_ id: String) -> Double? { snap.features.first { $0.id == "D.\(id)" }?.value }
        let adx = min(v("ADX14") ?? 15, 45)
        let relVol = min(v("RELVOL20") ?? 1, 3)
        let rsi = v("RSI14") ?? 50
        // Avoid chasing stretched moves: penalise RSI beyond 75/25 in the trade's direction.
        let stretch = direction == "long" ? max(rsi - 75, 0) : max(25 - rsi, 0)
        let score = Double(abs(lean)) * 10 + adx + (relVol - 1) * 5 - stretch * 2
        let keys = ["RSI14", "MACD", "ADX14", "SMA50", "SMA200", "CROSS50_200", "RANGE.POS", "ROC20", "RELVOL20", "STRUCTURE"]
        let parts = keys.compactMap { k in snap.features.first { $0.id == "D.\(k)" }.map { "\(k): \($0.display)" } }
        return ScreenRow(instrument: instrument, direction: direction, codeScore: score,
                         summary: "\(instrument.symbol) [\(direction), lean \(lean)] " + parts.joined(separator: "; "))
    }
}

@Observable
final class HotTradesEngine {
    enum Phase: Equatable {
        case idle
        case screening(done: Int, total: Int)
        case shortlisting
        case analysing(index: Int, symbol: String)
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

    /// Rough cost: three full analyses + one cheap shortlist call.
    static func estimate(settings: AppSettings, picks: Int = 3) -> Double {
        AnalysisEngine.estimate(settings: settings) * Double(picks) + 0.01
    }

    func start(market: HotMarket, profile: HoldingProfile, context: AnalysisEngine.Context, store: HotScanStore) {
        guard !isRunning else { return }
        task = Task { await run(market: market, profile: profile, context: context, store: store) }
    }

    func cancel() {
        task?.cancel()
        analysis.cancel()
        phase = .failed("Stopped.")
    }

    private func universe(_ market: HotMarket, store: MarketStore) async throws -> (instruments: [Instrument], skipped: [String]) {
        switch market {
        case .crypto:
            return (try await BinanceClient().topByVolume(limit: 30), [])
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
                } else { missing.append(sym) }
            }
            return (found, missing)
        }
    }

    private func run(market: HotMarket, profile: HoldingProfile, context: AnalysisEngine.Context, store: HotScanStore) async {
        var scan = HotScan(market: market, profile: profile)
        self.scan = scan

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
        // Twelve Data's free plan allows 8 requests a minute — pace accordingly.
        let pause: Duration = list.first?.provider == .twelveData ? .milliseconds(7_600) : .milliseconds(120)
        var rows: [ScreenRow] = []
        for (i, instrument) in list.enumerated() {
            if Task.isCancelled { return }
            phase = .screening(done: i, total: list.count)
            do {
                let candles = try await context.market.candles(for: instrument, timeframe: .d1)
                if let r = await Task.detached(priority: .userInitiated, operation: {
                    HotScreener.row(instrument, candles: candles, allowShorts: market.allowsShorts)
                }).value { rows.append(r) }
            } catch MarketDataError.loginRequired {
                phase = .failed(MarketDataError.loginRequired.localizedDescription); return
            } catch MarketDataError.notConfigured(let what) {
                phase = .failed(MarketDataError.notConfigured(what).localizedDescription); return
            } catch {
                scan.skipped.append(instrument.symbol)
            }
            try? await Task.sleep(for: pause)
        }
        rows.sort { $0.codeScore > $1.codeScore }
        scan.screened = rows
        self.scan = scan
        guard !rows.isEmpty else { phase = .failed("No product had enough price history to screen."); return }

        // 2. AI shortlist of 3 from the top 15 (Fast tier; falls back to the code ranking).
        phase = .shortlisting
        let top = Array(rows.prefix(15))
        var picks = top.prefix(3).map { HotPick(instrument: $0.instrument, direction: $0.direction, reason: "Top technical score") }
        if let ref = context.settings.tierAssignments[.fast], let key = try? KeychainStore().get(ref.provider.keychainAccount) {
            let prompt = "Holding profile: \(profile.title). Pick the 3 strongest, cleanest setups from these screened products. "
                + "Prefer clear trends with room to the next level; avoid stretched moves. Use only these symbols.\n\n"
                + top.map(\.summary).joined(separator: "\n")
            let request = AIRequest(system: "You shortlist trade candidates from computed technical summaries. Output only JSON.",
                                    user: prompt, maxTokens: 800, jsonSchema: HotPrompts.schema)
            if let response = try? await ref.provider.chatClient.complete(request, model: ref.modelID, apiKey: key) {
                scan.costUSD += Pricing.cost(response.usage, model: ref.modelID)
                if let obj = try? StageParser.extractObject(response.text),
                   let raw = obj["picks"] as? [[String: Any]] {
                    let chosen: [HotPick] = raw.compactMap { p in
                        guard let sym = p["symbol"] as? String,
                              let row = top.first(where: { $0.instrument.symbol.caseInsensitiveCompare(sym) == .orderedSame }) else { return nil }
                        return HotPick(instrument: row.instrument, direction: row.direction,
                                       reason: (p["reason"] as? String) ?? "")
                    }
                    var seen = Set<String>()
                    let unique = chosen.filter { seen.insert($0.instrument.id).inserted }
                    if unique.count >= 1 { picks = Array(unique.prefix(3)) }
                }
            }
        }
        scan.picks = picks
        self.scan = scan

        // 3. Full 10-stage analysis on each pick, one at a time.
        for i in scan.picks.indices {
            if Task.isCancelled { return }
            phase = .analysing(index: i + 1, symbol: scan.picks[i].instrument.symbol)
            if let run = await analysis.runAndWait(instrument: scan.picks[i].instrument, profile: profile, context: context) {
                scan.picks[i].runID = run.id
                scan.picks[i].composite = run.composite
                scan.picks[i].verdict = run.verdict
                scan.costUSD += run.totalCostUSD
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
    static let schema: JSONValue = .object([
        ("type", .string("object")),
        ("properties", .object([
            ("picks", .object([("type", .string("array")), ("items", .object([
                ("type", .string("object")),
                ("properties", .object([
                    ("symbol", .object([("type", .string("string"))])),
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
