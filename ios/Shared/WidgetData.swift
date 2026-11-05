import Foundation
import Security

/// One open or upcoming trade as the Home Screen widget needs it. Written by the app, read by the widget.
nonisolated struct WidgetTrade: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String            // "TRENT (NSE)", "BTC/USDT"
    var side: String            // long / short
    var status: String          // open / upcoming
    var entry: Double           // average entry, or the middle of the entry zone
    var entryLow: Double
    var entryHigh: Double
    var stop: Double
    var initialStop: Double
    var nextTarget: Double?
    var nextTargetStage: Int?
    var openUnits: Double       // open quantity × contract size (lots → units)
    var realized: Double        // money already booked, after fees
    var currency: String
    var decimals: Int
    var paper: Bool
    var lastPrice: Double?
    var lastPriceAt: Double?    // Unix seconds
    var badge: String? = nil    // Swing, Intraday, …
    var completeBy: Double? = nil

    var isLong: Bool { side != "short" }
    private var dir: Double { isLong ? 1 : -1 }

    func pnl(at p: Double) -> Double? { status == "open" ? realized + dir * (p - entry) * openUnits : nil }

    func r(at p: Double) -> Double? {
        let risk = abs(entry - initialStop)
        return status == "open" && risk > 0 ? dir * (p - entry) / risk : nil
    }

    /// 0 = at the stop … 1 = at the next target (the same bar as the Lock Screen card).
    func progress(at p: Double) -> Double {
        guard let t = nextTarget else { return 1 }
        let span = dir * (t - stop)
        return span > 0 ? min(max(dir * (p - stop) / span, 0), 1) : 0
    }

    func status(at p: Double) -> String {
        if status == "upcoming" { return p >= entryLow && p <= entryHigh ? "In entry zone" : "Waiting" }
        if isLong ? p <= stop : p >= stop { return "STOP HIT" }
        if let t = nextTarget, isLong ? p >= t : p <= t { return "TP\(nextTargetStage ?? 0) hit" }
        let risk = abs(entry - initialStop)
        if risk > 0, dir * (p - stop) / risk <= 0.25 { return "Near stop" }
        return "Open"
    }

    var symbol: String {
        switch currency {
        case "INR": "₹"
        case "USD", "USDT", "USDC": "$"
        case "EUR": "€"
        case "GBP": "£"
        default: ""
        }
    }

    func price(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(decimals)).grouping(.automatic)
            .locale(Locale(identifier: currency == "INR" ? "en_IN" : "en_US")))
    }

    func money(_ v: Double) -> String {
        (v >= 0 ? "+" : "−") + symbol + abs(v).formatted(.number.precision(.fractionLength(abs(v) >= 1000 ? 0 : 2)).grouping(.automatic)
            .locale(Locale(identifier: currency == "INR" ? "en_IN" : "en_US")))
    }
}

nonisolated struct WidgetSnapshot: Codable, Sendable {
    var trades: [WidgetTrade]
    var monitorAddress: String?
    var hideMoney: Bool
    var updatedAt: Double
}

/// A small keychain item shared by the app and its widget extension (keychain access group
/// `<team>.com.jondhale.thirdeye.shared`) — no App Group needed. Readable after the first unlock so the
/// widget can refresh while the phone is locked; never synced to iCloud.
nonisolated enum SharedStore {
    static let service = "com.jondhale.thirdeye.shared"
    static let snapshotAccount = "widget.snapshot"
    static let tokenAccount = "widget.monitorToken"

    static var accessGroup: String? {
        let prefix = (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String) ?? ""
        guard !prefix.isEmpty, !prefix.hasPrefix("$(") else { return nil }
        return prefix + "com.jondhale.thirdeye.shared"
    }

    private static func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    static func write(_ data: Data, account: String) {
        let q = query(account)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(q as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = q
            add.merge(update) { _, b in b }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    static func saveSnapshot(_ s: WidgetSnapshot) {
        if let data = try? JSONEncoder().encode(s) { write(data, account: snapshotAccount) }
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        read(snapshotAccount).flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
    }

    /// Same rule as the app: a Tailscale IP → http on 8788, a name → https.
    static func monitorURL(_ address: String, _ path: String) -> URL? {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        let isIP = parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
        return URL(string: isIP ? "http://\(address):8788\(path)" : "https://\(address)\(path)")
    }

    /// Latest prices from the PC monitor, by trade ID (nil when it can't be reached).
    static func fetchPrices(timeout: TimeInterval = 8) async -> [String: (price: Double, at: Double)]? {
        guard let snap = loadSnapshot(), let address = snap.monitorAddress, !address.isEmpty,
              let tokenData = read(tokenAccount), let token = String(data: tokenData, encoding: .utf8),
              let url = monitorURL(address, "/v1/status") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["trades"] as? [[String: Any]] else { return nil }
        var out: [String: (price: Double, at: Double)] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        for r in rows {
            guard let id = r["id"] as? String, let p = (r["lastPrice"] as? NSNumber)?.doubleValue, p > 0 else { continue }
            let s = r["lastCheck"] as? String ?? ""
            let at = (iso.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            out[id.uppercased()] = (p, at)
        }
        return out
    }
}
