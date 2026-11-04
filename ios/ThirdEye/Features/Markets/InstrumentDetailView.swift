import SwiftUI

struct InstrumentDetailView: View {
    @Environment(MarketStore.self) private var market
    @Environment(AnalysisStore.self) private var analyses
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    let instrument: Instrument

    @State private var timeframe: Timeframe = .d1
    @State private var candles: [Candle] = []
    @State private var loading = false
    @State private var error: MarketDataError?
    @State private var lastUpdate: Date?
    @State private var hovered: Candle?
    @State private var showLogin = false
    @State private var snapshot: FeatureEngine.Snapshot?
    @State private var showAnalyse = false

    private var displayTimeZone: TimeZone {
        instrument.provider == .upstox ? TimeZone(identifier: "Asia/Kolkata")! : .current
    }

    /// Decimal places from tick size (₹0.05 → 2) or price magnitude.
    private var precision: Int {
        if let tick = instrument.tickSize, tick > 0 {
            return min(max(Int(ceil(-log10(tick))), 0), 6)
        }
        let price = candles.last?.close ?? 100
        switch price {
        case ..<1: return 6
        case ..<10: return 4
        case ..<1000: return 2
        default: return 2
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                chartCard
                TimeframePicker(selection: $timeframe)
                if let snapshot {
                    TechnicalsPanel(snapshot: snapshot)
                } else if !candles.isEmpty {
                    Text("Need at least \(FeatureEngine.minimumBars) bars for technicals.")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                detailsCard
                AdaptiveButton(title: "Analyse with AI", systemImage: "sparkles", kind: .primary) { showAnalyse = true }
                pastAnalyses
            }
            .padding()
        }
        .background(palette.background)
        .navigationTitle(instrument.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    market.toggleWatch(instrument)
                } label: {
                    Image(systemName: market.isWatched(instrument) ? "star.fill" : "star")
                }
                .accessibilityLabel(market.isWatched(instrument) ? "Remove from watchlist" : "Add to watchlist")
            }
        }
        .task(id: "\(timeframe.rawValue)|\(scenePhase == .active)|\(market.upstoxLoggedIn)") {
            guard scenePhase == .active else { return }
            await load(showSpinner: true)
            // Live refresh while visible, at the cadence the timeframe deserves.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(timeframe.refreshInterval))
                guard !Task.isCancelled else { break }
                await load(showSpinner: false)
            }
        }
        .sheet(isPresented: $showLogin) { UpstoxLoginSheet() }
        .sheet(isPresented: $showAnalyse) { AnalyseSheet(instrument: instrument) }
        .task(id: candles.last.map { "\($0.time.timeIntervalSince1970)|\($0.close)|\(candles.count)|\(timeframe.rawValue)" } ?? "none") {
            let bars = candles
            let tf = timeframe
            guard !bars.isEmpty else { snapshot = nil; return }
            // Off the main thread: indicators over a few thousand bars take a few milliseconds.
            snapshot = await Task.detached(priority: .userInitiated) { FeatureEngine.snapshot(bars, timeframe: tf) }.value
        }
    }

    // MARK: Pieces

    private var header: some View {
        let shown = hovered ?? candles.last
        let previous = candles.dropLast().last?.close
        let change = (candles.last?.close).flatMap { last in previous.map { last - $0 } }
        let pct = change.flatMap { c in previous.map { $0 == 0 ? 0 : c / $0 * 100 } }
        return VStack(alignment: .leading, spacing: 4) {
            Text(instrument.name)
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(shown.map { format($0.close) } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                    .contentTransition(.numericText())
                if hovered == nil, let change, let pct {
                    Text("\(change >= 0 ? "+" : "")\(format(change))  (\(String(format: "%+.2f", pct))%)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(change >= 0 ? palette.up : palette.down)
                }
            }
            if let h = hovered {
                Text("O \(format(h.open))  H \(format(h.high))  L \(format(h.low))  C \(format(h.close))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
            } else if let lastUpdate {
                Text("\(instrument.currency) · \(instrument.provider.displayName) · updated \(lastUpdate.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    /// Nearest two support and two resistance zones, drawn as dashed lines.
    private var chartLevels: [ChartLevel] {
        guard let zones = snapshot?.zones else { return [] }
        let supports = zones.filter { $0.kind == .support }.prefix(2)
        let resistances = zones.filter { $0.kind == .resistance }.prefix(2)
        return (supports + resistances).map {
            ChartLevel(price: $0.price, title: $0.kind == .support ? "S" : "R", isSupport: $0.kind == .support)
        }
    }

    private var chartCard: some View {
        ZStack {
            CandleChartView(candles: candles,
                            precision: precision,
                            displayTimeZone: displayTimeZone,
                            fitToken: "\(instrument.id)|\(timeframe.rawValue)",
                            locale: instrument.currency == "INR" ? "en-IN" : "en-US",
                            levels: chartLevels,
                            onCrosshair: { hovered = $0 })
                .opacity(candles.isEmpty ? 0 : 1)
            if let error, candles.isEmpty {
                errorView(error)
            } else if loading && candles.isEmpty {
                ProgressView()
            }
        }
        .frame(height: 340)
        .dataCard(padding: 6)
    }

    @ViewBuilder
    private func errorView(_ error: MarketDataError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.largeTitle)
                .foregroundStyle(palette.neutral)
            Text(error.localizedDescription)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.textSecondary)
            switch error {
            case .loginRequired:
                Button("Log in to Upstox") { showLogin = true }.buttonStyle(.borderedProminent)
            case .notConfigured:
                NavigationLink("Set up market data") { MarketDataSettingsView() }.buttonStyle(.borderedProminent)
            default:
                Button("Retry") { Task { await load(showSpinner: true) } }.buttonStyle(.bordered)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var pastAnalyses: some View {
        let past = analyses.runs(for: instrument).prefix(5)
        if !past.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Past analyses").font(.headline).foregroundStyle(palette.textPrimary)
                ForEach(Array(past)) { run in
                    NavigationLink {
                        AnalysisReportView(run: run).navigationTitle(run.instrument.symbol)
                    } label: {
                        AnalysisRow(run: run)
                    }
                    .buttonStyle(.plain)
                }
            }
            .dataCard()
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details").font(.headline).foregroundStyle(palette.textPrimary)
            detail("Exchange", instrument.exchange)
            detail("Type", instrument.kind.title)
            if let expiry = instrument.expiry { detail("Expiry", Instrument.expiryFormatter.string(from: expiry)) }
            if let strike = instrument.strike { detail("Strike", format(strike)) }
            if let lot = instrument.lotSize, lot > 1 { detail("Lot size", lot.formatted()) }
            if let tick = instrument.tickSize { detail("Tick size", format(tick)) }
            if let underlying = instrument.underlying { detail("Underlying", underlying) }
            if let first = candles.first?.time, let last = candles.last?.time {
                detail("Bars loaded", "\(candles.count) · \(first.formatted(date: .abbreviated, time: .omitted)) → \(last.formatted(date: .abbreviated, time: .omitted))")
            }
        }
        .dataCard()
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(palette.textSecondary)
            Spacer()
            Text(value).foregroundStyle(palette.textPrimary).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(precision)).grouping(.automatic))
    }

    private func load(showSpinner: Bool) async {
        if showSpinner {
            loading = true
            candles = []
            hovered = nil
            snapshot = nil
        }
        defer { loading = false }
        do {
            let fresh = try await market.candles(for: instrument, timeframe: timeframe)
            candles = fresh
            error = fresh.isEmpty ? .unsupported("No data for this timeframe yet.") : nil
            lastUpdate = Date()
        } catch let e as MarketDataError {
            error = e
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }
}

private struct TimeframePicker: View {
    @Binding var selection: Timeframe
    @Environment(\.palette) private var palette

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Timeframe.allCases) { tf in
                    Button {
                        selection = tf
                    } label: {
                        Text(tf.label)
                            .font(.footnote.weight(selection == tf ? .bold : .regular))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(selection == tf ? palette.accent : palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .floatingGlass(in: Capsule(), tint: selection == tf ? palette.accent : nil, interactive: true)
                    .accessibilityLabel("Timeframe \(tf.label)")
                    .accessibilityAddTraits(selection == tf ? .isSelected : [])
                }
            }
        }
    }
}
