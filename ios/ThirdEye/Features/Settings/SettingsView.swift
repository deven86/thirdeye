import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @Environment(AppLock.self) private var lock
    @Environment(MarketStore.self) private var market
    @Environment(MonitorStore.self) private var monitor

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Artificial intelligence") {
                NavigationLink {
                    AIProvidersView()
                } label: {
                    LabeledContent {
                        Text("\(AIProviderKind.allCases.filter { catalog.hasKey[$0] == true }.count) connected")
                    } label: {
                        Label("AI Providers", systemImage: "key")
                    }
                }
                NavigationLink {
                    ModelTiersView()
                } label: {
                    LabeledContent {
                        Text("\(settings.tierAssignments.count) of 3 set")
                    } label: {
                        Label("Model Tiers", systemImage: "square.stack.3d.up")
                    }
                }
                Picker(selection: $settings.stageReuseHours) {
                    Text("Off").tag(0)
                    Text("6 hours").tag(6)
                    Text("12 hours").tag(12)
                    Text("24 hours").tag(24)
                } label: {
                    Label("Reuse news & context", systemImage: "arrow.uturn.backward.circle")
                }
            }

            Section("Markets") {
                NavigationLink {
                    MarketDataSettingsView()
                } label: {
                    LabeledContent {
                        Text(market.upstoxLoggedIn || market.hasTwelveDataKey ? "Connected" : "Crypto only")
                    } label: {
                        Label("Market Data", systemImage: "chart.bar.xaxis")
                    }
                }
                NavigationLink {
                    AlertsSettingsView()
                } label: {
                    LabeledContent {
                        Text(monitor.isPaired ? (monitor.isOnline ? "PC online" : "PC offline") : "Not set up")
                    } label: {
                        Label("Alerts (Windows PC)", systemImage: "bell.badge")
                    }
                }
            }

            Section {
                Toggle(isOn: $settings.watchNotifications) {
                    Label("Notify when a trade changes", systemImage: "eye")
                }
                Toggle(isOn: $settings.autoAIReview) {
                    Label("AI re-checks automatically", systemImage: "sparkles")
                }
            } header: {
                Text("Trade watch")
            } footer: {
                Text("While Third Eye is open, each open trade's reasons (trend, swings, momentum, volatility, key level) are re-checked against the chart. When something important changes, the AI re-reads the trade (Balanced model, about $0.01–0.05) and you get a notification.")
            }

            Section {
                Picker(selection: $settings.hotMarket) {
                    ForEach(HotMarket.allCases) { Text($0.title).tag($0) }
                } label: { Label("Hot trades market", systemImage: "flame") }
                Picker(selection: $settings.hotProfile) {
                    ForEach(HoldingProfile.allCases.filter { $0 != .equal }) { Text($0.title).tag($0) }
                } label: { Label("Hot trades style", systemImage: "clock") }
                Picker(selection: $settings.hotCandidates) {
                    Text("Top 3").tag(3)
                    Text("Top 5").tag(5)
                } label: { Label("Full analyses per scan", systemImage: "list.number") }
                NavigationLink { HotTradesView() } label: { Label("Open Hot trades", systemImage: "arrow.right.circle") }
            } header: {
                Text("Hot trades")
            } footer: {
                Text("Scans run only when you tap “Find hot trades” and show the estimated cost first.")
            }

            Section("Appearance") {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    LabeledContent {
                        Text(settings.theme.title)
                    } label: {
                        Label("Theme", systemImage: "paintpalette")
                    }
                }
                Toggle(isOn: $settings.colorBlindSafe) {
                    Label("Colour-blind-safe up/down", systemImage: "eye")
                }
            }

            Section {
                Picker(selection: $settings.relockSeconds) {
                    Text("Immediately").tag(1)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                } label: {
                    Label("Re-lock after", systemImage: "lock.rotation")
                }
                Toggle(isOn: $settings.hideLockScreenPnL) {
                    Label("Hide P&L on Lock Screen", systemImage: "eye.slash")
                }
                Button {
                    lock.lock()
                } label: {
                    Label("Lock now", systemImage: "lock")
                }
            } header: {
                Text("Security")
            } footer: {
                Text("API keys are stored in the Keychain and sync to your iPad through iCloud Keychain. They are never stored in app data or iCloud Drive.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { !settings.paperMode },
                    set: { wantsReal in
                        if wantsReal {
                            Task {
                                if await AppLock.authenticate(reason: "Switch Third Eye to real-money mode") == .success {
                                    settings.paperMode = false
                                }
                            }
                        } else {
                            settings.paperMode = true
                        }
                    })) {
                    Label("Real-money mode", systemImage: settings.paperMode ? "doc.text" : "indianrupeesign.circle")
                }
                Stepper(value: $settings.riskPercent, in: 0.25...2, step: 0.25) {
                    LabeledContent("Risk per trade", value: String(format: "%.2f%%", settings.riskPercent))
                }
                ForEach(settings.capital.keys.sorted(), id: \.self) { cur in
                    LabeledContent("Capital (\(cur))", value: money(settings.capital[cur] ?? 0, cur))
                }
                Stepper(value: $settings.weeklyLossLimitR, in: 1...10, step: 0.5) {
                    LabeledContent("Pause after a losing week", value: String(format: "−%.1fR", settings.weeklyLossLimitR))
                }
                Stepper(value: $settings.maxOpenRiskPercent, in: 2...20, step: 1) {
                    LabeledContent("Max open risk", value: String(format: "%.0f%% of capital", settings.maxOpenRiskPercent))
                }
            } header: {
                Text("Trading & risk guard")
            } footer: {
                Text("New trades are recorded as \(settings.paperMode ? "paper" : "REAL MONEY") trades. Switching to real money needs Face ID. Risk is capped at 2% per trade. The risk guard warns before a new trade when the last 7 days lost more than the limit, when total open risk would pass the cap, or when the trade is the same bet as ones you hold.")
            }

            Section("About") {
                NavigationLink {
                    DisclaimerView()
                } label: {
                    Label("Disclaimers", systemImage: "exclamationmark.shield")
                }
                LabeledContent("Version", value: Bundle.main.appVersionString)
            }
        }
        .navigationTitle("Settings")
    }
}

struct DisclaimerView: View {
    private let items = [
        "Personal analytical tool. Not investment advice. Not a SEBI-registered Research Analyst or Investment Adviser. Not distributed to third parties.",
        "Scores and signals are generated by AI models and rule-based algorithms that can be wrong, outdated or hallucinated. Verify against primary data.",
        "Trading in securities and derivatives involves substantial risk of loss. Past performance and back-tests do not guarantee future results.",
        "Alerts depend on third-party data, network and Apple push delivery and may be delayed or not delivered. Always keep a stop-loss order at your broker.",
        "Market data © respective exchanges and data vendors (Upstox, Twelve Data, Binance), for personal use only.",
        "Charts by TradingView Lightweight Charts™ (Apache License 2.0) — tradingview.com.",
    ]

    var body: some View {
        List(items, id: \.self) { item in
            Text(item).font(.callout)
        }
        .navigationTitle("Disclaimers")
    }
}

extension Bundle {
    var appVersionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
