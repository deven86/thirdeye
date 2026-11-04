import SwiftUI

@main
struct ThirdEyeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = MonitorStore.shared
    @State private var settings = AppSettings()
    @State private var lock = AppLock()
    @State private var catalog = ModelCatalog()
    @State private var market = MarketStore()
    @State private var analyses = AnalysisStore()
    @State private var trades = TradeStore()
    @State private var hotScans = HotScanStore()

    var body: some Scene {
        WindowGroup {
            ThemeHost {
                RootView()
            }
            .environment(settings)
            .environment(lock)
            .environment(catalog)
            .environment(market)
            .environment(analyses)
            .environment(trades)
            .environment(hotScans)
            .environment(monitor)
        }
    }
}

/// Decides between the lock screen and the app, and covers content whenever the scene is not active
/// so the app-switcher snapshot never shows trades or keys.
struct RootView: View {
    @Environment(AppLock.self) private var lock
    @Environment(AppSettings.self) private var settings
    @Environment(TradeStore.self) private var trades
    @Environment(MarketStore.self) private var market
    @Environment(MonitorStore.self) private var monitor
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if lock.isUnlocked {
                MainTabView()
                    .transition(.opacity)
            } else {
                LockView()
                    .transition(.opacity)
            }
            if scenePhase != .active {
                PrivacyCover()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: lock.isUnlocked)
        .animation(.easeInOut(duration: 0.2), value: scenePhase)
        .onChange(of: scenePhase) { _, phase in
            lock.relockAfter = TimeInterval(settings.relockSeconds)
            lock.handleScenePhase(phase)
            if phase == .active {
                Task { await monitor.refreshAll(trades: trades.trades, market: market) }
            }
        }
        // Keep the PC monitor's watch list in step with every trade change (debounced).
        .onChange(of: trades.trades) { _, all in monitor.scheduleSync(all) }
        .onChange(of: market.upstoxTokenExpiry) { _, _ in Task { await monitor.syncCredentials(market: market) } }
        .onChange(of: market.hasTwelveDataKey) { _, _ in Task { await monitor.syncCredentials(market: market) } }
        .task { await monitor.refreshAll(trades: trades.trades, market: market) }
    }
}

struct PrivacyCover: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "eye")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(palette.accent)
                Text("Third Eye")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
            }
        }
        .accessibilityHidden(true)
    }
}
