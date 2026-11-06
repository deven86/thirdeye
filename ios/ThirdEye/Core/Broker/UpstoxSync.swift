import Foundation
import Observation

/// Pulls your Upstox fills, positions and stop orders and brings Third Eye in line: matched fills are added to
/// their trades (automatically, unless turned off); the rest is listed for you to decide.
@Observable
final class UpstoxSync {
    private(set) var plan: UpstoxReconciler.Plan?
    private(set) var lastSync: Date?
    private(set) var lastAdded: [UpstoxReconciler.Match] = []
    private(set) var warnings: [String] = []
    private(set) var error: String?
    private(set) var running = false
    private(set) var ignored: Set<String>
    private var snapshot: BrokerSnapshot?

    private static let ignoredKey = "upstox.ignored"

    init() {
        ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? [])
    }

    var attentionCount: Int {
        guard let plan else { return 0 }
        return plan.matches.count + plan.unmatchedFills.count + plan.untracked.count + plan.mismatches.count
            + plan.stops.filter { $0.brokerStop == nil }.count
    }

    /// `auto`: called by the app every few minutes; skipped when run less than 10 minutes ago.
    func sync(trades: TradeStore, market: MarketStore, settings: AppSettings, auto: Bool = false) async {
        guard !running else { return }
        if auto, let lastSync, Date().timeIntervalSince(lastSync) < 600 { return }
        guard market.upstoxLoggedIn, let token = market.monitorCredentials().upstoxToken else {
            if !auto { error = UpstoxPortfolioError.notLoggedIn.localizedDescription }
            return
        }
        running = true
        defer { running = false }
        do {
            let snap = try await UpstoxPortfolioClient(accessToken: token).snapshot()
            snapshot = snap
            warnings = snap.warnings
            error = nil
            lastSync = Date()
            var p = UpstoxReconciler.plan(trades: trades.trades, snapshot: snap, ignored: ignored)
            if settings.autoImportUpstox, !p.matches.isEmpty {
                let matches = p.matches
                if trades.applyBrokerMatches(matches) > 0 { lastAdded = matches + lastAdded.filter { a in !matches.contains { $0.id == a.id } } }
                p = UpstoxReconciler.plan(trades: trades.trades, snapshot: snap, ignored: ignored)
            }
            plan = p
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addMatches(trades: TradeStore) {
        guard let plan, !plan.matches.isEmpty else { return }
        if trades.applyBrokerMatches(plan.matches) > 0 { lastAdded = plan.matches }
        replan(trades)
    }

    func ignore(_ id: String, trades: TradeStore) {
        ignored.insert(id)
        UserDefaults.standard.set(Array(ignored), forKey: Self.ignoredKey)
        replan(trades)
    }

    func track(_ p: BrokerPosition, trades: TradeStore, market: MarketStore) -> UUID {
        let instrument = market.index.instrument(id: p.instrumentKey) ?? UpstoxReconciler.fallbackInstrument(p)
        let t = UpstoxReconciler.trade(for: p, instrument: instrument)
        trades.save(t)
        replan(trades)
        return t.id
    }

    func useBrokerStop(_ check: UpstoxReconciler.StopCheck, trades: TradeStore) {
        guard let s = check.brokerStop, var t = trades.trade(id: check.tradeID) else { return }
        t.stopLoss = s
        trades.save(t)
        replan(trades)
    }

    private func replan(_ trades: TradeStore) {
        guard let snapshot else { return }
        plan = UpstoxReconciler.plan(trades: trades.trades, snapshot: snapshot, ignored: ignored)
    }
}
