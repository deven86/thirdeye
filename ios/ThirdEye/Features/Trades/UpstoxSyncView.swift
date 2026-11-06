import SwiftUI

/// Trades → Upstox: what was added from your Upstox account, and what still needs you.
struct UpstoxSyncView: View {
    @Environment(UpstoxSync.self) private var sync
    @Environment(TradeStore.self) private var trades
    @Environment(MarketStore.self) private var market
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @State private var openTrade: UUID?
    @State private var prices = PriceBook()

    private func px(_ v: Double) -> String { "₹" + v.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_IN"))) }
    private func qty(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...4))) }
    private func name(_ id: UUID) -> String { trades.trade(id: id)?.instrument.alertName ?? "trade" }

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                HStack {
                    Image(systemName: market.upstoxLoggedIn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(market.upstoxLoggedIn ? palette.up : palette.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(market.upstoxLoggedIn ? "Upstox connected" : "Upstox not logged in").font(.headline)
                        Text(sync.lastSync.map { "Last checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not checked yet")
                            .font(.caption).foregroundStyle(palette.textSecondary)
                    }
                }
                Button {
                    Task { await sync.sync(trades: trades, market: market, settings: settings) }
                } label: {
                    Label(sync.running ? "Checking Upstox…" : "Check Upstox now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.running)
                Toggle("Add matching fills automatically", isOn: $settings.autoImportUpstox)
                if sync.removedDuplicates > 0 {
                    Label("Removed \(sync.removedDuplicates) fill\(sync.removedDuplicates == 1 ? "" : "s") that were counted twice", systemImage: "wand.and.stars")
                        .font(.caption).foregroundStyle(palette.accent)
                }
                if let e = sync.error { Text(e).font(.caption).foregroundStyle(palette.warning) }
                ForEach(sync.warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(palette.textSecondary) }
            } footer: {
                Text("Read-only: Third Eye reads your fills (today and the last 30 days), positions, holdings and stop-loss/GTT orders. It never places or changes an order. Checked every 10 minutes while the app is open.")
            }

            if !sync.lastAdded.isEmpty {
                Section("Added from Upstox") {
                    ForEach(sync.lastAdded) { m in fillRow(m.fill, detail: "\(m.replacesFill != nil ? "Linked to your recorded " : "")\(m.isEntry ? "Entry" : m.takeProfitStage.map { "Exit · TP\($0)" } ?? "Exit") → \(name(m.tradeID))") }
                }
            }

            if let plan = sync.plan {
                if !plan.matches.isEmpty {
                    Section {
                        ForEach(plan.matches) { m in fillRow(m.fill, detail: "\(m.replacesFill != nil ? "Same as your recorded " : "")\(m.isEntry ? "entry" : "exit") → \(name(m.tradeID))") }
                        Button("Add these \(plan.matches.count) fills") { sync.addMatches(trades: trades) }
                    } header: { Text("Ready to add") }
                }

                if !plan.untracked.isEmpty {
                    Section {
                        ForEach(plan.untracked) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(p.symbol) · \(p.exchange)").font(.callout.weight(.semibold))
                                Text("\(p.quantity > 0 ? "Long" : "Short") \(qty(abs(p.quantity))) @ \(px(p.averagePrice)) · \(p.source == "holding" ? "holding" : "position \(p.product ?? "")")\(p.pnl.map { " · P&L \(px($0))" } ?? "")")
                                    .font(.caption).foregroundStyle(palette.textSecondary)
                                HStack {
                                    Button("Track in Third Eye") { openTrade = sync.track(p, trades: trades, market: market) }
                                        .disabled(p.averagePrice <= 0)
                                        .buttonStyle(.borderless)
                                    Spacer()
                                    Button("Ignore", role: .destructive) { sync.ignore("pos:\(p.instrumentKey)", trades: trades) }
                                        .buttonStyle(.borderless)
                                }
                                .font(.callout)
                            }
                        }
                    } header: {
                        Text("At Upstox, not in Third Eye")
                    } footer: {
                        Text("Track it to get alerts, the trade watch and the Lock Screen card. Its stop and targets start 5% away as placeholders — set your real ones with Edit plan.")
                    }
                }

                if !plan.unmatchedFills.isEmpty {
                    Section {
                        ForEach(plan.unmatchedFills) { f in
                            HStack {
                                fillRow(f, detail: "No matching Third Eye trade")
                                Button("Ignore") { sync.ignore(f.id, trades: trades) }.buttonStyle(.borderless).font(.caption)
                            }
                        }
                    } header: {
                        Text("Fills with no trade")
                    } footer: {
                        Text("Usually a trade you closed at Upstox before tracking it, or one you track on another exchange (NSE vs BSE). Ignore it, or create the trade first and check again.")
                    }
                }

                if !plan.waiting.isEmpty {
                    Section {
                        ForEach(plan.waiting) { m in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(m.name, systemImage: "clock").font(.callout.weight(.semibold))
                                ForEach((m.orderNote ?? "").split(separator: "\n").map(String.init), id: \.self) {
                                    Text($0).font(.caption).foregroundStyle(palette.textSecondary)
                                }
                                Text("Third Eye \(qty(m.appQuantity)) · held at Upstox \(qty(m.brokerQuantity)) · waiting \(qty(abs(m.waitingQuantity)))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(palette.accent)
                            }
                        }
                    } header: {
                        Text("Orders waiting at Upstox")
                    } footer: {
                        Text("Nothing to fix. When the order fills, Third Eye takes Upstox's real price and time for the entry you recorded (it doesn't add a second one). Place the stop-loss at Upstox once it has filled.")
                    }
                }

                if !plan.mismatches.isEmpty {
                    Section {
                        ForEach(plan.mismatches) { m in
                            Button { openTrade = m.tradeID } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name).font(.callout.weight(.semibold)).foregroundStyle(palette.textPrimary)
                                    Text("Third Eye \(qty(m.appQuantity)) · Upstox \(qty(m.brokerQuantity))\(m.waitingQuantity != 0 ? " · \(qty(abs(m.waitingQuantity))) in open orders" : "")")
                                        .font(.caption.monospacedDigit()).foregroundStyle(palette.warning)
                                }
                            }
                        }
                    } header: {
                        Text("Quantity differs")
                    } footer: {
                        Text("Open the trade and correct or delete a fill. Shares you already held before this trade also count at Upstox.")
                    }
                }

                if !plan.stops.isEmpty {
                    Section {
                        ForEach(plan.stops) { s in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.name).font(.callout.weight(.semibold))
                                if s.overCovered {
                                    Label("\(s.orderCount) stop orders for \(qty(s.orderQuantity)) shares — you hold \(qty(s.held)). Keep one, cancel the rest at Upstox (Orders → GTT).",
                                          systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption.weight(.semibold)).foregroundStyle(palette.down)
                                    Text("Triggers: " + s.triggers.map(px).joined(separator: ", ") + (s.firstTrigger.map { " · \(px($0)) fires first" } ?? ""))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(palette.textSecondary)
                                }
                                if let b = s.brokerStop {
                                    let same = abs(b - s.appStop) / max(s.appStop, 1e-9) < 0.002
                                    Label(same ? "Stop at Upstox \(px(b)) (\(s.kind ?? "")) — matches"
                                               : "Upstox stop \(px(b)) (\(s.kind ?? "")) · Third Eye \(px(s.appStop))",
                                          systemImage: same ? "checkmark.shield" : "exclamationmark.shield")
                                        .font(.caption).foregroundStyle(same ? palette.up : palette.warning)
                                    if !same {
                                        Button("Use the Upstox stop in Third Eye") { sync.useBrokerStop(s, trades: trades) }
                                            .buttonStyle(.borderless).font(.callout)
                                    }
                                } else {
                                    Label("No stop-loss order at Upstox — place an SL-M or GTT at \(px(s.appStop))", systemImage: "xmark.shield")
                                        .font(.caption).foregroundStyle(palette.down)
                                }
                            }
                        }
                    } header: {
                        Text("Stop-loss at the broker")
                    }
                }

                if plan.matches.isEmpty && plan.untracked.isEmpty && plan.unmatchedFills.isEmpty && plan.mismatches.isEmpty && plan.waiting.isEmpty {
                    Section { Label("Third Eye matches your Upstox account.", systemImage: "checkmark.seal").foregroundStyle(palette.up) }
                }
            }
        }
        .navigationTitle("Upstox")
        .navigationDestination(item: $openTrade) { id in TradeDetailView(tradeID: id, prices: prices) }
        .task { if sync.plan == nil { await sync.sync(trades: trades, market: market, settings: settings) } }
        .refreshable { await sync.sync(trades: trades, market: market, settings: settings) }
    }

    private func fillRow(_ f: BrokerFill, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(f.isBuy ? "BUY" : "SELL") \(qty(f.quantity)) \(f.symbol) @ \(px(f.price))").font(.callout.weight(.semibold).monospacedDigit())
            Text("\(f.date.formatted(date: .abbreviated, time: .shortened)) · \(detail)").font(.caption).foregroundStyle(palette.textSecondary)
        }
    }
}
