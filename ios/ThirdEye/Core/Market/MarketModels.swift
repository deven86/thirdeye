import Foundation

/// Where an instrument's data comes from.
nonisolated enum DataProvider: String, Codable, Sendable, CaseIterable {
    case upstox      // NSE, BSE, MCX, F&O, currency derivatives
    case twelveData  // US stocks/ETFs, forex, metals
    case binance     // crypto (public market data, no key)

    var displayName: String {
        switch self {
        case .upstox: "Upstox"
        case .twelveData: "Twelve Data"
        case .binance: "Binance"
        }
    }
}

/// Broad asset classes used for filters and badges.
nonisolated enum AssetKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case equity, index, future, option, forex, commodity, crypto, etf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .equity: "Stock"
        case .index: "Index"
        case .future: "Future"
        case .option: "Option"
        case .forex: "Forex"
        case .commodity: "Commodity"
        case .crypto: "Crypto"
        case .etf: "ETF"
        }
    }
}

/// A tradable "product". `id` is the provider's stable key
/// (e.g. `NSE_EQ|INE002A01018`, `twelve:EUR/USD`, `binance:BTCUSDT`).
nonisolated struct Instrument: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var provider: DataProvider
    var symbol: String
    var name: String
    var exchange: String
    var segment: String
    var kind: AssetKind
    var currency: String
    var expiry: Date?
    var strike: Double?
    var optionType: String?   // CE / PE
    var lotSize: Double?
    var tickSize: Double?     // in price units (rupees for Indian instruments)
    var underlying: String?

    /// Units in one "1" of quantity, the way brokers count it: forex is traded in lots of 100,000 of the base
    /// currency (MetaTrader: 1.00 lot), gold in lots of 100 oz, silver 5,000 oz. Everything else counts units.
    var contractSize: Double {
        guard provider != .upstox else { return 1 }   // Indian F&O quantity is already in units (lot multiples)
        switch kind {
        case .forex: return 100_000
        case .commodity:
            let s = symbol.uppercased()
            if s.hasPrefix("XAU") { return 100 }
            if s.hasPrefix("XAG") { return 5_000 }
            return 1
        default: return 1
        }
    }

    // MARK: Identity — so a trade is never ambiguous (TRENT on NSE vs BSE vs its futures and options)

    /// Short exchange badge: NSE, BSE, MCX, Binance, FX, US.
    var exchangeBadge: String {
        switch provider {
        case .upstox: segment.hasPrefix("MCX") ? "MCX" : segment.hasPrefix("BSE") || segment.hasPrefix("BCD") ? "BSE" : "NSE"
        case .binance: "Binance"
        case .twelveData: kind == .forex || kind == .commodity ? "FX" : exchange.isEmpty ? "US" : exchange
        }
    }

    /// Market segment in plain words.
    var segmentTitle: String {
        switch segment {
        case "NSE_EQ", "BSE_EQ": "Cash market (stocks / ETFs)"
        case "NSE_FO", "BSE_FO": "Equity derivatives (F&O)"
        case "MCX_FO", "NSE_COM": "Commodity derivatives"
        case "NCD_FO", "BCD_FO": "Currency derivatives"
        case "NSE_INDEX", "BSE_INDEX": "Index (not tradable itself)"
        case "CRYPTO": "Crypto spot"
        case "FOREX": kind == .forex ? "Forex spot" : "Metals spot"
        default: segment
        }
    }

    /// The name a broker shows: TRENT · TRENT FUT 25 Nov 26 · TRENT 3200 CE 25 Nov 26.
    var fullSymbol: String {
        let base = underlying ?? symbol
        let exp = expiry.map { " " + Instrument.expiryFormatter.string(from: $0) } ?? ""
        switch kind {
        case .future: return "\(base) FUT\(exp)"
        case .option:
            let k = strike.map { $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) } ?? ""
            return "\(base) \(k) \(optionType ?? "")\(exp)"
        default: return symbol
        }
    }

    /// One line that identifies the product exactly: "TRENT · NSE · Stock (cash)".
    var identityLine: String {
        var parts = [exchangeBadge]
        switch kind {
        case .equity: parts.append(segment.hasSuffix("_EQ") ? "Stock · cash" : "Stock")
        case .future, .option: parts.append(kind.title + (lotSize.map { $0 > 1 ? " · lot \(Int($0))" : "" } ?? ""))
        default: parts.append(kind.title)
        }
        if let isin { parts.append(isin) }
        return parts.joined(separator: " · ")
    }

    /// ISIN for Indian cash-market products (from the Upstox key, e.g. NSE_EQ|INE849A01020).
    var isin: String? {
        guard provider == .upstox, segment.hasSuffix("_EQ"), let code = id.split(separator: "|").last,
              code.count == 12, code.hasPrefix("IN") else { return nil }
        return String(code)
    }

    /// Name for alerts and the Lock Screen: adds the exchange where it matters.
    var alertName: String {
        provider == .upstox ? "\(fullSymbol) (\(exchangeBadge))" : symbol
    }

    /// Where to find exactly this product at a broker.
    var brokerHint: String {
        switch provider {
        case .upstox:
            switch kind {
            case .equity, .etf:
                return "Search \(symbol) and pick the \(exchangeBadge) row\(isin.map { " (ISIN \($0))" } ?? ""). The \(exchangeBadge == "NSE" ? "BSE" : "NSE") listing is the same company at a slightly different price — use the one you analysed."
            case .future:
                return "Search \(underlying ?? symbol), pick the \(exchangeBadge) future expiring \(expiry.map { Instrument.expiryFormatter.string(from: $0) } ?? "—")\(lotSize.map { $0 > 1 ? ", 1 lot = \(Int($0)) shares" : "" } ?? "")."
            case .option:
                return "Search \(fullSymbol) on \(exchangeBadge)\(lotSize.map { $0 > 1 ? ", 1 lot = \(Int($0))" : "" } ?? "")."
            case .index:
                return "An index can't be bought itself — trade its future, an option or an index ETF."
            default:
                return "Search \(fullSymbol) on \(exchangeBadge)."
            }
        case .binance: return "Binance → Spot → \(symbol)."
        case .twelveData:
            if kind == .forex || kind == .commodity { return "MetaTrader / your FX broker: \(symbol.replacingOccurrences(of: "/", with: "")). Quantity in lots (1 lot = \(Int(contractSize).formatted()) units)." }
            return "Search \(symbol) on your US broker."
        }
    }

    /// "lots" when quantity is counted in lots (forex, gold, silver), otherwise "units".
    var quantityUnit: String { contractSize > 1 ? "lots" : "units" }

    /// Key used by the provider's candle API.
    var providerKey: String {
        switch provider {
        case .upstox: id
        case .twelveData: String(id.dropFirst("twelve:".count))
        case .binance: String(id.dropFirst("binance:".count))
        }
    }

    var subtitle: String {
        var parts = [exchange]
        if kind != .equity { parts.append(kind.title) }
        if let expiry { parts.append(Instrument.expiryFormatter.string(from: expiry)) }
        if name.caseInsensitiveCompare(symbol) != .orderedSame { parts.insert(name, at: 0) }
        return parts.joined(separator: " · ")
    }

    nonisolated(unsafe) static let expiryFormatter: DateFormatter = { // read-only after init
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.dateFormat = "d MMM yy"
        return f
    }()
}

