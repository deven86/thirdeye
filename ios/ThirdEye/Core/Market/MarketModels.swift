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
