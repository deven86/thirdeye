import ActivityKit
import Foundation
import Observation

/// Starts, refreshes and ends the Lock Screen / Dynamic Island card for trades. The card is kept up to date by
/// the PC monitor (push) while the app is closed, and by the app itself while it is open.
/// iOS ends every Live Activity after about 8 hours (then it stays on the Lock Screen up to 4 more); opening
/// Third Eye starts a fresh one for trades that still want it.
@Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private(set) var lastError: String?
    /// Trades the user asked to show (kept so expired cards are restarted when the app opens).
    private(set) var wanted: Set<String>
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private static let wantedKey = "liveActivity.wanted"

    init() {
        wanted = Set(UserDefaults.standard.stringArray(forKey: Self.wantedKey) ?? [])
    }

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func isShowing(_ id: UUID) -> Bool {
        Activity<TradeActivityAttributes>.activities.contains { $0.attributes.tradeID == id.uuidString && $0.activityState == .active }
    }

    static func attributes(_ t: Trade) -> TradeActivityAttributes {
        let decimals: Int
        if let tick = t.instrument.tickSize, tick > 0 { decimals = min(max(Int(ceil(-log10(tick))), 0), 6) }
        else { decimals = FeatureEngine.decimals(t.plannedEntryMid) }
        let entry = TradeMath.summary(t, lastPrice: nil).averageEntry ?? t.plannedEntryMid
        return TradeActivityAttributes(tradeID: t.id.uuidString, symbol: t.instrument.alertName, side: t.side, entry: entry,
                                       currency: t.instrument.currency, decimals: decimals, paper: t.mode == .paper,
                                       hideMoney: UserDefaults.standard.bool(forKey: "settings.hideLockScreenPnL"),
                                       badge: t.badge.title, completeBy: t.completeBy.timeIntervalSince1970, initialStop: t.initialStop)
    }

    /// Same maths as the PC (monitor/live.go BuildLiveState), for the first frame and in-app refreshes.
    nonisolated static func state(_ t: Trade, price: Double, now: Date = Date()) -> TradeActivityAttributes.ContentState {
        let s = TradeMath.summary(t, lastPrice: price)
        let dir: Double = t.isLong ? 1 : -1
        let booked = Set(t.fills.compactMap(\.takeProfitStage))
        let next = t.takeProfits.first { !booked.contains($0.stage) && $0.price != nil }
        var st = TradeActivityAttributes.ContentState(price: price, r: nil, pnlPercent: nil, stop: t.stopLoss,
                                                      nextTarget: next?.price, nextTargetStage: next?.stage, progress: 0,
                                                      status: "open", note: nil, updatedAt: now.timeIntervalSince1970)
        st.stopPnl = t.pnl(ifPriceAt: t.stopLoss)
        st.targetPnl = next?.price.map { t.pnl(ifPriceAt: $0) }
        if t.status == .upcoming {
            if price >= t.plannedEntryLow && price <= t.plannedEntryHigh {
                st.status = "inZone"; st.note = "In the entry zone"
            } else {
                let edge = price < t.plannedEntryLow ? t.plannedEntryLow : t.plannedEntryHigh
                st.status = "waiting"; st.note = String(format: "%.1f%% from the entry zone", abs(price / edge - 1) * 100)
            }
            return st
        }
        let entry = s.averageEntry ?? t.plannedEntryMid
        let risk = abs(entry - t.initialStop)
        if risk > 0 { st.r = dir * (price - entry) / risk }
        if entry > 0 { st.pnlPercent = dir * (price / entry - 1) * 100 }
        st.pnl = s.total
        if let target = next?.price {
            let span = dir * (target - t.stopLoss)
            if span > 0 { st.progress = min(max(dir * (price - t.stopLoss) / span, 0), 1) }
        } else {
            st.progress = 1
        }
        if t.isLong ? price <= t.stopLoss : price >= t.stopLoss {
            st.status = "stop"; st.note = "Stop reached — exit what is left"
        } else if let n = next, let target = n.price, t.isLong ? price >= target : price <= target {
            st.status = "target"; st.note = "TP\(n.stage) reached — book \(Int(n.bookPercent))%"
        } else if risk > 0, dir * (price - t.stopLoss) / risk <= 0.25 {
            st.status = "nearStop"; st.note = "Close to the stop"
        }
        return st
    }

    /// Shows a trade on the Lock Screen and hands its push token to the PC.
    func start(_ t: Trade, price: Double?, monitor: MonitorStore) {
        guard t.status == .open || t.status == .upcoming else { return }
        wanted.insert(t.id.uuidString)
        persist()
        guard enabled else {
            lastError = "Live Activities are off for Third Eye: iPhone Settings → Third Eye → Live Activities."
            return
        }
        if let existing = activity(for: t.id), existing.activityState == .active {
            watchToken(existing, tradeID: t.id.uuidString, monitor: monitor)
            return
        }
        let state = Self.state(t, price: price ?? t.plannedEntryMid)
        do {
            let activity = try Activity.request(attributes: Self.attributes(t),
                                                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(1800)),
                                                pushType: .token)
            lastError = nil
            watchToken(activity, tradeID: t.id.uuidString, monitor: monitor)
        } catch {
            lastError = "Couldn't show it on the Lock Screen: \(error.localizedDescription)"
        }
    }

    func stop(_ id: UUID, monitor: MonitorStore) async {
        wanted.remove(id.uuidString)
        persist()
        tokenTasks[id.uuidString]?.cancel()
        tokenTasks[id.uuidString] = nil
        await Self.end(tradeID: id.uuidString, content: nil, policy: .immediate)
        await monitor.endLiveActivity(tradeID: id.uuidString)
    }

    /// While the app is open: refresh cards with fresh prices.
    func update(_ t: Trade, price: Double) async {
        guard activity(for: t.id)?.activityState == .active else { return }
        await Self.update(tradeID: t.id.uuidString,
                          content: ActivityContent(state: Self.state(t, price: price), staleDate: Date().addingTimeInterval(1800)))
    }

    /// On launch and after every trade change: end cards of closed trades, restart wanted ones iOS has ended,
    /// and re-send tokens to the PC.
    func reconcile(_ trades: [Trade], prices: PriceBook?, monitor: MonitorStore) async {
        let byID = Dictionary(uniqueKeysWithValues: trades.map { ($0.id.uuidString, $0) })
        for a in Activity<TradeActivityAttributes>.activities {
            let t = byID[a.attributes.tradeID]
            if t == nil || t!.status == .closed || t!.status == .cancelled {
                if let t {
                    let final = Self.state(t, price: TradeMath.summary(t, lastPrice: nil).averageExit ?? a.content.state.price)
                    await Self.end(tradeID: a.attributes.tradeID, content: ActivityContent(state: final, staleDate: nil),
                                   policy: .after(Date().addingTimeInterval(3600)))
                } else {
                    await Self.end(tradeID: a.attributes.tradeID, content: nil, policy: .immediate)
                }
                wanted.remove(a.attributes.tradeID)
                await monitor.endLiveActivity(tradeID: a.attributes.tradeID)
            } else if a.activityState == .active {
                watchToken(a, tradeID: a.attributes.tradeID, monitor: monitor)
            }
        }
        for id in wanted {
            guard let t = byID[id], t.status == .open || t.status == .upcoming else { wanted.remove(id); continue }
            if activity(for: t.id)?.activityState != .active {
                start(t, price: prices?.price(t.instrument), monitor: monitor)
            }
        }
        persist()
    }

    // ActivityKit objects aren't Sendable: look them up and act on them off the main actor, passing only values.
    @concurrent nonisolated private static func end(tradeID: String, content: ActivityContent<TradeActivityAttributes.ContentState>?,
                                                    policy: ActivityUIDismissalPolicy) async {
        for a in Activity<TradeActivityAttributes>.activities where a.attributes.tradeID == tradeID {
            await a.end(content, dismissalPolicy: policy)
        }
    }

    @concurrent nonisolated private static func update(tradeID: String,
                                                       content: ActivityContent<TradeActivityAttributes.ContentState>) async {
        for a in Activity<TradeActivityAttributes>.activities where a.attributes.tradeID == tradeID && a.activityState == .active {
            await a.update(content)
        }
    }

    private func activity(for id: UUID) -> Activity<TradeActivityAttributes>? {
        Activity<TradeActivityAttributes>.activities.first { $0.attributes.tradeID == id.uuidString }
    }

    private func watchToken(_ activity: Activity<TradeActivityAttributes>, tradeID: String, monitor: MonitorStore) {
        guard tokenTasks[tradeID] == nil else { return }
        tokenTasks[tradeID] = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await monitor.registerLiveActivity(tradeID: tradeID, token: token)
            }
            self?.tokenTasks[tradeID] = nil
        }
    }

    private func persist() {
        UserDefaults.standard.set(Array(wanted), forKey: Self.wantedKey)
    }
}
