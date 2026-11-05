import SwiftUI
#if canImport(ThirdEye)
@testable import ThirdEye   // design snapshot tests compile these files too
#endif
import UIKit
import WidgetKit

/// Third Eye's own colours (the app's Liquid Glass palette), light and dark.
enum TE {
    private static func c(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    static let accent = c(0x0E7C86, 0x3FB4BE)
    static let up = c(0x2E9E6B, 0x4CB782)
    static let down = c(0xD9534F, 0xE06C66)
    static let warning = c(0xB4541E, 0xE09A5B)
    static let neutral = c(0x8A94A3, 0x7D8794)
    static let background = Color(UIColor.systemGroupedBackground)
    static let surface = Color(UIColor.secondarySystemGroupedBackground)
    static let separator = Color(UIColor.separator)

    // Fixed colours for glass on the Lock Screen (always read over a dimmed, blurred wallpaper).
    static let glassUp = Color(UIColor(hex: 0x5BD08F))
    static let glassDown = Color(UIColor(hex: 0xFF7B73))
    static let glassAccent = Color(UIColor(hex: 0x5FD3DC))
    static let glassWarning = Color(UIColor(hex: 0xFFB36B))
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Everything one trade box shows — built from the widget's data or from a Live Activity.
struct TradeBoxModel {
    enum Tone { case up, down, accent, warning, neutral }
    var name: String
    var isLong: Bool
    var badge: String?
    var paper: Bool
    var price: String?
    var state: String
    var stateTone: Tone
    var money: String?
    var moneyTone: Tone
    var result: String?          // "+0.37R · +1.4%"
    var daysLeft: String?
    var progress: Double?
    var stop: String
    var entry: String
    var target: String?

    static func tone(_ state: String, pnl: Double?) -> Tone {
        switch state {
        case "STOP HIT", "Near stop": .down
        case _ where state.hasSuffix("hit"): .up
        case "In entry zone", "Waiting": .accent
        default: (pnl ?? 0) >= 0 ? .up : .down
        }
    }

    static func days(_ completeBy: Double?) -> String? {
        guard let c = completeBy else { return nil }
        let d = Calendar.current.dateComponents([.day], from: Date(), to: Date(timeIntervalSince1970: c)).day ?? 0
        return d >= 0 ? "\(d)d left" : "Overdue"
    }

    init(name: String, isLong: Bool, badge: String?, paper: Bool, price: String?, state: String, stateTone: Tone,
         money: String?, moneyTone: Tone, result: String?, daysLeft: String?, progress: Double?, stop: String,
         entry: String, target: String?) {
        self.name = name; self.isLong = isLong; self.badge = badge; self.paper = paper; self.price = price
        self.state = state; self.stateTone = stateTone; self.money = money; self.moneyTone = moneyTone
        self.result = result; self.daysLeft = daysLeft; self.progress = progress; self.stop = stop
        self.entry = entry; self.target = target
    }

    init(_ t: WidgetTrade, hideMoney: Bool) {
        let p = t.lastPrice
        let state = p.map { t.status(at: $0) } ?? "No price yet"
        let pnl = p.flatMap { t.pnl(at: $0) }
        var result: String?
        if let p, let r = t.r(at: p) {
            let pct = (t.isLong ? 1 : -1) * (p / t.entry - 1) * 100
            result = String(format: "%+.2fR · %+.1f%%", r, pct)
        }
        self.init(name: t.name, isLong: t.isLong, badge: t.badge, paper: t.paper, price: p.map { t.price($0) },
                  state: state, stateTone: Self.tone(state, pnl: pnl),
                  money: hideMoney ? nil : pnl.map { t.money($0) }, moneyTone: (pnl ?? 0) >= 0 ? .up : .down,
                  result: result, daysLeft: Self.days(t.completeBy), progress: p.map { t.progress(at: $0) },
                  stop: t.price(t.stop), entry: t.price(t.entry), target: t.nextTarget.map { "TP\(t.nextTargetStage ?? 0) " + t.price($0) })
    }

    init(_ a: TradeActivityAttributes, _ s: TradeActivityAttributes.ContentState) {
        let state = TradeLiveText.statusTitle(s)
        var result: String?
        if let r = s.r { result = String(format: "%+.2fR", r) + (s.pnlPercent.map { String(format: " · %+.1f%%", $0) } ?? "") }
        self.init(name: a.symbol, isLong: a.isLong, badge: a.badge, paper: a.paper, price: a.format(s.price),
                  state: state, stateTone: Self.tone(state == "Target hit" ? "TP hit" : state, pnl: s.pnl ?? s.r),
                  money: TradeLiveText.money(a, s), moneyTone: (s.pnl ?? s.r ?? 0) >= 0 ? .up : .down,
                  result: result ?? s.note, daysLeft: Self.days(a.completeBy), progress: s.r == nil ? nil : s.progress,
                  stop: a.format(s.stop), entry: a.format(a.entry), target: s.nextTarget.map { "TP\(s.nextTargetStage ?? 0) " + a.format($0) })
    }
}

/// The trade box from the app's Trades tab: name, chips and profit on top; price, status, R and days below;
/// then the stop → target bar. `glass` = white text on the Lock Screen's glass; otherwise the app's colours.
struct TradeBox: View {
    let model: TradeBoxModel
    var glass = false
    var showBar = true
    var showLevels = false
    var nameSize: CGFloat = 13

    private func color(_ t: TradeBoxModel.Tone) -> Color {
        switch t {
        case .up: glass ? TE.glassUp : TE.up
        case .down: glass ? TE.glassDown : TE.down
        case .accent: glass ? TE.glassAccent : TE.accent
        case .warning: glass ? TE.glassWarning : TE.warning
        case .neutral: glass ? Color.white.opacity(0.7) : TE.neutral
        }
    }

    private var primary: Color { glass ? .white : .primary }
    private var secondary: Color { glass ? .white.opacity(0.72) : .secondary }

    var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(m.name).font(.system(size: nameSize, weight: .semibold)).foregroundStyle(primary)
                    .lineLimit(1).minimumScaleFactor(0.75).layoutPriority(1)
                chip(m.isLong ? "LONG" : "SHORT", color(m.isLong ? .up : .down))
                if let b = m.badge { chip(b, color(.accent)) }
                if m.paper { chip("Paper", color(.neutral)) }
                Spacer(minLength: 4)
                if let money = m.money {
                    Text(money).font(.system(size: nameSize + 1, weight: .bold).monospacedDigit())
                        .foregroundStyle(color(m.moneyTone)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            HStack(spacing: 6) {
                if let p = m.price { Text("Now \(p)").font(.system(size: 11).monospacedDigit()).foregroundStyle(secondary).lineLimit(1) }
                Text(m.state).font(.system(size: 11, weight: .semibold)).foregroundStyle(color(m.stateTone)).lineLimit(1)
                Spacer(minLength: 4)
                if let r = m.result { Text(r).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(color(m.moneyTone)).lineLimit(1).minimumScaleFactor(0.8) }
                if let d = m.daysLeft { Text(d).font(.system(size: 11)).foregroundStyle(d == "Overdue" ? color(.warning) : secondary).lineLimit(1) }
            }
            if showBar, let p = m.progress { bar(p) }
            if showLevels {
                HStack {
                    Text("Stop \(m.stop)").foregroundStyle(color(.down))
                    Spacer(minLength: 4)
                    Text("Entry \(m.entry)").foregroundStyle(secondary)
                    Spacer(minLength: 4)
                    if let t = m.target { Text(t).foregroundStyle(color(.up)) }
                }
                .font(.system(size: 10.5).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }

    private func chip(_ text: String, _ c: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(c.opacity(glass ? 0.28 : 0.15), in: Capsule())
            .foregroundStyle(glass ? .white : c)
    }

    private func bar(_ progress: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, x = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [color(.down).opacity(0.75), secondary.opacity(0.35), color(.up).opacity(0.75)],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 4)
                Circle().fill(primary).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(glass ? Color.black.opacity(0.25) : TE.surface, lineWidth: 1))
                    .offset(x: max(0, min(w - 8, w * x - 4)))
            }
            .frame(height: 8)
        }
        .frame(height: 8)
    }
}
