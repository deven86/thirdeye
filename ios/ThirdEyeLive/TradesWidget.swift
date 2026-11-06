import SwiftUI
#if canImport(ThirdEye)
@testable import ThirdEye   // design snapshot tests compile these files too
#endif
import WidgetKit

/// Home Screen widget: every open and upcoming trade with live price, result in R, profit in money and the
/// stop → target bar. Prices come from the PC monitor (refreshed about every 15 minutes, iOS decides exactly)
/// and from the app whenever it is open.
nonisolated struct TradesEntry: TimelineEntry, Sendable {
    var date: Date
    var trades: [WidgetTrade]
    var hideMoney: Bool
    var fresh: Bool            // prices came from the PC just now
    var empty: Bool
}

private nonisolated struct Unchecked<T>: @unchecked Sendable { let value: T }

nonisolated struct TradesProvider: TimelineProvider {
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
                .containerBackground(for: .widget) { TE.background }
                .widgetURL(URL(string: "thirdeye://trades"))
        }
        .configurationDisplayName("Open trades")
        .description("Your open trades as in the Trades tab: profit, price, status, R, days left and the stop → target bar.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

/// Fixed row heights + a count worked out from the space the widget really has, so no row is ever cut at
/// the top, bottom or corners, on any iPhone or iPad size.
struct TradesWidgetView: View {
    @Environment(\.widgetFamily) private var envFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: TradesEntry
    var familyOverride: WidgetFamily? = nil      // design snapshots in tests
    private var family: WidgetFamily { familyOverride ?? envFamily }

    private let headerHeight: CGFloat = 18
    private let gap: CGFloat = 6
    private var glassMode: Bool { renderingMode != .fullColor }   // Clear / Tinted Home Screen

    var body: some View {
        if entry.empty {
            VStack(spacing: 6) {
                Image(systemName: "eye").font(.title2).foregroundStyle(TE.accent)
                Text("No open trades").font(.headline)
                Text("Open Third Eye once to fill this widget.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if family == .systemSmall {
            small
        } else {
            GeometryReader { geo in list(height: geo.size.height) }
        }
    }

    private func header(more: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(TE.accent)
            Text(family == .systemSmall ? "Trades" : "Open trades").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if more > 0 {
                Text("+\(more) more").font(.system(size: 10, weight: .semibold)).foregroundStyle(TE.accent)
            }
            Spacer(minLength: 4)
            Text(entry.date, style: .time).font(.system(size: 10).monospacedDigit())
                .foregroundStyle(entry.fresh ? Color.secondary : TE.warning)
        }
        .frame(height: headerHeight)
    }

    private func list(height: CGFloat) -> some View {
        // A row with the bar needs 56 pt; without it 44 pt. Use the bar only when at least two rows still fit.
        // With the stop / target row (and the result at each) a row needs 86 pt: used when every trade fits, or 3+ do.
        let room = height - headerHeight - gap
        let withLevels = Int((room + gap) / (86 + gap))
        let showLevels = withLevels >= min(max(entry.trades.count, 1), 3)
        let withBar = Int((room + gap) / (56 + gap))
        let showBar = showLevels || withBar >= 2
        let rowHeight: CGFloat = showLevels ? 86 : showBar ? 56 : 44
        let fit = max(1, Int((room + gap) / (rowHeight + gap)))
        let shown = Array(entry.trades.prefix(fit))
        return VStack(alignment: .leading, spacing: gap) {
            header(more: entry.trades.count - shown.count)
            ForEach(shown) { t in
                Link(destination: URL(string: "thirdeye://trade/\(t.id)")!) {
                    TradeBox(model: TradeBoxModel(t, hideMoney: entry.hideMoney), showBar: showBar, showLevels: showLevels)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
                        .background(card)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(glassMode ? AnyShapeStyle(Color.white.opacity(0.10)) : AnyShapeStyle(TE.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(glassMode ? Color.white.opacity(0.25) : TE.separator.opacity(0.5), lineWidth: 0.5))
    }

    // MARK: Small — total profit, count, the biggest mover

    private var small: some View {
        let open = entry.trades.filter { $0.status == "open" }
        let groups = Dictionary(grouping: open, by: \.currency)
        let best = groups.max { $0.value.count < $1.value.count }
        let list = best?.value ?? []
        let total = list.compactMap { t in t.lastPrice.flatMap { t.pnl(at: $0) } }.reduce(0, +)
        let top = entry.trades.first
        return VStack(alignment: .leading, spacing: 4) {
            header(more: 0)
            Spacer(minLength: 0)
            if let first = list.first, !entry.hideMoney {
                Text(first.money(total)).font(.system(size: 24, weight: .bold).monospacedDigit())
                    .foregroundStyle(total >= 0 ? TE.up : TE.down).lineLimit(1).minimumScaleFactor(0.5)
                Text("\(open.count) open\(groups.count > 1 ? " · \(best?.key ?? "") shown" : "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("\(open.count) open").font(.system(size: 24, weight: .bold))
            }
            Spacer(minLength: 0)
            if let top {
                let m = TradeBoxModel(top, hideMoney: entry.hideMoney)
                VStack(alignment: .leading, spacing: 2) {
                    Text(top.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(m.result ?? m.state).font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(m.moneyTone == .up ? TE.up : TE.down).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(card)
            }
        }
    }
}
