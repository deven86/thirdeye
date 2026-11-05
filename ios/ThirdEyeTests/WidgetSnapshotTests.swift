import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import ThirdEye

/// Renders the Home Screen widget at every size and the Lock Screen card, and prints each as base64 PNG
/// ("SNAPSHOT <name> <data>") so the design can be checked from the CI log. Also asserts nothing overflows.
@MainActor
@Suite("Widget design snapshots")
struct WidgetSnapshotTests {
    private func trade(_ i: Int) -> WidgetTrade {
        let names = ["TRENT (NSE)", "JSWSTEEL (NSE)", "NZD/USD", "BTC/USDT", "RELIANCE (NSE)", "XAU/USD", "TAO/USDT", "ADA/USDT", "INFY (BSE)"]
        let long = i % 3 != 2
        let entry = 100.0 + Double(i) * 10
        let stop = long ? entry * 0.96 : entry * 1.04
        let price = entry * (long ? 1.012 + Double(i % 4) * 0.004 : 0.993)
        return WidgetTrade(id: "\(i)", name: names[i % names.count], side: long ? "long" : "short", status: i == 8 ? "upcoming" : "open",
                           entry: entry, entryLow: entry * 0.995, entryHigh: entry * 1.005, stop: stop, initialStop: stop,
                           nextTarget: long ? entry * 1.04 : entry * 0.96, nextTargetStage: 1, openUnits: 25, realized: 0,
                           currency: i % 3 == 0 ? "INR" : "USD", decimals: 2, paper: i % 2 == 0, lastPrice: price,
                           lastPriceAt: Date().timeIntervalSince1970, badge: "Swing", completeBy: Date().addingTimeInterval(9 * 86_400).timeIntervalSince1970)
    }

    private func emit(_ name: String, _ view: some View, size: CGSize) {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        r.scale = 2
        guard let png = r.uiImage?.pngData() else { Issue.record("no image for \(name)"); return }
        print("SNAPSHOT \(name) \(png.base64EncodedString())")
    }

    @Test func homeScreenWidgetAllSizes() {
        let entry = TradesEntry(date: Date(), trades: (0..<9).map(trade), hideMoney: false, fresh: true, empty: false)
        // iPhone widget sizes (6.1–6.3"), minus the system's 16 pt content margins.
        let sizes: [(String, WidgetFamily, CGSize)] = [
            ("small", .systemSmall, CGSize(width: 170, height: 170)),
            ("medium", .systemMedium, CGSize(width: 364, height: 170)),
            ("large", .systemLarge, CGSize(width: 364, height: 382)),
            ("large-se", .systemLarge, CGSize(width: 338, height: 354)),   // smallest iPhone
        ]
        for (name, family, size) in sizes {
            let content = TradesWidgetView(entry: entry, familyOverride: family)
                .frame(width: size.width - 32, height: size.height - 32)
                .clipped()
                .padding(16)
                .background(TE.background)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            emit("widget-\(name)", content, size: size)
        }
    }

    @Test func lockScreenCardFitsAndRenders() {
        let a = TradeActivityAttributes(tradeID: "1", symbol: "TRENT (NSE)", side: "long", entry: 3055, currency: "INR", decimals: 2,
                                        paper: true, badge: "Swing", completeBy: Date().addingTimeInterval(14 * 86_400).timeIntervalSince1970,
                                        initialStop: 2940)
        let s = TradeActivityAttributes.ContentState(price: 3098.5, r: 0.38, pnlPercent: 1.42, pnl: 435, stop: 2940, nextTarget: 3135,
                                                     nextTargetStage: 1, progress: 0.8, status: "open", note: nil,
                                                     updatedAt: Date().timeIntervalSince1970)
        let card = LockScreenTradeView(attributes: a, state: s, stale: false)
            .frame(width: 361)
            .fixedSize(horizontal: false, vertical: true)
        let r = ImageRenderer(content: card)
        let height = r.uiImage.map { $0.size.height } ?? 0
        print("SNAPSHOT-HEIGHT lock \(height)")
        #expect(height > 0 && height <= 160, "iOS cuts Lock Screen cards taller than 160 pt")
        let wallpaper = LinearGradient(colors: [Color(red: 0.2, green: 0.35, blue: 0.6), Color(red: 0.75, green: 0.5, blue: 0.4)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
        let shown = card.background(Color.black.opacity(0.32)).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(16).background(wallpaper)
        emit("lockscreen", shown, size: CGSize(width: 393, height: height + 32))
    }
}
