import Foundation

/// Upstox API (Indian markets), fully on-device for the phone-first build.
///
/// Login: OAuth authorization-code flow. The registered redirect URL is
/// `https://127.0.0.1/thirdeye`; the in-app login sheet intercepts that URL, so nothing
/// ever actually loads from it. The code is exchanged for an access token on the device.
/// Upstox access tokens stop working at about 03:30 IST the next morning.
nonisolated enum UpstoxAuth {
    static let redirectURI = "https://127.0.0.1/thirdeye"
    static let dialogURL = URL(string: "https://api.upstox.com/v2/login/authorization/dialog")!
    static let tokenURL = URL(string: "https://api.upstox.com/v2/login/authorization/token")!

    static func loginURL(apiKey: String, state: String) -> URL {
        var c = URLComponents(url: dialogURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: apiKey),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    nonisolated enum CallbackResult: Equatable {
        case code(String)
        case error(String)
        case notCallback
    }

    /// Recognises the redirect and pulls out `code` (checking `state`).
    static func parseCallback(_ url: URL, expectedState: String) -> CallbackResult {
        guard url.host == "127.0.0.1", url.path.hasPrefix("/thirdeye") else { return .notCallback }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { return .error(value("error_description") ?? error) }
        guard value("state") == expectedState else { return .error("Login response did not match this request.") }
        guard let code = value("code"), !code.isEmpty else { return .error("Upstox did not return a login code.") }
        return .code(code)
    }

    nonisolated struct TokenResponse: Decodable {
        let access_token: String?
        let user_name: String?
        let errors: [ErrorItem]?
        nonisolated struct ErrorItem: Decodable { let message: String? }
    }

    static func exchange(code: String, apiKey: String, apiSecret: String) async throws -> (token: String, user: String?) {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: apiKey),
            URLQueryItem(name: "client_secret", value: apiSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, status) = try await MarketHTTP.data(for: request)
        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard status == 200, let token = decoded?.access_token, !token.isEmpty else {
            let message = decoded?.errors?.first?.message ?? ProviderHTTP.errorMessage(from: data)
            throw MarketDataError.http(status, message)
        }
        return (token, decoded?.user_name)
    }

    /// The next 03:30 IST after `issued`.
    static func expiry(issuedAt issued: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        var comps = cal.dateComponents([.year, .month, .day], from: issued)
        comps.hour = 3
        comps.minute = 30
        let sameDay = cal.date(from: comps)!
        return sameDay > issued ? sameDay : cal.date(byAdding: .day, value: 1, to: sameDay)!
    }
}

