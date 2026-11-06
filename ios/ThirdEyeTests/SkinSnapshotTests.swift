import SwiftUI
import Testing
import UIKit
@testable import ThirdEye

/// Renders a skinned list screen and a skinned card screen in a real window (Lists and glass don't draw in
/// ImageRenderer) and prints them as "SNAPSHOT <name>" pieces for the CI log.
@MainActor
@Suite("Skin design snapshots")
struct SkinSnapshotTests {
    private func emit(_ name: String, _ view: some View) async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("no window scene"); return
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        try? await Task.sleep(for: .milliseconds(1200))
        let img = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        guard let png = img.pngData() else { Issue.record("no png"); return }
        let b64 = png.base64EncodedString()
        let pieces = stride(from: 0, to: b64.count, by: 16_000).map { i -> String in
            let start = b64.index(b64.startIndex, offsetBy: i)
            return String(b64[start..<(b64.index(start, offsetBy: 16_000, limitedBy: b64.endIndex) ?? b64.endIndex)])
        }
        for (i, piece) in pieces.enumerated() { print("SNAPSHOT \(name)-p\(i)of\(pieces.count) \(piece)") }
    }

    private func settings(_ skin: Skin) -> AppSettings {
        let s = AppSettings(defaults: UserDefaults(suiteName: "skin-test-\(skin.rawValue)")!)
        s.skin = skin
        s.skinDim = 0.25
        return s
    }

    private struct SampleList: View {
        @Environment(\.palette) private var palette
        var body: some View {
            NavigationStack {
                List { Group {
                    Section("Open trades") {
                        ForEach(["TRENT (NSE)", "JSWSTEEL (BSE)", "RELIANCE (NSE)"], id: \.self) { n in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(n).font(.headline)
                                    Text("Now 3,041.20 · Open").font(.caption).foregroundStyle(palette.textSecondary)
                                }
                                Spacer()
                                Text("+₹11.90").font(.headline.monospacedDigit()).foregroundStyle(palette.up)
                            }
                        }
                    }
                    Section("Settings") {
                        Toggle("Add matching fills automatically", isOn: .constant(true))
                        LabeledContent("Skin", value: "Aurora")
                    }
                }.skinRows()
                }
                .skinScreen()
                .navigationTitle("Trades")
            }
        }
    }

    private struct SampleCards: View {
        @Environment(\.palette) private var palette
        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(0..<3) { i in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Market score").font(.caption).foregroundStyle(palette.textSecondary)
                                Text("\(712 + i * 41) / 1000").font(.title.bold().monospacedDigit())
                                Text("Trend up · volume rising").font(.callout)
                            }
                            .dataCard()
                        }
                        AdaptiveButton(title: "Find hot trades", systemImage: "flame") {}
                    }
                    .padding()
                }
                .skinScreen()
                .navigationTitle("Home")
            }
        }
    }

    private struct SampleTradeRows: View {
        var body: some View {
            let names: [(String, String, String, Double)] = [("TRENT", "NSE_EQ", "INR", 3029.3), ("GBP/USD", "FX", "USD", 1.2745), ("TAO/USDT", "SPOT", "USDT", 412.5)]
            let trades: [Trade] = names.enumerated().map { i, n in
                let inst = Instrument(id: "k\(i)", provider: i == 0 ? .upstox : .binance, symbol: n.0, name: n.0, exchange: i == 0 ? "NSE" : "Binance",
                                      segment: n.1, kind: i == 0 ? .equity : .crypto, currency: n.2)
                var t = Trade(instrument: inst, mode: i == 0 ? .real : .paper, side: i == 2 ? "short" : "long", status: .open,
                              plannedEntryLow: n.3 * 0.998, plannedEntryHigh: n.3 * 1.002, stopLoss: n.3 * 0.95, initialStop: n.3 * 0.95,
                              takeProfits: (1...3).map { TakeProfit(stage: $0, price: n.3 * (1 + 0.05 * Double($0)), rMultiple: Double($0), bookPercent: 30, then: "") },
                              plannedQuantity: i == 0 ? 1 : 1000, badge: i == 1 ? .shortTerm : .swing, completeBy: Date().addingTimeInterval(29 * 86_400))
                t.fills.append(Fill(kind: .entry, date: Date(), price: n.3, quantity: i == 0 ? 1 : 1000))
                return t
            }
            return NavigationStack {
                List { Group {
                    Section { ForEach(trades) { t in TradeRow(trade: t, price: t.plannedEntryMid * 1.0164) } }
                }.skinRows()
                }
                .skinScreen()
                .navigationTitle("Trades")
            }
        }
    }

    @Test func tradeRowsOnPhotoLikeSkin() async {
        let s = settings(.sunset)
        s.colorBlindSafe = true
        await emit("skin-traderows", ThemeHost { SampleTradeRows() }.environment(s))
        s.skin = .none
        await emit("plain-traderows", ThemeHost { SampleTradeRows() }.environment(s))
    }

    @Test func skins() async {
        for (name, skin) in [("aurora", Skin.aurora), ("sunset", .sunset), ("classic", .classic)] {
            let s = settings(skin)
            await emit("skin-\(name)-list", ThemeHost { SampleList() }.environment(s))
        }
        let s = settings(.ocean)
        await emit("skin-ocean-cards", ThemeHost { SampleCards() }.environment(s))
    }
}
