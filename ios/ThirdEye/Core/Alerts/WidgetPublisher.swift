import Foundation
import WidgetKit

/// Writes the trades the Home Screen widget shows into the shared keychain item and asks iOS to redraw it.
/// Prices: the PC monitor's latest (from its status), else the last known one.
enum WidgetPublisher {
    private static var lastData: Data?
    private static var lastReload = Date.distantPast

    static func publish(trades: [Trade], monitor: MonitorStore, extraPrices: [String: Double] = [:], force: Bool = false) {
        monitor.shareTokenWithWidget()
        let old = SharedStore.loadSnapshot()
        let oldPrices = Dictionary((old?.trades ?? []).map { ($0.id, ($0.lastPrice, $0.lastPriceAt)) }, uniquingKeysWith: { a, _ in a })
        let live = Dictionary((monitor.status?.trades ?? []).compactMap { row -> (String, (Double, Double))? in
            guard let p = row.lastPrice, p > 0 else { return nil }
            return (row.id.uppercased(), (p, (row.lastCheck ?? Date()).timeIntervalSince1970))
        }, uniquingKeysWith: { a, _ in a })

        let rows: [WidgetTrade] = trades.filter { $0.status == .open || $0.status == .upcoming }.map { t in
            let id = t.id.uuidString
            let s = TradeMath.summary(t, lastPrice: nil)
            let booked = Set(t.fills.compactMap(\.takeProfitStage))
            let next = t.takeProfits.first { !booked.contains($0.stage) && $0.price != nil }
            let decimals: Int
            if let tick = t.instrument.tickSize, tick > 0 { decimals = min(max(Int(ceil(-log10(tick))), 0), 6) }
            else { decimals = FeatureEngine.decimals(t.plannedEntryMid) }
            var price: Double? = nil, at: Double? = nil
            if let p = extraPrices[t.instrument.id] { price = p; at = Date().timeIntervalSince1970 }
            else if let l = live[id.uppercased()] { price = l.0; at = l.1 }
            else if let o = oldPrices[id] { price = o.0; at = o.1 }
            return WidgetTrade(id: id, name: t.instrument.alertName, side: t.side, status: t.status.rawValue,
                               entry: s.averageEntry ?? t.plannedEntryMid, entryLow: t.plannedEntryLow, entryHigh: t.plannedEntryHigh,
                               stop: t.stopLoss, initialStop: t.initialStop, nextTarget: next?.price, nextTargetStage: next?.stage,
                               openUnits: s.openQuantity * t.instrument.contractSize, realized: s.realized,
                               currency: t.instrument.currency, decimals: decimals, paper: t.mode == .paper,
                               lastPrice: price, lastPriceAt: at)
        }
        let snapshot = WidgetSnapshot(trades: rows, monitorAddress: monitor.isPaired ? monitor.address : nil,
                                      hideMoney: UserDefaults.standard.bool(forKey: "settings.hideLockScreenPnL"),
                                      updatedAt: Date().timeIntervalSince1970)
        var compare = snapshot
        compare.updatedAt = 0
        let data = try? JSONEncoder().encode(compare)
        guard force || data != lastData else { return }
        lastData = data
        SharedStore.saveSnapshot(snapshot)
        if force || Date().timeIntervalSince(lastReload) > 30 {
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
