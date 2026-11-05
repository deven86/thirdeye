import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island for an open (or upcoming) trade. Updated by the PC monitor by push.
struct TradeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TradeActivityAttributes.self) { context in
            LockScreenTradeView(attributes: context.attributes, state: context.state, stale: context.isStale)
                .activityBackgroundTint(nil)   // the system's glass, light or dark with the Lock Screen
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(URL(string: "thirdeye://trade/\(context.attributes.tradeID)"))
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.symbol).font(.headline).lineLimit(1)
                        Text(a.isLong ? "LONG" : "SHORT").font(.caption2.weight(.bold)).foregroundStyle(a.isLong ? .green : .red)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(a.format(s.price)).font(.headline.monospacedDigit())
                        Text(TradeLiveText.money(a, s) ?? TradeLiveText.result(s)).font(.caption.monospacedDigit()).foregroundStyle(TradeLiveText.color(s))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        TradeProgressBar(state: s)
                        HStack {
                            Text("Stop \(a.format(s.stop))").foregroundStyle(.red)
                            Spacer()
                            if let t = s.nextTarget { Text("TP\(s.nextTargetStage ?? 0) \(a.format(t))").foregroundStyle(.green) }
                        }
                        .font(.caption2.monospacedDigit())
                        if let note = s.note { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            } compactLeading: {
                Text(String(a.symbol.prefix(4))).font(.caption2.weight(.semibold))
            } compactTrailing: {
                Text(TradeLiveText.compact(s)).font(.caption2.monospacedDigit()).foregroundStyle(TradeLiveText.color(s))
            } minimal: {
                Text(TradeLiveText.compact(s)).font(.caption2.monospacedDigit()).foregroundStyle(TradeLiveText.color(s))
            }
            .keylineTint(TradeLiveText.color(s))
        }
    }
}

struct LockScreenTradeView: View {
    let attributes: TradeActivityAttributes
    let state: TradeActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let a = attributes, s = state
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "eye").foregroundStyle(.teal)
                Text(a.symbol).font(.headline)
                Text(a.isLong ? "LONG" : "SHORT").font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((a.isLong ? Color.green : Color.red).opacity(0.25), in: Capsule())
                if a.paper { Text("PAPER").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                Spacer()
                Text(a.format(s.price)).font(.title3.weight(.semibold).monospacedDigit())
            }
            HStack {
                Text(TradeLiveText.result(s)).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(TradeLiveText.color(s))
                if let m = TradeLiveText.money(a, s) {
                    Text(m).font(.callout.weight(.bold).monospacedDigit()).foregroundStyle(TradeLiveText.color(s))
                }
                Spacer()
                Text(TradeLiveText.statusTitle(s)).font(.caption.weight(.semibold)).foregroundStyle(TradeLiveText.color(s))
            }
            TradeProgressBar(state: s)
            HStack {
                Text("Stop \(a.format(s.stop))").foregroundStyle(.red)
                Spacer()
                Text("Entry \(a.format(a.entry))").foregroundStyle(.secondary)
                Spacer()
                if let t = s.nextTarget { Text("TP\(s.nextTargetStage ?? 0) \(a.format(t))").foregroundStyle(.green) }
            }
            .font(.caption.monospacedDigit())
            HStack {
                if let note = s.note { Text(note).lineLimit(1) }
                Spacer()
                Text(stale ? "not updated since \(s.updated.formatted(date: .omitted, time: .shortened))"
                           : "updated \(s.updated.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption2)
            .foregroundStyle(stale ? .orange : .secondary)
        }
        .padding(14)
    }
}

/// Stop on the left, next target on the right, a dot where the price is.
struct TradeProgressBar: View {
    let state: TradeActivityAttributes.ContentState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = min(max(state.progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [.red.opacity(0.7), .gray.opacity(0.4), .green.opacity(0.7)],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 6)
                Circle().fill(.primary).frame(width: 12, height: 12)
                    .offset(x: max(0, min(w - 12, w * p - 6)))
            }
            .frame(height: 12)
        }
        .frame(height: 12)
    }
}

enum TradeLiveText {
    static func result(_ s: TradeActivityAttributes.ContentState) -> String {
        guard let r = s.r else { return s.note ?? "Waiting for entry" }
        let pct = s.pnlPercent.map { String(format: " · %+.2f%%", $0) } ?? ""
        return String(format: "%+.2fR", r) + pct
    }

    /// Profit in money, unless the user hid it on the Lock Screen.
    static func money(_ a: TradeActivityAttributes, _ s: TradeActivityAttributes.ContentState) -> String? {
        guard a.hideMoney != true, let p = s.pnl else { return nil }
        return a.money(p)
    }

    static func compact(_ s: TradeActivityAttributes.ContentState) -> String {
        if let r = s.r { return String(format: "%+.1fR", r) }
        return s.status == "inZone" ? "Zone" : "Wait"
    }

    static func statusTitle(_ s: TradeActivityAttributes.ContentState) -> String {
        switch s.status {
        case "stop": "STOP HIT"
        case "nearStop": "Near stop"
        case "target": "Target hit"
        case "inZone": "In entry zone"
        case "waiting": "Waiting"
        default: "Open"
        }
    }

    static func color(_ s: TradeActivityAttributes.ContentState) -> Color {
        switch s.status {
        case "stop", "nearStop": .red
        case "target": .green
        case "waiting", "inZone": .teal
        default: (s.r ?? 0) >= 0 ? .green : .red
        }
    }
}
