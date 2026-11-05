import SwiftUI

/// Price chart with a trade's plan drawn on it: entry zone, average entry, stop (and where it started),
/// every take-profit, and arrows on the bars where you entered and exited.
struct TradeChartView: View {
    @Environment(MarketStore.self) private var market
    @Environment(\.palette) private var palette
    let instrument: Instrument
    let levels: [ChartLevel]
    let markers: [ChartMarker]
    let defaultTimeframe: Timeframe
    var height: CGFloat = 300

    @State private var timeframe: Timeframe?
    @State private var candles: [Candle] = []
    @State private var error: String?
    @State private var loading = false

    static let choices: [Timeframe] = [.m15, .h1, .d1, .w1]

    private var tf: Timeframe { timeframe ?? defaultTimeframe }

    private var precision: Int {
        if let tick = instrument.tickSize, tick > 0 { return min(max(Int(ceil(-log10(tick))), 0), 6) }
        return FeatureEngine.decimals(candles.last?.close ?? 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Chart", selection: Binding(get: { tf }, set: { timeframe = $0 })) {
                ForEach(Self.choices) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            ZStack {
                CandleChartView(candles: candles, precision: precision,
                                displayTimeZone: instrument.provider == .upstox ? TimeZone(identifier: "Asia/Kolkata")! : .current,
                                fitToken: "\(instrument.id)|\(tf.rawValue)",
                                locale: instrument.currency == "INR" ? "en-IN" : "en-US",
                                levels: levels, markers: markers)
                    .opacity(candles.isEmpty ? 0 : 1)
                if candles.isEmpty {
                    if let error {
                        Text(error).font(.caption).foregroundStyle(palette.textSecondary).multilineTextAlignment(.center).padding()
                    } else if loading {
                        ProgressView()
                    }
                }
            }
            .frame(height: height)
            legend
        }
        .task(id: tf) { await load() }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            key(palette.accent, "Entry")
            key(palette.down, "Stop")
            key(palette.up, "Targets")
            if !markers.isEmpty {
                Label("your fills", systemImage: "arrowtriangle.up.fill").font(.caption2).foregroundStyle(palette.textSecondary)
            }
        }
    }

    private func key(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 3)
            Text(text).font(.caption2).foregroundStyle(palette.textSecondary)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let c = try await market.candles(for: instrument, timeframe: tf)
            candles = c
            error = c.isEmpty ? "No \(tf.label) data for this product." : nil
        } catch {
            candles = []
            self.error = error.localizedDescription
        }
    }
}

/// What gets drawn for a trade or a plan.
enum TradeChart {
    static func levels(_ t: Trade) -> [ChartLevel] {
        var out: [ChartLevel] = []
        let s = TradeMath.summary(t, lastPrice: nil)
        if t.status == .upcoming || s.averageEntry == nil {
            out += zone(t.plannedEntryLow, t.plannedEntryHigh)
        }
        if let avg = s.averageEntry { out.append(ChartLevel(price: avg, title: "Avg entry", kind: .entry, dashed: false, width: 2)) }
        out.append(ChartLevel(price: t.stopLoss, title: t.stopLoss != t.initialStop ? "Stop (moved)" : "Stop", kind: .stop, dashed: false, width: 2))
        if t.stopLoss != t.initialStop { out.append(ChartLevel(price: t.initialStop, title: "First stop", kind: .muted)) }
        let booked = Set(t.fills.compactMap(\.takeProfitStage))
        for tp in t.takeProfits {
            guard let p = tp.price else { continue }
            out.append(ChartLevel(price: p, title: "TP\(tp.stage)\(booked.contains(tp.stage) ? " ✓" : "")",
                                  kind: booked.contains(tp.stage) ? .muted : .target))
        }
        return out
    }

    static func markers(_ t: Trade) -> [ChartMarker] {
        var out = [ChartMarker(time: t.createdAt, kind: .plan, text: "Planned", below: !t.isLong)]
        for f in t.fills.sorted(by: { $0.date < $1.date }) {
            let qty = f.quantity.formatted(.number.precision(.fractionLength(0...4)))
            if f.kind == .entry {
                out.append(ChartMarker(time: f.date, kind: .entry, text: "\(t.isLong ? "Buy" : "Sell") \(qty) @ \(FeatureEngine.plain(f.price))",
                                       below: t.isLong))
            } else {
                let loss = t.isLong ? f.price < (TradeMath.summary(t, lastPrice: nil).averageEntry ?? f.price) : f.price > (TradeMath.summary(t, lastPrice: nil).averageEntry ?? f.price)
                let label = f.takeProfitStage.map { "TP\($0)" } ?? (loss ? "Stop/exit" : "Exit")
                out.append(ChartMarker(time: f.date, kind: f.takeProfitStage == nil && loss ? .stop : .exit,
                                       text: "\(label) \(qty) @ \(FeatureEngine.plain(f.price))", below: !t.isLong))
            }
        }
        return out
    }

    static func levels(_ plan: TradePlan) -> [ChartLevel] {
        var out = zone(plan.entryLow, plan.entryHigh)
        out.append(ChartLevel(price: plan.stopLoss, title: "Stop", kind: .stop, dashed: false, width: 2))
        for tp in plan.takeProfits {
            if let p = tp.price { out.append(ChartLevel(price: p, title: "TP\(tp.stage)", kind: .target)) }
        }
        return out
    }

    private static func zone(_ lo: Double, _ hi: Double) -> [ChartLevel] {
        if abs(hi - lo) < 1e-12 { return [ChartLevel(price: lo, title: "Entry", kind: .entry)] }
        return [ChartLevel(price: hi, title: "Entry top", kind: .entry), ChartLevel(price: lo, title: "Entry low", kind: .entry)]
    }
}
