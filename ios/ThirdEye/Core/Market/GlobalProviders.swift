import Foundation

// MARK: - Binance (crypto; public market data, no key)

/// Uses Binance's public market-data host `data-api.binance.vision`
/// (no key, not geo-restricted; formats verified 2026-11-04).
nonisolated struct BinanceClient: CandleSource {
    static let base = URL(string: "https://data-api.binance.vision/api/v3")!

    nonisolated struct ExchangeInfo: Decodable {
        nonisolated struct Symbol: Decodable {
            let symbol: String
            let status: String
            let baseAsset: String
            let quoteAsset: String
        }
        let symbols: [Symbol]
    }

    /// Spot pairs quoted in USDT (≈ the liquid universe). Kept small on purpose.
    func instruments() async throws -> [Instrument] {
        var request = URLRequest(url: Self.base.appending(path: "exchangeInfo"))
        request.url = URL(string: request.url!.absoluteString + "?permissions=SPOT")
        let (data, status) = try await MarketHTTP.data(for: request)
        guard status == 200 else { throw MarketDataError.http(status, "Binance symbols") }
        return try Self.parseInstruments(data)
    }

    static func parseInstruments(_ data: Data) throws -> [Instrument] {
        let info: ExchangeInfo
        do { info = try JSONDecoder().decode(ExchangeInfo.self, from: data) } catch {
            throw MarketDataError.decoding("Binance symbols")
        }
        return info.symbols
            .filter { $0.status == "TRADING" && $0.quoteAsset == "USDT" }
            .map {
                Instrument(id: "binance:\($0.symbol)", provider: .binance,
                           symbol: "\($0.baseAsset)/USDT", name: $0.baseAsset,
                           exchange: "Binance", segment: "CRYPTO", kind: .crypto, currency: "USDT")
            }
    }

    static func interval(_ tf: Timeframe) -> String {
        switch tf {
        case .m1: "1m"
        case .m5: "5m"
        case .m15: "15m"
        case .m30: "30m"
        case .h1: "1h"
        case .d1: "1d"
        case .w1: "1w"
        case .mo1: "1M"
        }
    }

    func candles(for instrument: Instrument, timeframe: Timeframe, now: Date) async throws -> [Candle] {
        var components = URLComponents(url: Self.base.appending(path: "klines"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: instrument.providerKey),
            URLQueryItem(name: "interval", value: Self.interval(timeframe)),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        let (data, status) = try await MarketHTTP.data(for: URLRequest(url: components.url!))
        switch status {
        case 200: return try Self.parseKlines(data)
        case 418, 429: throw MarketDataError.rateLimited
        default: throw MarketDataError.http(status, ProviderHTTP.errorMessage(from: data))
        }
    }

    /// `[[openTimeMs, "open", "high", "low", "close", "volume", closeTime, ...], ...]` — prices are strings.
    static func parseKlines(_ data: Data) throws -> [Candle] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw MarketDataError.decoding("Binance klines")
        }
        return rows.compactMap { row in
            guard row.count >= 6,
                  let t = (row[0] as? NSNumber)?.doubleValue,
                  let o = Double("\(row[1])"), let h = Double("\(row[2])"),
                  let l = Double("\(row[3])"), let c = Double("\(row[4])"),
                  let v = Double("\(row[5])") else { return nil }
            return Candle(time: Date(timeIntervalSince1970: t / 1000), open: o, high: h, low: l, close: c, volume: v)
        }.normalized()
    }
}

// MARK: - Twelve Data (US stocks/ETFs, forex, metals)

