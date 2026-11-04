import Foundation
import Observation
import UIKit
import UserNotifications

/// What the Windows monitor watches for one trade (mirrors monitor/model.go).
nonisolated struct MonitorWatchTrade: Codable, Hashable, Sendable {
    nonisolated struct Target: Codable, Hashable, Sendable {
        var stage: Int
        var price: Double?
        var r: Double?
        var bookPercent: Double
        var then: String
        var booked: Bool
    }
    var id: String
    var symbol: String
    var provider: String
    var providerKey: String
    var exchange: String
    var segment: String
    var kind: String
    var currency: String
    var side: String
    var status: String
    var mode: String
    var entryLow: Double
    var entryHigh: Double
    var stop: Double
    var initialStop: Double
    var avgEntry: Double?
    var openQuantity: Double
    var targets: [Target]
    var completeBy: Date
    var cadenceSeconds: Int
    var updatedAt: Date

    /// How often the PC checks the price while the market is open.
    static func cadence(_ badge: HoldingBadge) -> Int {
        switch badge {
        case .scalp, .intraday: 30
        case .shortTerm, .swing: 300
        case .positional: 1800
        case .longTerm: 3600
        }
    }

    /// Only trades the PC should watch: upcoming (waiting for entry) and open.
    static func from(_ t: Trade) -> MonitorWatchTrade? {
        guard t.status == .upcoming || t.status == .open else { return nil }
        let summary = TradeMath.summary(t, lastPrice: nil)
        let booked = Set(t.fills.compactMap(\.takeProfitStage))
        return MonitorWatchTrade(
            id: t.id.uuidString, symbol: t.instrument.symbol, provider: t.instrument.provider.rawValue,
            providerKey: t.instrument.providerKey, exchange: t.instrument.exchange, segment: t.instrument.segment,
            kind: t.instrument.kind.rawValue, currency: t.instrument.currency, side: t.side, status: t.status.rawValue,
            mode: t.mode.rawValue, entryLow: t.plannedEntryLow, entryHigh: t.plannedEntryHigh, stop: t.stopLoss,
            initialStop: t.initialStop, avgEntry: summary.averageEntry, openQuantity: summary.openQuantity,
            targets: t.takeProfits.map {
                Target(stage: $0.stage, price: $0.price, r: $0.rMultiple, bookPercent: $0.bookPercent, then: $0.then,
                       booked: booked.contains($0.stage))
            },
            completeBy: t.completeBy, cadenceSeconds: cadence(t.badge), updatedAt: t.updatedAt)
    }
}

nonisolated struct MonitorPairRequest: Encodable, Sendable { var code: String; var device: String }

nonisolated struct MonitorDeviceRequest: Encodable, Sendable {
    var installID: String
    var token: String
    var environment: String
    var name: String
    var teamID: String
    var bundleID: String
}

nonisolated struct MonitorWatchPayload: Encodable, Sendable {
    nonisolated struct Settings: Encodable, Sendable {
        var suddenMoveR: Double
        var summaryTimes: [String]
        var timeZone: String
    }
    var trades: [MonitorWatchTrade]
    var settings: Settings
}

nonisolated struct MonitorCredentialsPayload: Encodable, Sendable {
    var twelveDataKey: String
    var upstoxToken: String
    var upstoxIssuedAt: Date?
}

/// Go writes times as RFC 3339 with up to 9 fractional digits; ISO8601DateFormatter takes at most 3.
nonisolated func parseMonitorDate(_ s: String) -> Date? {
    var str = s
    if let dot = str.firstIndex(of: "."),
       let zone = str[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
        let digits = str[str.index(after: dot)..<zone]
        let ms = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        str = String(str[..<dot]) + "." + ms + String(str[zone...])
    }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: str) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: str)
}

nonisolated struct MonitorAlert: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var tradeID: String?
    var symbol: String?
    var kind: String
    var title: String
    var body: String
    var urgent: Bool
    var at: Date
    var delivered: String?
}

nonisolated struct MonitorStatus: Codable, Sendable {
    nonisolated struct TradeRow: Codable, Sendable, Identifiable {
        var id: String
        var symbol: String
        var lastPrice: Double?
        var lastCheck: Date?
        var marketOpen: Bool
    }
    var version: String
    var startedAt: Date
    var now: Date
    var lastLoopAt: Date
    var watching: Int
    var apns: String
    var devices: Int
    var providers: [String: String]
    var trades: [TradeRow]?
    var alerts: [MonitorAlert]?
}

/// Talks to the Third Eye monitor on the user's Windows PC (over Tailscale, HTTPS) and handles push setup.
@Observable
final class MonitorStore {
    static let shared = MonitorStore()

    private(set) var address: String
    private(set) var isPaired: Bool
    private(set) var status: MonitorStatus?
    private(set) var statusError: String?
    private(set) var lastStatusAt: Date?
    private(set) var lastSyncAt: Date?
    private(set) var syncError: String?
    private(set) var notificationsAllowed: Bool?
    var deviceToken: String? {
        didSet { if deviceToken != oldValue { Task { await registerDevice() } } }
    }
    /// Set when a notification is tapped; the main view opens that trade.
    var openTradeID: UUID?
    /// Why iOS refused a push token (normally: the build lacks the Push Notifications capability).
    var pushRegistrationError: String?

    private let keychain = KeychainStore(synchronizable: false)   // this device only
    private static let tokenAccount = "monitor.token"
    private static let addressKey = "monitor.address"
    private var syncTask: Task<Void, Never>?
    private var lastSentCredentials: String?

