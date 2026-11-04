import SwiftUI

/// iPhone: tab bar (gets Liquid Glass automatically on iOS 26).
/// iPad: the same tabs adapt to a sidebar via `.sidebarAdaptable`.
struct MainTabView: View {
    enum AppTab: Hashable { case home, markets, portfolio, trades, settings }
    @State private var selection: AppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "gauge.with.dots.needle.67percent", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            Tab("Markets", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.markets) {
                NavigationStack { MarketsView() }
            }
            Tab("Portfolio", systemImage: "chart.pie", value: AppTab.portfolio) {
                NavigationStack { PortfolioView() }
            }
            Tab("Trades", systemImage: "list.bullet.rectangle", value: AppTab.trades) {
                NavigationStack { TradesView() }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

struct ComingSoonView: View {
    @Environment(\.palette) private var palette
    let title: String
    let systemImage: String
    let milestone: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            Text("Arrives in \(milestone)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .floatingGlass(in: Capsule())
        }
        .background(palette.background)
        .navigationTitle(title)
    }
}
