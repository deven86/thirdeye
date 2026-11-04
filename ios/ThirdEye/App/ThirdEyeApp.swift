import SwiftUI

@main
struct ThirdEyeApp: App {
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
        }
    }
}

/// Decides between the lock screen and the app, and covers content whenever the scene is not active
/// so the app-switcher snapshot never shows trades or keys.
struct RootView: View {
    @Environment(AppLock.self) private var lock
    @Environment(AppSettings.self) private var settings
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
        }
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
