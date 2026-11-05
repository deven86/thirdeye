import SwiftUI
import WidgetKit

/// Home Screen widget: every open and upcoming trade with live price, result in R, profit in money and the
/// stop → target bar. Prices come from the PC monitor (refreshed about every 15 minutes, iOS decides exactly)
/// and from the app whenever it is open.
struct TradesEntry: TimelineEntry, Sendable {
    var date: Date
    var trades: [WidgetTrade]
    var hideMoney: Bool
    var fresh: Bool            // prices came from the PC just now
    var empty: Bool
}

private struct Unchecked<T>: @unchecked Sendable { let value: T }

struct TradesProvider: TimelineProvider {
    func placeholder(in context: Context) -> TradesEntry { Self.sample }

    func getSnapshot(in context: Context, completion: @escaping (TradesEntry) -> Void) {
        completion(context.isPreview ? Self.sample : Self.load(prices: nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TradesEntry>) -> Void) {
        let done = Unchecked(value: completion)
        Task {
            let prices = await SharedStore.fetchPrices()
            let entry = Self.load(prices: prices)
            done.value(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    static func load(prices: [String: (price: Double, at: Double)]?) -> TradesEntry {
        guard let snap = SharedStore.loadSnapshot() else {
            return TradesEntry(date: Date(), trades: [], hideMoney: false, fresh: false, empty: true)
        }
        var trades = snap.trades
        if let prices {
            for i in trades.indices {
                if let p = prices[trades[i].id.uppercased()] {
                    trades[i].lastPrice = p.price
                    trades[i].lastPriceAt = p.at
                }
            }
        }
        // Open trades first, then by size of the move either way.
        trades.sort { a, b in
            if a.status != b.status { return a.status == "open" }
            return abs(a.lastPrice.flatMap { a.r(at: $0) } ?? 0) > abs(b.lastPrice.flatMap { b.r(at: $0) } ?? 0)
        }
        return TradesEntry(date: Date(), trades: trades, hideMoney: snap.hideMoney, fresh: prices != nil, empty: trades.isEmpty)
    }

    static let sample = TradesEntry(date: Date(), trades: [
        WidgetTrade(id: "1", name: "TRENT (NSE)", side: "long", status: "open", entry: 3055, entryLow: 3040, entryHigh: 3070,
                    stop: 2940, initialStop: 2940, nextTarget: 3135, nextTargetStage: 1, openUnits: 10, realized: 0,
                    currency: "INR", decimals: 2, paper: true, lastPrice: 3098, lastPriceAt: nil),
        WidgetTrade(id: "2", name: "NZD/USD", side: "short", status: "open", entry: 0.56396, entryLow: 0.5635, entryHigh: 0.5652,
                    stop: 0.57, initialStop: 0.57, nextTarget: 0.5587, nextTargetStage: 1, openUnits: 100_000, realized: 0,
                    currency: "USD", decimals: 5, paper: true, lastPrice: 0.56376, lastPriceAt: nil),
    ], hideMoney: false, fresh: true, empty: false)
}

struct TradesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ThirdEyeTrades", provider: TradesProvider()) { entry in
            TradesWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color.teal.opacity(0.25), Color.indigo.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .background(.ultraThinMaterial)
                }
                .widgetURL(URL(string: "thirdeye://trades"))
        }
        .configurationDisplayName("Open trades")
        .description("Every open trade: price, result in R, profit, and how close it is to the stop or next target.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct TradesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TradesEntry

    private var limit: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 7
        default: 8
        }
    }

    var body: some View {
        if entry.empty {
            VStack(spacing: 6) {
                Image(systemName: "eye").font(.title2).foregroundStyle(.teal)
                Text("No open trades").font(.headline)
                Text("Open Third Eye once to fill this widget.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else if family == .systemSmall {
            small
        } else {
            list
        }
    }

    // MARK: Small: the total, then the biggest mover

    private var small: some View {
        let open = entry.trades.filter { $0.status == "open" }
        let byCurrency = Dictionary(grouping: open, by: \.currency)
        let best = byCurrency.max { $0.value.count < $1.value.count }
        let cur = best?.key ?? "", list = best?.value ?? []
        let total = list.compactMap { t in t.lastPrice.flatMap { t.pnl(at: $0) } }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            if let first = list.first, !entry.hideMoney {
                Text(first.money(total)).font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(total >= 0 ? .green : .red).minimumScaleFactor(0.6).lineLimit(1)
                Text("\(list.count) open in \(cur)\(byCurrency.count > 1 ? " · +\(byCurrency.count - 1) more currencies" : "")")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("\(open.count) open").font(.title2.weight(.bold))
            }
            Spacer(minLength: 0)
            if let t = entry.trades.first { row(t, compact: true) }
        }
    }

    // MARK: Medium / large: one glass row per trade

    private var list: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 5 : 7) {
            header
            ForEach(entry.trades.prefix(limit)) { t in
                Link(destination: URL(string: "thirdeye://trade/\(t.id)")!) { row(t, compact: family == .systemMedium) }
            }
            if entry.trades.count > limit {
                Text("+\(entry.trades.count - limit) more in Third Eye").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye").foregroundStyle(.teal)
            Text("Third Eye").font(.caption.weight(.semibold))
            Spacer()
            Text(entry.date, style: .time).font(.caption2).foregroundStyle(entry.fresh ? Color.secondary : Color.orange)
        }
    }

    @ViewBuilder
    private func row(_ t: WidgetTrade, compact: Bool) -> some View {
        let p = t.lastPrice
        let state = p.map { t.status(at: $0) } ?? "No price yet"
        let tint: Color = state == "STOP HIT" || state == "Near stop" ? .red
            : state.hasSuffix("hit") ? .green
            : (p.flatMap { t.pnl(at: $0) } ?? 0) >= 0 ? .green : .red
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(t.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(t.isLong ? "LONG" : "SHORT").font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background((t.isLong ? Color.green : Color.red).opacity(0.22), in: Capsule())
                if t.paper { Text("PAPER").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
                Spacer(minLength: 2)
                if let p { Text(t.price(p)).font(.caption.monospacedDigit()).lineLimit(1) }
            }
            HStack(spacing: 6) {
                if let p, let r = t.r(at: p) {
                    Text(String(format: "%+.2fR", r)).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
                }
                if !entry.hideMoney, let p, let money = t.pnl(at: p) {
                    Text(t.money(money)).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(tint).lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(state).font(.caption2).foregroundStyle(state == "Open" ? Color.secondary : tint).lineLimit(1)
            }
            if !compact, let p {
                GeometryReader { geo in
                    let w = geo.size.width, x = t.progress(at: p)
                    ZStack(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [.red.opacity(0.6), .gray.opacity(0.35), .green.opacity(0.6)],
                                                      startPoint: .leading, endPoint: .trailing)).frame(height: 4)
                        Circle().fill(.primary).frame(width: 8, height: 8).offset(x: max(0, min(w - 8, w * x - 4)))
                    }
                }
                .frame(height: 8)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
