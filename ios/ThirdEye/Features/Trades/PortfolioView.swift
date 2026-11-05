import Charts
import SwiftUI

struct PortfolioView: View {
    @Environment(TradeStore.self) private var store
    @Environment(MarketStore.self) private var market
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase

    @State private var prices = PriceBook()
    @State private var mode: TradeMode = .paper
    @State private var grouping: PortfolioMath.Grouping = .product
    @State private var usdInr: (rate: Double, at: Date)?

    private static let usdInrInstrument = Instrument(id: "twelve:USD/INR", provider: .twelveData, symbol: "USD/INR",
                                                     name: "US Dollar / Indian Rupee", exchange: "FX", segment: "FOREX",
                                                     kind: .forex, currency: "INR")

    private var summaries: [PortfolioMath.CurrencySummary] {
        PortfolioMath.summaries(store.trades, mode: mode, prices: { prices.price($0) }, capital: settings.capital)
    }

    var body: some View {
        let sums = summaries
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Mode", selection: $mode) {
                    Text("Paper").tag(TradeMode.paper)
                    Text("Real money").tag(TradeMode.real)
                }
                .pickerStyle(.segmented)

                if sums.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "chart.pie",
                                           description: Text("Open positions and closed trades in \(mode == .paper ? "paper" : "real-money") mode appear here. Track a trade from any product, then tap “I entered”."))
                } else {
                    if sums.count > 1, let total = PortfolioMath.totalInINR(sums, usdInr: usdInr?.rate), let fx = usdInr {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Approximate total").font(.caption).foregroundStyle(palette.textSecondary)
                            Text(money(total, "INR")).font(.title2.weight(.bold).monospacedDigit())
                            Text("Converted at USD/INR \(String(format: "%.2f", fx.rate)) (\(fx.at.formatted(date: .omitted, time: .shortened))); USDT counted as USD.")
                                .font(.caption2).foregroundStyle(palette.textSecondary)
                        }
                        .dataCard()
                    }
                    ForEach(sums, id: \.currency) { s in currencyCard(s) }
                    allocationCard(sums.flatMap(\.holdings))
                    ForEach(sums, id: \.currency) { s in equityCard(s.currency) }
                    holdingsCard(sums.flatMap(\.holdings))
                }
            }
            .padding()
        }
        .background(palette.background)
        .navigationTitle("Portfolio")
        .onAppear { mode = settings.paperMode ? .paper : .real }
        .task(id: "\(mode)|\(scenePhase == .active)|\(store.trades.count)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                let open = store.trades.filter { $0.status == .open && $0.mode == mode }.map(\.instrument)
                await prices.refresh(Array(Dictionary(grouping: open, by: \.id).compactMap(\.value.first).prefix(15)), market: market)
                let currencies = Set(store.trades.filter { $0.mode == mode }.map(\.instrument.currency))
                if currencies.contains("INR"), currencies.count > 1, market.hasTwelveDataKey,
                   usdInr == nil || Date().timeIntervalSince(usdInr!.at) > 600,
                   let rate = try? await market.lastPrice(Self.usdInrInstrument) {
                    usdInr = (rate, Date())
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: Cards

    private func currencyCard(_ s: PortfolioMath.CurrencySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(s.currency).font(.headline)
                Spacer()
                Text("\(s.holdings.count) open").font(.caption).foregroundStyle(palette.textSecondary)
            }
            HStack(alignment: .top) {
                metric("Current value", s.value.map { money($0, s.currency) } ?? "updating…")
                metric("Invested (open)", money(s.cost, s.currency))
            }
            HStack(alignment: .top) {
                metric("Unrealised", s.unrealized.map { money($0, s.currency, signed: true) } ?? "—",
                       color: (s.unrealized ?? 0) >= 0 ? palette.up : palette.down)
                metric("Realised this month", money(s.realizedThisMonth, s.currency, signed: true),
                       color: s.realizedThisMonth >= 0 ? palette.up : palette.down)
            }
            HStack(alignment: .top) {
                metric("Realised all time", money(s.realizedAllTime, s.currency, signed: true),
                       color: s.realizedAllTime >= 0 ? palette.up : palette.down)
                metric("If every stop is hit", s.openRisk > 0 ? "−" + money(s.openRisk, s.currency) : "No open risk",
                       sub: s.openRiskPercentOfCapital.map { String(format: "%.1f%% of capital", $0) },
                       color: (s.openRiskPercentOfCapital ?? 0) > 6 ? palette.warning : palette.textPrimary)
            }
            if let pct = s.openRiskPercentOfCapital, pct > 6 {
                Label("More than 6% of your capital is at risk across open trades. Consider tightening stops or taking fewer trades.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(palette.warning)
            }
        }
        .dataCard()
    }

    private func metric(_ title: String, _ value: String, sub: String? = nil, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(palette.textSecondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(color ?? palette.textPrimary)
            if let sub { Text(sub).font(.caption2).foregroundStyle(palette.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func allocationCard(_ holdings: [PortfolioMath.Holding]) -> some View {
        let slices = PortfolioMath.allocation(holdings, by: grouping)
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Allocation").font(.headline)
                    Spacer()
                    Picker("Group by", selection: $grouping) {
                        ForEach(PortfolioMath.Grouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Chart(slices) { s in
                    SectorMark(angle: .value("Share", s.amount), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(by: .value("Group", s.label))
                        .cornerRadius(3)
                }
                .chartLegend(.hidden)
                .frame(height: 180)
                ForEach(Array(slices.prefix(8).enumerated()), id: \.element.id) { _, s in
                    HStack {
                        Text(s.label).font(.callout)
                        Spacer()
                        Text(String(format: "%.1f%%", s.percent)).font(.callout.monospacedDigit())
                    }
                }
                if slices.count > 1, let top = slices.first, top.percent > 40 {
                    Text("\(top.label) is \(Int(top.percent))% of open positions — concentrated.")
                        .font(.caption).foregroundStyle(palette.warning)
                }
                Text("Mixes currencies by size only; amounts are not converted.").font(.caption2).foregroundStyle(palette.textSecondary)
            }
            .dataCard()
        }
    }

    @ViewBuilder
    private func equityCard(_ currency: String) -> some View {
        let points = PortfolioMath.equityCurve(store.trades, mode: mode, currency: currency)
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Realised P&L over time · \(currency)").font(.headline)
                Chart(points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("P&L", p.cumulative))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(palette.accent)
                    AreaMark(x: .value("Date", p.date), y: .value("P&L", p.cumulative))
                        .foregroundStyle(palette.accent.opacity(0.12))
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(palette.separator)
                }
                .frame(height: 160)
            }
            .dataCard()
        }
    }

    @ViewBuilder
    private func holdingsCard(_ holdings: [PortfolioMath.Holding]) -> some View {
        if !holdings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open positions").font(.headline)
                ForEach(holdings) { h in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(h.trade.instrument.fullSymbol) · \(h.trade.instrument.exchangeBadge)").font(.callout.weight(.semibold))
                            Text("\(h.trade.side.uppercased()) \(h.openQuantity.formatted()) @ \(plainPrice(h.averageEntry))")
                                .font(.caption.monospacedDigit()).foregroundStyle(palette.textSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(h.value.map { money($0, h.trade.instrument.currency) } ?? "—").font(.callout.monospacedDigit())
                            if let u = h.unrealized {
                                Text(money(u, h.trade.instrument.currency, signed: true))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(u >= 0 ? palette.up : palette.down)
                            }
                        }
                    }
                }
            }
            .dataCard()
        }
    }
}
