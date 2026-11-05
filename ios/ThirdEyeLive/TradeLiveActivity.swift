import ActivityKit
import SwiftUI
#if canImport(ThirdEye)
@testable import ThirdEye   // design snapshot tests compile these files too
#endif
import WidgetKit

/// Lock Screen card and Dynamic Island for a trade. The Lock Screen card is the app's trade box on glass:
/// a translucent dark tint over the blurred wallpaper, white text, the same chips, profit, status, R and bar.
struct TradeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TradeActivityAttributes.self) { context in
            LockScreenTradeView(attributes: context.attributes, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.32))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "thirdeye://trade/\(context.attributes.tradeID)"))
        } dynamicIsland: { context in
            let a = context.attributes, s = context.state
            let m = TradeBoxModel(a, s)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.symbol).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        Text(a.isLong ? "LONG" : "SHORT").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(a.isLong ? TE.glassUp : TE.glassDown)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(m.money ?? m.result ?? "").font(.system(size: 14, weight: .bold).monospacedDigit())
                            .foregroundStyle(m.moneyTone == .up ? TE.glassUp : TE.glassDown).lineLimit(1).minimumScaleFactor(0.7)
                        Text(m.price ?? "").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
                        HStack(spacing: 6) {
                            Text(m.state).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(m.stateTone == .down ? TE.glassDown : m.stateTone == .accent ? TE.glassAccent : TE.glassUp)
                            Spacer(minLength: 4)
                            if let r = m.result { Text(r).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        TradeProgressBar(state: s)
                        HStack {
                            Text("Stop \(m.stop)").foregroundStyle(TE.glassDown)
                            Spacer(minLength: 4)
                            if let t = m.target { Text(t).foregroundStyle(TE.glassUp) }
                        }
                        .font(.system(size: 10.5).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Text(String(a.symbol.prefix(5))).font(.system(size: 12, weight: .semibold))
            } compactTrailing: {
                Text(TradeLiveText.compact(s)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(TradeLiveText.color(s))
            } minimal: {
                Text(TradeLiveText.compact(s)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(TradeLiveText.color(s)).minimumScaleFactor(0.6)
            }
            .keylineTint(TradeLiveText.color(s))
        }
    }
}

/// The Lock Screen card: the app's trade box on a glass pane. About 120 pt tall — inside the 160 pt iOS allows,
/// so nothing is cut at any text size.
struct LockScreenTradeView: View {
    let attributes: TradeActivityAttributes
    let state: TradeActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(TE.glassAccent)
                Text("Third Eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(stale ? "not updated since \(state.updated.formatted(date: .omitted, time: .shortened))"
                           : "updated \(state.updated.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(stale ? TE.glassWarning : .white.opacity(0.6))
            }
            TradeBox(model: TradeBoxModel(attributes, state), glass: true, showBar: true, showLevels: true, nameSize: 15)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 0.6))
                )
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// Stop on the left, next target on the right, a dot where the price is (Dynamic Island).
struct TradeProgressBar: View {
    let state: TradeActivityAttributes.ContentState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = min(max(state.progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [TE.glassDown.opacity(0.8), Color.white.opacity(0.3), TE.glassUp.opacity(0.8)],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 5)
                Circle().fill(.white).frame(width: 10, height: 10)
                    .offset(x: max(0, min(w - 10, w * p - 5)))
            }
            .frame(height: 10)
        }
        .frame(height: 10)
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
        case "stop", "nearStop": TE.glassDown
        case "target": TE.glassUp
        case "waiting", "inZone": TE.glassAccent
        default: (s.r ?? 0) >= 0 ? TE.glassUp : TE.glassDown
        }
    }
}
