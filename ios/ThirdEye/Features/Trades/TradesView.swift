import SwiftUI

struct TradesView: View {
    @Environment(TradeStore.self) private var store
    @Environment(MarketStore.self) private var market
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @State private var prices = PriceBook()
    @State private var tab: TradeStatus = .open

    private var visible: [Trade] {
        tab == .closed ? store.trades.filter { $0.status == .closed || $0.status == .cancelled }.sorted { ($0.closedAt ?? $0.updatedAt) > ($1.closedAt ?? $1.updatedAt) }
                       : store.trades(tab)
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $tab) {
                    Text("Upcoming (\(store.trades(.upcoming).count))").tag(TradeStatus.upcoming)
                    Text("Open (\(store.trades(.open).count))").tag(TradeStatus.open)
                    Text("Closed").tag(TradeStatus.closed)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if tab == .closed { JournalStats(trades: store.trades) }
            if visible.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyText))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(visible) { t in
                        NavigationLink(value: t.id) { TradeRow(trade: t, price: prices.price(t.instrument)) }
                    }
                }
            }
        }
        .navigationTitle("Trades")
        .navigationDestination(for: UUID.self) { id in
            if let t = store.trade(id: id) { TradeDetailView(tradeID: t.id, prices: prices) }
        }
        .task(id: "\(tab)|\(scenePhase == .active)|\(store.trades.count)") {
            guard scenePhase == .active, tab != .closed else { return }
            while !Task.isCancelled {
                await prices.refresh(Array(visible.prefix(12).map(\.instrument)), market: market)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var emptyTitle: String {
        switch tab {
        case .upcoming: "No upcoming trades"
        case .open: "No open positions"
        default: "No closed trades yet"
        }
    }

    private var emptyText: String {
        switch tab {
        case .upcoming: "Run an analysis, then tap “Save as upcoming trade” on its plan."
        case .open: "When price reaches an upcoming trade's entry zone and you buy, tap “I entered”."
        default: "Closed trades and their profit or loss appear here."
        }
    }
}

struct TradeRow: View {
    @Environment(\.palette) private var palette
    let trade: Trade
    let price: Double?

    var body: some View {
        let s = TradeMath.summary(trade, lastPrice: price)
        let signal = TradeMath.signal(trade, lastPrice: price)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trade.instrument.symbol).font(.body.weight(.semibold))
                Text(trade.side.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(trade.isLong ? palette.up : palette.down)
                Chip(text: trade.badge.title, color: palette.accent)
                if trade.mode == .paper { Chip(text: "Paper", color: palette.neutral) }
                Spacer()
                if trade.status == .open || trade.status == .closed, let total = trade.status == .closed ? s.realized : s.total {
                    Text(money(total, trade.instrument.currency, signed: true))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(total >= 0 ? palette.up : palette.down)
                }
            }
            HStack(spacing: 8) {
                if let price { Text("Now \(plainPrice(price))").font(.caption.monospacedDigit()).foregroundStyle(palette.textSecondary) }
                SignalLabel(signal: signal, trade: trade)
                Spacer()
                if trade.status == .cancelled { Text("Cancelled").font(.caption).foregroundStyle(palette.textSecondary) }
                else if trade.status != .closed {
                    let days = Calendar.current.dateComponents([.day], from: Date(), to: trade.completeBy).day ?? 0
                    Text(days >= 0 ? "\(days)d left" : "Overdue").font(.caption).foregroundStyle(days >= 0 ? palette.textSecondary : palette.warning)
                } else if let r = s.rMultiple {
                    Text(String(format: "%+.2fR", r)).font(.caption.monospacedDigit()).foregroundStyle(palette.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct SignalLabel: View {
    @Environment(\.palette) private var palette
    let signal: TradeMath.Signal
    let trade: Trade

    var body: some View {
        switch signal {
        case .none: EmptyView()
        case .inEntryZone: Chip(text: "In entry zone", color: palette.accent)
        case .nearEntryZone(let pct): Text(String(format: "%+.1f%% from entry", pct)).font(.caption).foregroundStyle(palette.textSecondary)
        case .stopHit: Chip(text: "Stop hit — close", color: palette.down)
        case .takeProfitReached(let stage): Chip(text: "TP\(stage) reached", color: palette.up)
        case .pastCompleteBy: Chip(text: "Past complete-by", color: palette.warning)
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct JournalStats: View {
    @Environment(\.palette) private var palette
    let trades: [Trade]

    var body: some View {
        ForEach(TradeMode.allCases, id: \.self) { mode in
            let stats = TradeMath.stats(trades, mode: mode)
            if !stats.isEmpty {
                Section("\(mode.title) results") {
                    ForEach(stats.keys.sorted(), id: \.self) { currency in
                        let s = stats[currency]!
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(currency).font(.caption.weight(.semibold)).foregroundStyle(palette.textSecondary)
                                Spacer()
                                Text(money(s.totalPnL, currency, signed: true))
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(s.totalPnL >= 0 ? palette.up : palette.down)
                            }
                            Text("\(s.closedCount) closed · win rate \(s.winRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—") · average \(s.averageR.map { String(format: "%+.2fR", $0) } ?? "—")")
                                .font(.caption).foregroundStyle(palette.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

func money(_ v: Double, _ currency: String, signed: Bool = false) -> String {
    let locale = Locale(identifier: currency == "INR" ? "en_IN" : "en_US")
    let body = abs(v).formatted(.number.precision(.fractionLength(2)).locale(locale))
    let symbol = currency == "INR" ? "₹" : currency == "USD" ? "$" : ""
    let suffix = symbol.isEmpty ? " \(currency)" : ""
    let sign = v < 0 ? "−" : (signed && v > 0 ? "+" : "")
    return "\(sign)\(symbol)\(body)\(suffix)"
}

func plainPrice(_ v: Double) -> String {
    v.formatted(.number.precision(.fractionLength(v < 10 ? 4 : 2)))
}
