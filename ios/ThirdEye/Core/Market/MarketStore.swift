import Foundation
import Observation

/// Owns market-data credentials, the instrument universe, search, the watchlist and candle routing.
/// Phone-first: everything runs on the device (no backend until Milestone 6).
@Observable
final class MarketStore {
    enum Account: String {
        case upstoxKey = "market.upstox.apiKey"
        case upstoxSecret = "market.upstox.apiSecret"
        case upstoxToken = "market.upstox.accessToken"   // device-only, expires daily
        case twelveDataKey = "market.twelvedata.apiKey"
    }

    enum UniverseState: Equatable {
        case idle
        case loading(String)
        case ready
        case failed(String)
    }

    private(set) var index = InstrumentIndex([])
    private(set) var universeState: UniverseState = .idle
    private(set) var counts: [DataProvider: Int] = [:]
    private(set) var lastRefreshed: [DataProvider: Date] = [:]
    private(set) var providerErrors: [DataProvider: String] = [:]
    private(set) var watchlist: [Instrument] = []
    private(set) var upstoxTokenExpiry: Date?
    private(set) var upstoxUser: String?
    private(set) var hasUpstoxKeys = false
    private(set) var hasTwelveDataKey = false

    private let syncedKeychain = KeychainStore()                       // syncs to iPad
    private let deviceKeychain = KeychainStore(synchronizable: false)  // this device only
    private let defaults: UserDefaults
    private var lists: [DataProvider: [Instrument]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadWatchlist()
        refreshCredentialStatus()
    }

    // MARK: Credentials

    func refreshCredentialStatus() {
        hasUpstoxKeys = syncedKeychain.contains(Account.upstoxKey.rawValue) && syncedKeychain.contains(Account.upstoxSecret.rawValue)
        hasTwelveDataKey = syncedKeychain.contains(Account.twelveDataKey.rawValue)
        if let stored = try? deviceKeychain.get(Account.upstoxToken.rawValue),
           let decoded = Self.decodeToken(stored) {
            upstoxTokenExpiry = UpstoxAuth.expiry(issuedAt: decoded.issued)
            upstoxUser = decoded.user
        } else {
            upstoxTokenExpiry = nil
            upstoxUser = nil
        }
    }

    var upstoxLoggedIn: Bool {
        guard let upstoxTokenExpiry else { return false }
        return upstoxTokenExpiry > Date()
    }

