import SwiftUI

struct MarketDataSettingsView: View {
    @Environment(MarketStore.self) private var market
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    @State private var upstoxKey = ""
    @State private var upstoxSecret = ""
    @State private var twelveKey = ""
    @State private var showLogin = false
    @State private var message: String?
    @State private var busy = false
    @State private var confirmRemoveUpstox = false

    var body: some View {
        Form { Group {
            upstoxSection
            twelveDataSection

            Section {
                LabeledContent("Status", value: "Ready — no key needed")
            } header: {
                Text("Crypto · Binance")
            } footer: {
                Text("Public market data from Binance (spot pairs quoted in USDT). Third Eye never trades on Binance.")
            }

            Section {
                ForEach(DataProvider.allCases, id: \.self) { provider in
                    LabeledContent(provider.displayName) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(market.counts[provider] ?? 0) products")
                            if let date = market.lastRefreshed[provider] {
                                Text("updated \(date.formatted(.relative(presentation: .named)))").font(.caption2)
                            }
                            if let error = market.providerErrors[provider] {
                                Text(error).font(.caption2).foregroundStyle(palette.warning).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                Button {
                    Task { await market.loadUniverse(force: true) }
                } label: {
                    HStack {
                        Text("Update product lists now")
                        Spacer()
                        if case .loading = market.universeState { ProgressView() }
                    }
                }
            } header: {
                Text("Product lists")
            } footer: {
                Text("Indian lists refresh every morning; global lists weekly. Lists are stored on this device only.")
            }

            if let message {
                Section { Text(message).foregroundStyle(palette.warning) }
            }
        }.skinRows()
        }
        .skinScreen()
        .navigationTitle("Market Data")
        .sheet(isPresented: $showLogin) { UpstoxLoginSheet() }
        .confirmationDialog("Remove your Upstox API key and secret from this iPhone and your iPad?",
                            isPresented: $confirmRemoveUpstox, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { market.removeUpstoxKeys() }
        }
        .onAppear { market.refreshCredentialStatus() }
    }

    private var upstoxSection: some View {
        Section {
            if market.hasUpstoxKeys {
                if market.upstoxLoggedIn, let expiry = market.upstoxTokenExpiry {
                    LabeledContent("Session", value: "Logged in\(market.upstoxUser.map { " as \($0)" } ?? "")")
                    LabeledContent("Valid until", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    Button("Log out") { market.logOutUpstox() }
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        Label("Log in to Upstox", systemImage: "person.badge.key")
                    }
                }
                Button("Remove API key", role: .destructive) { confirmRemoveUpstox = true }
            } else {
                SecureField("API Key", text: $upstoxKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                SecureField("API Secret", text: $upstoxSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Save") {
                    do {
                        try market.saveUpstoxKeys(apiKey: upstoxKey, apiSecret: upstoxSecret)
                        upstoxKey = ""
                        upstoxSecret = ""
                        message = nil
                        showLogin = true
                    } catch {
                        message = error.localizedDescription
                    }
                }
                .disabled(upstoxKey.trimmingCharacters(in: .whitespaces).isEmpty || upstoxSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Open Upstox developer apps") {
                    openURL(URL(string: "https://account.upstox.com/developer/apps")!)
                }
            }
        } header: {
            Text("India · Upstox (NSE, BSE, F&O, MCX)")
        } footer: {
            Text("Redirect URL in your Upstox app must be exactly \(UpstoxAuth.redirectURI). Upstox sessions end every morning around 3:30 AM, so you log in once per trading day. Key and secret sync to your iPad via iCloud Keychain; the daily session stays on this device.")
        }
    }

    private var twelveDataSection: some View {
        Section {
            if market.hasTwelveDataKey {
                LabeledContent("Status", value: "Connected")
                Button("Remove key", role: .destructive) { market.removeTwelveDataKey() }
            } else {
                SecureField("API Key", text: $twelveKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await market.saveTwelveDataKey(twelveKey)
                            twelveKey = ""
                            message = nil
                            await market.loadUniverse(force: true)
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        Text("Test & save")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(twelveKey.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                Button("Get a free key") { openURL(URL(string: "https://twelvedata.com/register")!) }
            }
        } header: {
            Text("US stocks · Forex · Gold · Twelve Data")
        } footer: {
            Text("Free plan: 800 requests a day, 8 a minute — charts for these refresh about once a minute.")
        }
    }
}