    private init() {
        address = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        isPaired = keychain.contains(Self.tokenAccount)
    }

    /// Online = it checked prices within the last 15 minutes.
    var isOnline: Bool {
        guard let s = status, statusError == nil else { return false }
        return s.now.timeIntervalSince(s.lastLoopAt) < 15 * 60
    }

    nonisolated static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        while s.hasSuffix("/") || s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: HTTP

    nonisolated enum MonitorError: LocalizedError {
        case unreachable(String), refused(String), notPaired
        var errorDescription: String? {
            switch self {
            case .unreachable(let m): "Can't reach your PC (\(m)). Check that Tailscale is on, on both the iPhone and the PC, and that the PC is awake."
            case .refused(let m): m
            case .notPaired: "Not connected to a PC yet."
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            return parseMonitorDate(s) ?? .distantPast
        }
        return d
    }()

    private func request(_ method: String, _ path: String, body: (any Encodable)? = nil, auth: Bool = true,
                         host: String? = nil) async throws -> Data {
        let target = host ?? address
        guard !target.isEmpty, let url = URL(string: "https://\(target)\(path)") else { throw MonitorError.notPaired }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth {
            guard let token = try? keychain.get(Self.tokenAccount) else { throw MonitorError.notPaired }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try Self.encoder.encode(body) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw MonitorError.unreachable((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if code == 401, auth { forgetPairing() }
            throw MonitorError.refused(message ?? "Your PC answered \(code).")
        }
        return data
    }

    // MARK: Pairing

    func pair(address raw: String, code: String) async throws {
        let host = Self.normalize(raw)
        let body = MonitorPairRequest(code: code.trimmingCharacters(in: .whitespaces), device: UIDevice.current.name)
        let data = try await request("POST", "/v1/pair", body: body, auth: false, host: host)
        guard let token = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String else {
            throw MonitorError.refused("Unexpected answer from the PC.")
        }
        try keychain.set(token, for: Self.tokenAccount)
        address = host
        UserDefaults.standard.set(host, forKey: Self.addressKey)
        isPaired = true
        lastSentCredentials = nil
    }

    func unpair() async {
        _ = try? await request("DELETE", "/v1/pair")
        forgetPairing()
    }

    private func forgetPairing() {
        try? keychain.delete(Self.tokenAccount)
        isPaired = false
        status = nil
    }

    // MARK: Push notifications

    func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notificationsAllowed = granted
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func refreshNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if notificationsAllowed == true { UIApplication.shared.registerForRemoteNotifications() }
    }

    func registerDevice() async {
        guard isPaired, let deviceToken else { return }
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        let prefix = (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String) ?? ""
        let device = MonitorDeviceRequest(installID: UIDevice.current.identifierForVendor?.uuidString ?? deviceToken,
                            token: deviceToken, environment: environment, name: UIDevice.current.name,
                            teamID: prefix.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                            bundleID: Bundle.main.bundleIdentifier ?? "com.jondhale.thirdeye")
        do { _ = try await request("PUT", "/v1/device", body: device); syncError = nil }
        catch { syncError = error.localizedDescription }
    }

    // MARK: Sync

    /// Debounced: many quick edits send one update.
    func scheduleSync(_ trades: [Trade]) {
        guard isPaired else { return }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await syncTrades(trades)
        }
    }

    func syncTrades(_ trades: [Trade]) async {
        guard isPaired else { return }
        let payload = MonitorWatchPayload(trades: trades.compactMap(MonitorWatchTrade.from),
                                          settings: .init(suddenMoveR: 1, summaryTimes: ["09:00", "21:00"],
                                                          timeZone: TimeZone.current.identifier))
        do {
            _ = try await request("PUT", "/v1/watch", body: payload)
            lastSyncAt = Date()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Sends the Twelve Data key and today's Upstox token when they change, so the PC can fetch those prices.
    func syncCredentials(market: MarketStore) async {
        guard isPaired else { return }
        let creds = market.monitorCredentials()
        let fingerprint = "\(creds.twelveDataKey ?? "")|\(creds.upstoxToken ?? "")"
        guard fingerprint != lastSentCredentials else { return }
        do {
            _ = try await request("PUT", "/v1/credentials",
                                  body: MonitorCredentialsPayload(twelveDataKey: creds.twelveDataKey ?? "",
                                                                  upstoxToken: creds.upstoxToken ?? "",
                                                                  upstoxIssuedAt: creds.upstoxIssued))
            lastSentCredentials = fingerprint
        } catch {
            syncError = error.localizedDescription
        }
    }

    func refreshStatus() async {
        guard isPaired else { return }
        do {
            let data = try await request("GET", "/v1/status")
            status = try Self.decoder.decode(MonitorStatus.self, from: data)
            statusError = nil
        } catch {
            statusError = error.localizedDescription
        }
        lastStatusAt = Date()
    }

    func sendTestAlert() async throws -> String {
        let data = try await request("POST", "/v1/test-alert")
        return ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["delivered"] as? String) ?? "sent"
    }

    /// Everything at once — on launch, on returning to the app, after pairing.
    func refreshAll(trades: [Trade], market: MarketStore) async {
        guard isPaired else { return }
        await refreshNotificationPermission()
        await registerDevice()
        await syncCredentials(market: market)
        await syncTrades(trades)
        await refreshStatus()
    }
}
