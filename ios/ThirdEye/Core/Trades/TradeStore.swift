import Foundation
import Observation

/// Trades are saved on this device and mirrored to iCloud key-value storage so the iPad sees them.
/// One key per trade (`trade.<uuid>`); on conflict the most recent `updatedAt` wins.
/// If iCloud is unavailable everything still works locally.
@Observable
final class TradeStore {
    private(set) var trades: [Trade] = []
    private(set) var lastSync: Date?

    private let kvs = NSUbiquitousKeyValueStore.default
    private static let prefix = "trade."
    private static let tombstonePrefix = "deleted."
    private var observer: NSObjectProtocol?

    private static var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "trades", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "trades.json")
    }

    init() {
        loadLocal()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mergeFromCloud() }
        }
        kvs.synchronize()
        mergeFromCloud()
    }

    // MARK: Queries

    func trades(_ status: TradeStatus) -> [Trade] {
        trades.filter { $0.status == status }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func trade(id: UUID) -> Trade? { trades.first { $0.id == id } }

    // MARK: Changes

    func save(_ trade: Trade) {
        var t = trade
        t.updatedAt = Date()
        if let i = trades.firstIndex(where: { $0.id == t.id }) { trades[i] = t } else { trades.insert(t, at: 0) }
        persist()
        push(t)
    }

    func delete(_ trade: Trade) {
        trades.removeAll { $0.id == trade.id }
        persist()
        kvs.removeObject(forKey: Self.prefix + trade.id.uuidString)
        kvs.set(Date().timeIntervalSince1970, forKey: Self.tombstonePrefix + trade.id.uuidString)
        kvs.synchronize()
    }

    /// Records an entry (first or additional) and marks the trade open.
    func recordEntry(_ trade: Trade, price: Double, quantity: Double, fees: Double, date: Date) {
        var t = trade
        t.fills.append(Fill(kind: .entry, date: date, price: price, quantity: quantity, fees: fees))
        t.status = .open
        save(t)
    }

    /// Records an exit; closes the trade when nothing is left open.
    func recordExit(_ trade: Trade, price: Double, quantity: Double, fees: Double, date: Date, takeProfitStage: Int?, note: String?) {
        var t = trade
        t.fills.append(Fill(kind: .exit, date: date, price: price, quantity: quantity, fees: fees,
                            takeProfitStage: takeProfitStage, note: note))
        // Spec risk rule: after TP1, move the stop to breakeven (only ever tighten it).
        if takeProfitStage == 1, let avg = TradeMath.summary(t, lastPrice: nil).averageEntry {
            t.stopLoss = t.isLong ? max(t.stopLoss, avg) : min(t.stopLoss, avg)
        }
        if TradeMath.summary(t, lastPrice: nil).openQuantity <= 1e-12 {
            t.status = .closed
            t.closedAt = date
        }
        save(t)
    }

    /// Adds fills matched from the broker. Recording TP1 still moves the stop to breakeven.
    func applyBrokerMatches(_ matches: [UpstoxReconciler.Match]) -> Int {
        var added = 0
        for m in matches {
            guard var t = trade(id: m.tradeID), !t.fills.contains(where: { $0.brokerID == m.fill.id }) else { continue }
            t.fills.append(Fill(kind: m.isEntry ? .entry : .exit, date: m.fill.date, price: m.fill.price, quantity: m.fill.quantity,
                                takeProfitStage: m.takeProfitStage, note: m.isEntry ? nil : "From Upstox", brokerID: m.fill.id))
            if !m.isEntry, m.takeProfitStage == 1, let avg = TradeMath.summary(t, lastPrice: nil).averageEntry {
                t.stopLoss = t.isLong ? max(t.stopLoss, avg) : min(t.stopLoss, avg)
            }
            Self.settleStatus(&t)
            save(t)
            added += 1
        }
        return added
    }

    /// Corrects a recorded fill (price, quantity, fees, date, which target).
    func replaceFill(_ trade: Trade, with fill: Fill) {
        var t = trade
        guard let i = t.fills.firstIndex(where: { $0.id == fill.id }) else { return }
        t.fills[i] = fill
        Self.settleStatus(&t)
        save(t)
    }

    func deleteFill(_ trade: Trade, id: UUID) {
        var t = trade
        t.fills.removeAll { $0.id == id }
        Self.settleStatus(&t)
        save(t)
    }

    /// After an edit: no entries → upcoming, nothing left open → closed, otherwise open.
    nonisolated static func settleStatus(_ t: inout Trade) {
        guard t.status != .cancelled else { return }
        let s = TradeMath.summary(t, lastPrice: nil)
        if s.entryQuantity <= 1e-12 {
            t.status = .upcoming
            t.closedAt = nil
        } else if s.openQuantity <= 1e-12 {
            t.status = .closed
            t.closedAt = t.fills.filter { $0.kind == .exit }.map(\.date).max() ?? Date()
        } else {
            t.status = .open
            t.closedAt = nil
        }
    }

    func cancel(_ trade: Trade) {
        var t = trade
        t.status = .cancelled
        t.closedAt = Date()
        save(t)
    }

    // MARK: Sync

    private func push(_ t: Trade) {
        guard let data = try? Self.encoder.encode(t) else { return }
        kvs.set(data, forKey: Self.prefix + t.id.uuidString)
        kvs.synchronize()
    }

    private func mergeFromCloud() {
        let all = kvs.dictionaryRepresentation
        var changed = false
        let deleted = Set(all.keys.filter { $0.hasPrefix(Self.tombstonePrefix) }.map { String($0.dropFirst(Self.tombstonePrefix.count)) })
        if !deleted.isEmpty {
            let before = trades.count
            trades.removeAll { deleted.contains($0.id.uuidString) }
            changed = changed || trades.count != before
        }
        for (key, value) in all where key.hasPrefix(Self.prefix) {
            guard let data = value as? Data, let remote = try? Self.decoder.decode(Trade.self, from: data),
                  !deleted.contains(remote.id.uuidString) else { continue }
            if let i = trades.firstIndex(where: { $0.id == remote.id }) {
                if remote.updatedAt > trades[i].updatedAt { trades[i] = remote; changed = true }
                else if remote.updatedAt < trades[i].updatedAt { push(trades[i]) }
            } else {
                trades.append(remote)
                changed = true
            }
        }
        // Upload local trades the cloud has not seen (e.g. created before iCloud was enabled).
        let cloudIDs = Set(all.keys.filter { $0.hasPrefix(Self.prefix) }.map { String($0.dropFirst(Self.prefix.count)) })
        for t in trades where !cloudIDs.contains(t.id.uuidString) { push(t) }
        if changed { persist() }
        lastSync = Date()
    }

    // MARK: Local file

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private func persist() {
        guard let data = try? Self.encoder.encode(trades) else { return }
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
    }

    private func loadLocal() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? Self.decoder.decode([Trade].self, from: data) else { return }
        trades = list
    }
}

/// Latest prices for the Trades screen. Cheap single-price endpoints, cached for 30 s.
@Observable
final class PriceBook {
    private(set) var prices: [String: (price: Double, at: Date)] = [:]

    func price(_ instrument: Instrument) -> Double? { prices[instrument.id]?.price }

    func refresh(_ instruments: [Instrument], market: MarketStore) async {
        for instrument in instruments {
            if let cached = prices[instrument.id], Date().timeIntervalSince(cached.at) < 30 { continue }
            if let p = try? await market.lastPrice(instrument) {
                prices[instrument.id] = (p, Date())
            }
        }
    }
}