    func saveUpstoxKeys(apiKey: String, apiSecret: String) throws {
        try syncedKeychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Account.upstoxKey.rawValue)
        try syncedKeychain.set(apiSecret.trimmingCharacters(in: .whitespacesAndNewlines), for: Account.upstoxSecret.rawValue)
        refreshCredentialStatus()
    }

    func upstoxAPIKey() -> String? { try? syncedKeychain.get(Account.upstoxKey.rawValue) }

    func completeUpstoxLogin(code: String) async throws {
        guard let key = try syncedKeychain.get(Account.upstoxKey.rawValue),
              let secret = try syncedKeychain.get(Account.upstoxSecret.rawValue) else {
            throw MarketDataError.notConfigured("Upstox API key and secret")
        }
        let result = try await UpstoxAuth.exchange(code: code, apiKey: key, apiSecret: secret)
        try deviceKeychain.set(Self.encodeToken(result.token, issued: Date(), user: result.user),
                               for: Account.upstoxToken.rawValue)
        refreshCredentialStatus()
    }

    func logOutUpstox() {
        try? deviceKeychain.delete(Account.upstoxToken.rawValue)
        refreshCredentialStatus()
    }

    func removeUpstoxKeys() {
        try? syncedKeychain.delete(Account.upstoxKey.rawValue)
        try? syncedKeychain.delete(Account.upstoxSecret.rawValue)
        logOutUpstox()
    }

    func saveTwelveDataKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Verify with a cheap call before saving.
        _ = try await TwelveDataClient(apiKey: trimmed).candles(
            for: Instrument(id: "twelve:EUR/USD", provider: .twelveData, symbol: "EUR/USD", name: "", exchange: "FX",
                            segment: "FOREX", kind: .forex, currency: "USD"),
            timeframe: .d1, now: Date())
        try syncedKeychain.set(trimmed, for: Account.twelveDataKey.rawValue)
        refreshCredentialStatus()
    }

    func removeTwelveDataKey() {
        try? syncedKeychain.delete(Account.twelveDataKey.rawValue)
        refreshCredentialStatus()
    }

    /// For the Windows monitor (sent over Tailscale only after pairing): the Twelve Data key and today's
    /// Upstox token, if they exist.
    func monitorCredentials() -> (twelveDataKey: String?, upstoxToken: String?, upstoxIssued: Date?) {
        let key = try? syncedKeychain.get(Account.twelveDataKey.rawValue)
        var token: String?, issued: Date?
        if let stored = try? deviceKeychain.get(Account.upstoxToken.rawValue), let decoded = Self.decodeToken(stored),
           UpstoxAuth.expiry(issuedAt: decoded.issued) > Date() {
            token = decoded.token
            issued = decoded.issued
        }
        return (key ?? nil, token, issued)
    }

    nonisolated static func encodeToken(_ token: String, issued: Date, user: String?) -> String {
        "\(Int(issued.timeIntervalSince1970))|\(user ?? "")|\(token)"
    }

    nonisolated static func decodeToken(_ stored: String) -> (token: String, issued: Date, user: String?)? {
        let parts = stored.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let epoch = Double(parts[0]), !parts[2].isEmpty else { return nil }
        return (String(parts[2]), Date(timeIntervalSince1970: epoch), parts[1].isEmpty ? nil : String(parts[1]))
    }

    private func validUpstoxToken() throws -> String {
        guard let stored = try deviceKeychain.get(Account.upstoxToken.rawValue),
              let decoded = Self.decodeToken(stored),
              UpstoxAuth.expiry(issuedAt: decoded.issued) > Date() else {
            throw MarketDataError.loginRequired
        }
        return decoded.token
    }

    // MARK: Candles

    func candles(for instrument: Instrument, timeframe: Timeframe) async throws -> [Candle] {
        let source: any CandleSource
        switch instrument.provider {
        case .upstox:
            guard hasUpstoxKeys else { throw MarketDataError.notConfigured("Upstox") }
            source = UpstoxCandleClient(accessToken: try validUpstoxToken())
        case .twelveData:
            guard let key = try syncedKeychain.get(Account.twelveDataKey.rawValue) else {
                throw MarketDataError.notConfigured("Twelve Data")
            }
            source = TwelveDataClient(apiKey: key)
        case .binance:
            source = BinanceClient()
        }
        do {
            return try await source.candles(for: instrument, timeframe: timeframe, now: Date())
        } catch MarketDataError.loginRequired {
            logOutUpstox()
            throw MarketDataError.loginRequired
        }
    }

    /// Latest traded price (cheap single-quote endpoints).
    func lastPrice(_ instrument: Instrument) async throws -> Double {
        switch instrument.provider {
        case .binance:
            return try await BinanceClient().lastPrice(instrument)
        case .twelveData:
            guard let key = try syncedKeychain.get(Account.twelveDataKey.rawValue) else {
                throw MarketDataError.notConfigured("Twelve Data")
            }
            return try await TwelveDataClient(apiKey: key).lastPrice(instrument)
        case .upstox:
            guard hasUpstoxKeys else { throw MarketDataError.notConfigured("Upstox") }
            return try await UpstoxCandleClient(accessToken: try validUpstoxToken()).lastPrice(instrument)
        }
    }

    // MARK: Instrument universe

    /// Loads cached lists instantly, then refreshes stale ones in the background.
    func loadUniverse(force: Bool = false) async {
        if lists.isEmpty {
            universeState = .loading("Loading saved instruments…")
            for provider in DataProvider.allCases {
                if let cached = await Self.readCache(provider) {
                    lists[provider] = cached.instruments
                    lastRefreshed[provider] = cached.savedAt
                }
            }
            rebuildIndex()
        }

        for provider in DataProvider.allCases where force || isStale(provider) {
            guard canFetchList(provider) else { continue }
            universeState = .loading("Updating \(provider.displayName) instruments…")
            do {
                let fresh = try await fetchList(provider)
                lists[provider] = fresh
                lastRefreshed[provider] = Date()
                providerErrors[provider] = nil
                await Self.writeCache(provider, fresh)
                rebuildIndex()
            } catch {
                providerErrors[provider] = error.localizedDescription
            }
        }
        universeState = index.count > 0 ? .ready : .failed(providerErrors.values.first ?? "No instruments yet.")
    }

    private func canFetchList(_ provider: DataProvider) -> Bool {
        switch provider {
        case .upstox, .binance: true            // public files, no key needed
        case .twelveData: hasTwelveDataKey
        }
    }

    private func fetchList(_ provider: DataProvider) async throws -> [Instrument] {
        switch provider {
        case .upstox:
            var all: [Instrument] = []
            for url in UpstoxInstruments.files {
                let (data, status) = try await MarketHTTP.data(for: URLRequest(url: url))
                guard status == 200 else { throw MarketDataError.http(status, "Upstox instrument file") }
                all += try await Task.detached(priority: .utility) { try UpstoxInstruments.parse(data) }.value
            }
            return all
        case .binance:
            return try await BinanceClient().instruments()
        case .twelveData:
            guard let key = try syncedKeychain.get(Account.twelveDataKey.rawValue) else { return [] }
            return try await TwelveDataClient(apiKey: key).instruments()
        }
    }

    /// Upstox publishes fresh files each morning; global lists change rarely.
    private func isStale(_ provider: DataProvider) -> Bool {
        guard let last = lastRefreshed[provider] else { return true }
        let maxAge: TimeInterval = provider == .upstox ? 20 * 3600 : 7 * 86_400
        return Date().timeIntervalSince(last) > maxAge
    }

    private func rebuildIndex() {
        let all = DataProvider.allCases.flatMap { lists[$0] ?? [] }
        index = InstrumentIndex(all)
        counts = lists.mapValues(\.count)
    }

    // MARK: Cache (Application Support, LZFSE-compressed, excluded from backup)

    nonisolated struct CacheFile: Codable, Sendable {
        let savedAt: Date
        let instruments: [Instrument]
    }

    nonisolated static func cacheURL(_ provider: DataProvider) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "market", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appending(path: "instruments-\(provider.rawValue).bin")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    nonisolated static func readCache(_ provider: DataProvider) async -> CacheFile? {
        await Task.detached(priority: .utility) {
            guard let raw = try? Data(contentsOf: cacheURL(provider)),
                  let json = try? (raw as NSData).decompressed(using: .lzfse) as Data else { return nil }
            return try? JSONDecoder().decode(CacheFile.self, from: json)
        }.value
    }

    nonisolated static func writeCache(_ provider: DataProvider, _ instruments: [Instrument]) async {
        await Task.detached(priority: .utility) {
            guard let json = try? JSONEncoder().encode(CacheFile(savedAt: Date(), instruments: instruments)),
                  let packed = try? (json as NSData).compressed(using: .lzfse) as Data else { return }
            try? packed.write(to: cacheURL(provider), options: [.atomic, .completeFileProtection])
        }.value
    }

    // MARK: Watchlist (local for now; iCloud sync arrives with SwiftData in a later milestone)

    private static let watchlistKey = "market.watchlist"

    func isWatched(_ instrument: Instrument) -> Bool {
        watchlist.contains { $0.id == instrument.id }
    }

    func toggleWatch(_ instrument: Instrument) {
        if let i = watchlist.firstIndex(where: { $0.id == instrument.id }) {
            watchlist.remove(at: i)
        } else {
            watchlist.append(instrument)
        }
        if let data = try? JSONEncoder().encode(watchlist) { defaults.set(data, forKey: Self.watchlistKey) }
    }

    private func loadWatchlist() {
        if let data = defaults.data(forKey: Self.watchlistKey),
           let list = try? JSONDecoder().decode([Instrument].self, from: data) {
            watchlist = list
        } else {
            // Starter watchlist that works with no keys (crypto) or once Upstox/Twelve Data are connected.
            watchlist = [
                Instrument(id: "NSE_INDEX|Nifty 50", provider: .upstox, symbol: "NIFTY", name: "Nifty 50",
                           exchange: "NSE", segment: "NSE_INDEX", kind: .index, currency: "INR"),
                Instrument(id: "NSE_EQ|INE002A01018", provider: .upstox, symbol: "RELIANCE", name: "Reliance Industries",
                           exchange: "NSE", segment: "NSE_EQ", kind: .equity, currency: "INR"),
                Instrument(id: "twelve:XAU/USD", provider: .twelveData, symbol: "XAU/USD", name: "Gold / US Dollar",
                           exchange: "FX", segment: "FOREX", kind: .commodity, currency: "USD"),
                Instrument(id: "twelve:USD/INR", provider: .twelveData, symbol: "USD/INR", name: "US Dollar / Indian Rupee",
                           exchange: "FX", segment: "FOREX", kind: .forex, currency: "INR"),
                Instrument(id: "binance:BTCUSDT", provider: .binance, symbol: "BTC/USDT", name: "BTC",
                           exchange: "Binance", segment: "CRYPTO", kind: .crypto, currency: "USDT"),
            ]
        }
    }
}