/// Fetches candles with a valid access token.
nonisolated struct UpstoxCandleClient: CandleSource {
    let accessToken: String
    static let base = "https://api.upstox.com/v3/historical-candle"

    /// (unit, interval) per the v3 API.
    static func unit(_ tf: Timeframe) -> (String, Int) {
        switch tf {
        case .m1: ("minutes", 1)
        case .m5: ("minutes", 5)
        case .m15: ("minutes", 15)
        case .m30: ("minutes", 30)
        case .h1: ("hours", 1)
        case .d1: ("days", 1)
        case .w1: ("weeks", 1)
        case .mo1: ("months", 1)
        }
    }

    /// History window per request, inside Upstox's documented limits
    /// (1–15 min: 1 month; 16+ min and hours: 1 quarter; days: 1 decade; weeks/months: unlimited from 2000).
    static func fromDate(_ tf: Timeframe, now: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        switch tf {
        case .m1: return cal.date(byAdding: .day, value: -7, to: now)!
        case .m5, .m15: return cal.date(byAdding: .day, value: -29, to: now)!
        case .m30, .h1: return cal.date(byAdding: .day, value: -88, to: now)!
        case .d1: return cal.date(byAdding: .year, value: -5, to: now)!
        case .w1, .mo1: return cal.date(from: DateComponents(year: 2000, month: 1, day: 1))!
        }
    }

    nonisolated(unsafe) static let dayFormatter: DateFormatter = { // read-only after init
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Encodes `|` and spaces (index keys like `NSE_INDEX|Nifty 50`) for use in a URL path.
    static func encodedKey(_ key: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/|")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
    }

    func candles(for instrument: Instrument, timeframe: Timeframe, now: Date) async throws -> [Candle] {
        let (unit, interval) = Self.unit(timeframe)
        let key = Self.encodedKey(instrument.providerKey)
        let to = Self.dayFormatter.string(from: now)
        let from = Self.dayFormatter.string(from: Self.fromDate(timeframe, now: now))
        let historical = "\(Self.base)/\(key)/\(unit)/\(interval)/\(to)/\(from)"

        async let past = fetch(historical)
        // Today's bars come from the intraday endpoint (minutes/hours/days only).
        let today: [Candle]
        if ["minutes", "hours", "days"].contains(unit) {
            today = (try? await fetch("\(Self.base)/intraday/\(key)/\(unit)/\(interval)")) ?? []
        } else {
            today = []
        }
        return (try await past + today).normalized()
    }

    /// LTP: `{"status":"success","data":{"NSE_EQ:RELIANCE":{"last_price":..,"instrument_token":"NSE_EQ|INE…"}}}`
    /// (shape not yet verified against a live account — falls back to the last 1-minute candle).
    func lastPrice(_ instrument: Instrument) async throws -> Double {
        var c = URLComponents(string: "https://api.upstox.com/v3/market-quote/ltp")!
        c.queryItems = [URLQueryItem(name: "instrument_key", value: instrument.providerKey)]
        var request = URLRequest(url: c.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await MarketHTTP.data(for: request)
        if status == 401 { throw MarketDataError.loginRequired }
        if status == 200, let p = Self.parseLTP(data, key: instrument.providerKey) { return p }
        let candles = try await fetch("\(Self.base)/intraday/\(Self.encodedKey(instrument.providerKey))/minutes/1")
        guard let last = candles.last else { throw MarketDataError.unsupported("No price yet today.") }
        return last.close
    }

    static func parseLTP(_ data: Data, key: String) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else { return nil }
        let entries = payload.values.compactMap { $0 as? [String: Any] }
        let match = entries.first { ($0["instrument_token"] as? String) == key } ?? (entries.count == 1 ? entries.first : nil)
        return (match?["last_price"] as? NSNumber)?.doubleValue
    }

    private func fetch(_ urlString: String) async throws -> [Candle] {
        guard let url = URL(string: urlString) else { throw MarketDataError.unsupported("Bad instrument key") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await MarketHTTP.data(for: request)
        switch status {
        case 200: return try Self.parseCandles(data)
        case 401: throw MarketDataError.loginRequired
        case 429: throw MarketDataError.rateLimited
        default: throw MarketDataError.http(status, ProviderHTTP.errorMessage(from: data))
        }
    }

    /// `{"status":"success","data":{"candles":[["2025-01-12T15:15:00+05:30",o,h,l,c,vol,oi], ...]}}`
    /// Newest first in the API; returned ascending.
    static func parseCandles(_ data: Data) throws -> [Candle] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let rows = payload["candles"] as? [[Any]] else {
            throw MarketDataError.decoding("Upstox candles")
        }
        return rows.compactMap { row in
            guard row.count >= 6 else { return nil }
            let time: Date?
            if let s = row[0] as? String { time = ISODate.parse(s) }
            else if let n = row[0] as? NSNumber { time = Date(timeIntervalSince1970: n.doubleValue / 1000) }
            else { time = nil }
            guard let time,
                  let o = (row[1] as? NSNumber)?.doubleValue, let h = (row[2] as? NSNumber)?.doubleValue,
                  let l = (row[3] as? NSNumber)?.doubleValue, let c = (row[4] as? NSNumber)?.doubleValue
            else { return nil }
            let v = (row[5] as? NSNumber)?.doubleValue ?? 0
            return Candle(time: time, open: o, high: h, low: l, close: c, volume: v)
        }.normalized()
    }
}