/// One OHLCV bar. `time` is the start of the bar.
nonisolated struct Candle: Hashable, Codable, Sendable {
    var time: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double
}

/// Chart/analysis timeframes from the spec (1 minute to 1 month).
nonisolated enum Timeframe: String, CaseIterable, Identifiable, Codable, Sendable {
    case m1, m5, m15, m30, h1, d1, w1, mo1

    var id: String { rawValue }

    var label: String {
        switch self {
        case .m1: "1m"
        case .m5: "5m"
        case .m15: "15m"
        case .m30: "30m"
        case .h1: "1H"
        case .d1: "1D"
        case .w1: "1W"
        case .mo1: "1M"
        }
    }

    var isIntraday: Bool { [.m1, .m5, .m15, .m30, .h1].contains(self) }

    /// Seconds per bar (approximate for month).
    var seconds: TimeInterval {
        switch self {
        case .m1: 60
        case .m5: 300
        case .m15: 900
        case .m30: 1800
        case .h1: 3600
        case .d1: 86_400
        case .w1: 604_800
        case .mo1: 2_592_000
        }
    }

    /// How often a visible chart refreshes. Spec: short timeframes are watched live.
    var refreshInterval: TimeInterval {
        switch self {
        case .m1: 10
        case .m5, .m15: 30
        case .m30, .h1: 60
        case .d1: 120
        case .w1, .mo1: 600
        }
    }
}

nonisolated enum MarketDataError: LocalizedError, Equatable {
    case notConfigured(String)
    case loginRequired
    case invalidKey
    case rateLimited
    case http(Int, String)
    case decoding(String)
    case network(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): "\(what) is not set up yet. Open Settings → Market Data."
        case .loginRequired: "Your Upstox session has expired. Log in again from Settings → Market Data (Upstox sessions end every morning)."
        case .invalidKey: "The data provider rejected the key. Check it in Settings → Market Data."
        case .rateLimited: "Too many requests to the data provider. Wait a minute and try again."
        case .http(let code, let message): "Data provider error \(code): \(message)"
        case .decoding(let detail): "Unexpected data format (\(detail))."
        case .network(let detail): "Network problem: \(detail)"
        case .unsupported(let detail): detail
        }
    }
}

/// Anything that can supply candles for its own instruments.
nonisolated protocol CandleSource: Sendable {
    func candles(for instrument: Instrument, timeframe: Timeframe, now: Date) async throws -> [Candle]
}

nonisolated enum MarketHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "ThirdEye-iOS"]
        return URLSession(configuration: config)
    }()

    static func data(for request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw MarketDataError.network(error.localizedDescription)
        }
    }
}

extension Array where Element == Candle {
    /// Sorted ascending, one bar per timestamp (later sources win).
    nonisolated func normalized() -> [Candle] {
        var byTime: [Date: Candle] = [:]
        for c in self { byTime[c.time] = c }
        return byTime.values.sorted { $0.time < $1.time }
    }
}