/// Free Basic plan: 800 credits/day, 8/minute. Lists are cached for a week; charts refresh slowly.
nonisolated struct TwelveDataClient: CandleSource {
    static let base = URL(string: "https://api.twelvedata.com")!
    let apiKey: String

    nonisolated struct ListResponse: Decodable {
        nonisolated struct Item: Decodable {
            let symbol: String
            let name: String?
            let currency: String?
            let exchange: String?
            let type: String?
            let currency_group: String?
            let currency_base: String?
            let currency_quote: String?
            let category: String?
        }
        let data: [Item]?
        let status: String?
        let code: Int?
        let message: String?
    }

    nonisolated struct SeriesResponse: Decodable {
        nonisolated struct Value: Decodable {
            let datetime: String
            let open: String
            let high: String
            let low: String
            let close: String
            let volume: String?
        }
        let values: [Value]?
        let status: String?
        let code: Int?
        let message: String?
    }

    private func get(_ path: String, _ items: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        // Header auth keeps the key out of URLs.
        request.setValue("apikey \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await MarketHTTP.data(for: request)
        if status == 401 || status == 403 { throw MarketDataError.invalidKey }
        if status == 429 { throw MarketDataError.rateLimited }
        guard status == 200 else { throw MarketDataError.http(status, ProviderHTTP.errorMessage(from: data)) }
        return data
    }

    /// Forex pairs (incl. XAU/USD, XAG/USD, USD/INR), US common stocks and US ETFs. 3 credits.
    func instruments() async throws -> [Instrument] {
        async let fx = get("forex_pairs", [])
        async let stocks = get("stocks", [URLQueryItem(name: "country", value: "United States")])
        async let etfs = get("etf", [URLQueryItem(name: "country", value: "United States")])
        return try Self.parseList(try await fx, kind: .forex)
            + Self.parseList(try await stocks, kind: .equity)
            + Self.parseList(try await etfs, kind: .etf)
    }

    static func parseList(_ data: Data, kind: AssetKind) throws -> [Instrument] {
        let response: ListResponse
        do { response = try JSONDecoder().decode(ListResponse.self, from: data) } catch {
            throw MarketDataError.decoding("Twelve Data list")
        }
        if response.status == "error" {
            throw response.code == 401 ? MarketDataError.invalidKey
                : MarketDataError.http(response.code ?? 0, response.message ?? "Twelve Data error")
        }
        var seen = Set<String>()
        return (response.data ?? []).compactMap { item in
            if kind == .equity, let type = item.type, type != "Common Stock" { return nil }
            guard seen.insert(item.symbol).inserted else { return nil } // one listing per symbol
            let isMetal = kind == .forex && (item.symbol.hasPrefix("XAU") || item.symbol.hasPrefix("XAG")
                                             || item.symbol.hasPrefix("XPT") || item.symbol.hasPrefix("XPD"))
            let name: String = {
                if kind == .forex, let b = item.currency_base, let q = item.currency_quote { return "\(b) / \(q)" }
                return item.name ?? item.symbol
            }()
            return Instrument(id: "twelve:\(item.symbol)", provider: .twelveData,
                              symbol: item.symbol, name: name,
                              exchange: item.exchange ?? (kind == .forex ? "FX" : "US"),
                              segment: kind.rawValue.uppercased(),
                              kind: isMetal ? .commodity : kind,
                              currency: item.currency ?? item.symbol.components(separatedBy: "/").last ?? "USD")
        }
    }

    static func interval(_ tf: Timeframe) -> String {
        switch tf {
        case .m1: "1min"
        case .m5: "5min"
        case .m15: "15min"
        case .m30: "30min"
        case .h1: "1h"
        case .d1: "1day"
        case .w1: "1week"
        case .mo1: "1month"
        }
    }

    func candles(for instrument: Instrument, timeframe: Timeframe, now: Date) async throws -> [Candle] {
        let data = try await get("time_series", [
            URLQueryItem(name: "symbol", value: instrument.providerKey),
            URLQueryItem(name: "interval", value: Self.interval(timeframe)),
            URLQueryItem(name: "outputsize", value: "1500"),
            URLQueryItem(name: "timezone", value: "UTC"),
            URLQueryItem(name: "order", value: "asc"),
        ])
        return try Self.parseSeries(data)
    }

    static func parseSeries(_ data: Data) throws -> [Candle] {
        let response: SeriesResponse
        do { response = try JSONDecoder().decode(SeriesResponse.self, from: data) } catch {
            throw MarketDataError.decoding("Twelve Data series")
        }
        if response.status == "error" {
            switch response.code {
            case 401, 403: throw MarketDataError.invalidKey
            case 429: throw MarketDataError.rateLimited
            default: throw MarketDataError.http(response.code ?? 0, response.message ?? "Twelve Data error")
            }
        }
        return (response.values ?? []).compactMap { v in
            guard let time = parseUTC(v.datetime),
                  let o = Double(v.open), let h = Double(v.high), let l = Double(v.low), let c = Double(v.close)
            else { return nil }
            return Candle(time: time, open: o, high: h, low: l, close: c, volume: v.volume.flatMap(Double.init) ?? 0)
        }.normalized()
    }

    /// "2026-11-03 14:30:00" or "2026-11-03", interpreted as UTC (we request timezone=UTC).
    static func parseUTC(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = s.count > 10 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        return f.date(from: s)
    }
}
