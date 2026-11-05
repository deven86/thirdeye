import SwiftUI
import UIKit

/// Settings → Alerts: connect the Windows PC monitor, allow notifications, test, and see recent alerts.
struct AlertsSettingsView: View {
    @Environment(MonitorStore.self) private var monitor
    @Environment(TradeStore.self) private var trades
    @Environment(MarketStore.self) private var market
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    @State private var address = ""
    @State private var code = ""
    @State private var working = false
    @State private var message: String?
    @State private var messageIsError = false

    private static let guideURL = URL(string: "https://github.com/deven86/thirdeye/blob/main/docs/ALERTS.md")!

    var body: some View {
        List {
            statusSection
            if !monitor.isPaired { pairSection }
            notificationsSection
            if monitor.isPaired { actionsSection }
            if let rows = monitor.status?.trades, !rows.isEmpty { watchingSection(rows) }
            if let alerts = monitor.status?.alerts, !alerts.isEmpty { historySection(alerts) }
        }
        .navigationTitle("Alerts")
        .task {
            if address.isEmpty { address = monitor.address }
            await monitor.refreshNotificationPermission()
            if monitor.notificationsAllowed == nil { await monitor.requestNotifications() }
            await monitor.refreshAll(trades: trades.trades, market: market)
        }
        .refreshable { await monitor.refreshAll(trades: trades.trades, market: market) }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: monitor.isPaired ? (monitor.isOnline ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") : "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(monitor.isPaired ? (monitor.isOnline ? palette.up : palette.warning) : palette.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.headline)
                    Text(subline).font(.caption).foregroundStyle(palette.textSecondary)
                }
            }
            if let s = monitor.status {
                LabeledContent("Push to this iPhone", value: s.apns == "ready" ? "Ready" : s.apns)
                ForEach(s.providers.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    LabeledContent(providerTitle(k), value: v)
                }
            }
            if let err = monitor.statusError ?? monitor.syncError {
                Text(err).font(.caption).foregroundStyle(palette.warning)
            }
        } footer: {
            Text("Your Windows PC checks prices 24×7 and sends alerts here even when Third Eye is closed: entry zone, stop-loss (as a time-sensitive alert that breaks through Focus), each take-profit, time limit, sharp moves and a 09:00 / 21:00 summary.")
        }
    }

    private var headline: String {
        guard monitor.isPaired else { return "Not connected" }
        return monitor.isOnline ? "PC monitor online" : (monitor.status == nil ? "Connecting…" : "PC monitor offline")
    }

    private var subline: String {
        guard monitor.isPaired else { return "Set up the monitor on your PC, then connect below." }
        var parts = [monitor.address]
        if let s = monitor.status {
            parts.append("watching \(s.watching)")
            if s.lastLoopAt.timeIntervalSince1970 > 0 { parts.append("last check \(s.lastLoopAt.formatted(date: .omitted, time: .shortened))") }
        }
        return parts.joined(separator: " · ")
    }

    private func providerTitle(_ key: String) -> String {
        switch key {
        case "binance": "Binance (crypto)"
        case "twelveData": "Twelve Data (US, forex, gold)"
        case "upstox": "Upstox (India)"
        default: key
        }
    }

    private var pairSection: some View {
        Section {
            TextField("PC address, e.g. my-pc.tail1234.ts.net", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("6-digit pairing code", text: $code)
                .keyboardType(.numberPad)
            Button {
                Task { await connect() }
            } label: {
                Label(working ? "Connecting…" : "Connect", systemImage: "link")
            }
            .disabled(working || MonitorStore.normalize(address).isEmpty || code.trimmingCharacters(in: .whitespaces).count != 6)
            if let message { Text(message).font(.caption).foregroundStyle(messageIsError ? palette.warning : palette.up) }
            Button("Open the step-by-step setup guide") { openURL(Self.guideURL) }
                .font(.callout)
        } header: {
            Text("Connect your PC")
        } footer: {
            Text("On the PC, `thirdeye-monitor install` (or `thirdeye-monitor pair`) shows both. Tailscale must be on, on this iPhone and the PC.")
        }
    }

    private var notificationsSection: some View {
        Section {
            switch monitor.notificationsAllowed {
            case .some(true):
                Label("Notifications allowed", systemImage: "bell.badge").foregroundStyle(palette.up)
            case .some(false):
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label("Notifications are off — open iPhone Settings", systemImage: "bell.slash")
                }
            case .none:
                Button {
                    Task { await monitor.requestNotifications() }
                } label: {
                    Label("Allow notifications", systemImage: "bell")
                }
            }
            if let err = monitor.pushRegistrationError {
                Text("This build can't receive push yet: \(err)").font(.caption).foregroundStyle(palette.warning)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("For stop-loss alerts during Focus or Sleep: iPhone Settings → Focus → (your Focus) → Apps → add Third Eye, or allow Time Sensitive notifications for it.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task {
                    working = true
                    defer { working = false }
                    do {
                        let result = try await monitor.sendTestAlert()
                        show(result.hasPrefix("sent") ? "Test alert \(result)." : "Not delivered: \(result)", error: !result.hasPrefix("sent"))
                    } catch {
                        show(error.localizedDescription, error: true)
                    }
                    await monitor.refreshStatus()
                }
            } label: {
                Label("Send a test alert", systemImage: "paperplane")
            }
            .disabled(working)
            Button {
                Task {
                    await monitor.refreshAll(trades: trades.trades, market: market)
                    show(monitor.syncError ?? "Synced \(trades.trades.filter { $0.status == .open || $0.status == .upcoming }.count) trade(s).",
                         error: monitor.syncError != nil)
                }
            } label: {
                Label("Sync trades now", systemImage: "arrow.triangle.2.circlepath")
            }
            if let message { Text(message).font(.caption).foregroundStyle(messageIsError ? palette.warning : palette.up) }
            Button("Disconnect this iPhone", role: .destructive) {
                Task { await monitor.unpair() }
            }
        }
    }

    private func watchingSection(_ rows: [MonitorStatus.TradeRow]) -> some View {
        Section("Watching") {
            ForEach(rows) { r in
                HStack {
                    Text(r.symbol).font(.callout.weight(.semibold))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(r.lastPrice.flatMap { $0 > 0 ? $0.formatted(.number.precision(.significantDigits(2...8))) : nil } ?? "—").font(.callout.monospacedDigit())
                        Text(r.marketOpen ? (r.lastCheck.flatMap { $0.timeIntervalSince1970 > 0 ? "checked \($0.formatted(date: .omitted, time: .shortened))" : nil } ?? "waiting")
                                          : "market closed")
                            .font(.caption2).foregroundStyle(palette.textSecondary)
                    }
                }
            }
        }
    }

    private func historySection(_ alerts: [MonitorAlert]) -> some View {
        Section("Recent alerts") {
            ForEach(alerts.prefix(20)) { a in
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).font(.callout.weight(.semibold))
                    Text(a.body).font(.caption).foregroundStyle(palette.textSecondary)
                    Text("\(a.at.formatted(date: .abbreviated, time: .shortened)) · \(a.delivered ?? "")")
                        .font(.caption2).foregroundStyle((a.delivered ?? "").hasPrefix("sent") ? palette.textSecondary : palette.warning)
                }
            }
        }
    }

    // MARK: Actions

    private func connect() async {
        working = true
        defer { working = false }
        do {
            try await monitor.pair(address: address, code: code)
            code = ""
            await monitor.requestNotifications()
            await monitor.refreshAll(trades: trades.trades, market: market)
            show("Connected. Now send a test alert.", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}
