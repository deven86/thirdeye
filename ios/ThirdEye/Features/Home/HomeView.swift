import SwiftUI

struct HomeView: View {
    @Environment(\.palette) private var palette
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MarketStore.self) private var market
    @Environment(AnalysisStore.self) private var analyses
    @Environment(TradeStore.self) private var trades
    @State private var prices = PriceBook()
    @Environment(HotScanStore.self) private var hotScans
    @Environment(MonitorStore.self) private var monitor
    @Environment(OutcomeStore.self) private var outcomes

    private var hotSubtitle: String {
        guard let last = hotScans.scans.first else {
            return "AI scans \(settings.hotMarket.title) and analyses the top \(settings.hotCandidates)"
        }
        let hot = last.hotTrades.map(\.instrument.symbol)
        let watch = last.watchList.count
        let when = last.startedAt.formatted(.relative(presentation: .named))
        if !hot.isEmpty { return "Last scan: \(hot.joined(separator: ", "))" + (watch > 0 ? " · \(watch) on watch" : "") }
        return "Last scan \(when): no hot trades" + (watch > 0 ? " · \(watch) on watch" : "")
    }
    @State private var demoScore = 712

    private var connectedCount: Int {
        AIProviderKind.allCases.filter { catalog.hasKey[$0] == true }.count
    }

    private var reportCardSummary: String {
        let graded = analyses.runs.filter { outcomes.outcomes[$0.id] != nil }.count
        let waiting = outcomes.pending(analyses.runs)
        if graded == 0 { return waiting > 0 ? "\(waiting) ready to grade" : "grades start after each holding period" }
        let card = ReportCard.build(runs: analyses.runs, outcomes: outcomes.outcomes)
        return "\(graded) graded" + (card.directionRightPct.map { " · \(Int($0.rounded()))% right" } ?? "")
    }

    /// The risk guard's pause suggestion after a losing week.
    private var losingWeek: String? {
        let mode: TradeMode = settings.paperMode ? .paper : .real
        let week = RiskGuard.lastSevenDays(trades.trades, mode: mode, now: Date())
        guard week.count > 0, week.r <= -settings.weeklyLossLimitR else { return nil }
        return "Losing week (\(String(format: "%+.1f", week.r))R) — the risk guard suggests a pause"
    }

    private var monitorOfflineText: String {
        if let s = monitor.status, s.lastLoopAt.timeIntervalSince1970 > 0 {
            return "PC monitor offline since \(s.lastLoopAt.formatted(date: .omitted, time: .shortened)) — alerts paused"
        }
        return "Can't reach your PC monitor — alerts may be paused"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if monitor.isPaired, monitor.lastStatusAt != nil, !monitor.isOnline {
                    NavigationLink { AlertsSettingsView() } label: {
                        Label(monitorOfflineText, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(palette.warning)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .floatingGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let losing = losingWeek {
                    Label(losing, systemImage: "hand.raised.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.down)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .floatingGlass(in: Capsule())
                }
                if settings.paperMode {
                    Label("Paper mode — no real money", systemImage: "doc.text")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .floatingGlass(in: Capsule())
                }

                NavigationLink {
                    HotTradesView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "flame.fill").font(.title2).foregroundStyle(palette.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hot trades").font(.headline).foregroundStyle(palette.textPrimary)
                            Text(hotSubtitle).font(.caption).foregroundStyle(palette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(palette.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .dataCard()

                let active = trades.trades.filter { $0.status == .open || $0.status == .upcoming }
                if !active.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Your trades").font(.headline).foregroundStyle(palette.textPrimary)
                            Spacer()
                            Text("\(trades.trades(.open).count) open · \(trades.trades(.upcoming).count) upcoming")
                                .font(.caption).foregroundStyle(palette.textSecondary)
                        }
                        ForEach(active.prefix(6)) { t in
                            TradeRow(trade: t, price: prices.price(t.instrument))
                        }
                        Text("Open the Trades tab to record entries and exits.")
                            .font(.caption2).foregroundStyle(palette.textSecondary)
                    }
                    .dataCard()
                    .task(id: active.count) {
                        await prices.refresh(Array(active.prefix(6).map(\.instrument)), market: market)
                    }
                }

                if !analyses.runs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent analyses").font(.headline).foregroundStyle(palette.textPrimary)
                        ForEach(Array(analyses.runs.prefix(5))) { run in
                            NavigationLink {
                                AnalysisReportView(run: run).navigationTitle(run.instrument.symbol)
                            } label: { AnalysisRow(run: run) }
                            .buttonStyle(.plain)
                        }
                        Text("AI spend this month: $\(String(format: "%.2f", analyses.monthToDateCost))")
                            .font(.caption).foregroundStyle(palette.textSecondary)
                        NavigationLink { ReportCardView() } label: {
                            HStack {
                                Label("Report card", systemImage: "checkmark.seal")
                                    .font(.callout.weight(.semibold))
                                Spacer()
                                Text(reportCardSummary).font(.caption).foregroundStyle(palette.textSecondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .dataCard()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Score preview")
                        .font(.headline)
                        .foregroundStyle(palette.textPrimary)
                    ScoreGauge(score: demoScore, caption: "Sample only — run a real analysis from any product in Markets")
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity)
                    Slider(value: Binding(get: { Double(demoScore) }, set: { demoScore = Int($0) }),
                           in: 10...1000, step: 1)
                        .accessibilityLabel("Sample score")
                    Text("Drag to see how the verdict bands and colours behave in this theme.")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .dataCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Setup")
                        .font(.headline)
                        .foregroundStyle(palette.textPrimary)
                    SetupRow(done: connectedCount > 0,
                             title: "Connect an AI provider",
                             detail: connectedCount > 0 ? "\(connectedCount) connected" : "Settings → AI Providers")
                    SetupRow(done: settings.tierAssignments.count == ModelTier.allCases.count,
                             title: "Choose Fast / Balanced / Deep models",
                             detail: "\(settings.tierAssignments.count) of 3 tiers set")
                    SetupRow(done: market.upstoxLoggedIn,
                             title: "Connect Indian markets (Upstox)",
                             detail: market.upstoxLoggedIn ? "Logged in for today"
                                : (market.hasUpstoxKeys ? "Log in today: Settings → Market Data" : "Settings → Market Data"))
                    SetupRow(done: market.hasTwelveDataKey,
                             title: "Connect US stocks, forex & gold",
                             detail: market.hasTwelveDataKey ? "Twelve Data connected" : "Settings → Market Data")
                }
                .dataCard()
            }
            .padding()
        }
        .skinScreen()
        .background(palette.background)
        .navigationTitle("Home")
    }
}

private struct SetupRow: View {
    @Environment(\.palette) private var palette
    let done: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? palette.up : palette.neutral)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(palette.textPrimary)
                Text(detail).font(.caption).foregroundStyle(palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
