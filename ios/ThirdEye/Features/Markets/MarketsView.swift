import SwiftUI

struct MarketsView: View {
    @Environment(MarketStore.self) private var market
    @Environment(\.palette) private var palette
    @State private var query = ""
    @State private var filter: InstrumentIndex.Filter = .all
    @State private var results: [Instrument] = []

    var body: some View {
        List { Group {
            if query.isEmpty {
                Section {
                    ForEach(market.watchlist) { instrument in
                        NavigationLink(value: instrument) { InstrumentRow(instrument: instrument) }
                    }
                    .onDelete { offsets in
                        let removed = offsets.map { market.watchlist[$0] }
                        removed.forEach { market.toggleWatch($0) }
                    }
                } header: {
                    Text("Watchlist")
                } footer: {
                    Text("Search above to find any product. Swipe left to remove.")
                }
                Section("Data sources") {
                    SourceStatusRow()
                }
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            } else {
                Section("\(results.count) results") {
                    ForEach(results) { instrument in
                        NavigationLink(value: instrument) { InstrumentRow(instrument: instrument) }
                    }
                }
            }
        }.skinRows()
        }
        .skinScreen()
        .navigationTitle("Markets")
        .navigationDestination(for: Instrument.self) { InstrumentDetailView(instrument: $0) }
        .searchable(text: $query, prompt: "Stock, index, F&O, forex, crypto…")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !query.isEmpty { FilterBar(selection: $filter) }
        }
        .task(id: "\(query)|\(filter.rawValue)|\(market.index.count)") {
            let q = query
            let index = market.index
            let f = filter
            try? await Task.sleep(for: .milliseconds(120)) // debounce typing
            guard !Task.isCancelled else { return }
            results = await Task.detached(priority: .userInitiated) { index.search(q, filter: f) }.value
        }
        .task { await market.loadUniverse() }
        .refreshable { await market.loadUniverse(force: true) }
    }
}

private struct FilterBar: View {
    @Binding var selection: InstrumentIndex.Filter
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(InstrumentIndex.Filter.allCases) { f in
                        Button {
                            selection = f
                        } label: {
                            Text(f.title)
                                .font(.subheadline.weight(selection == f ? .semibold : .regular))
                                .foregroundStyle(selection == f ? palette.accent : palette.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .floatingGlass(in: Capsule(), tint: selection == f ? palette.accent : nil, interactive: true)
                        .accessibilityAddTraits(selection == f ? .isSelected : [])
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }
}

struct InstrumentRow: View {
    @Environment(\.palette) private var palette
    let instrument: Instrument

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instrument.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(instrument.subtitle)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Chip(text: instrument.exchangeBadge, color: palette.textSecondary)
            KindBadge(kind: instrument.kind)
        }
        .accessibilityElement(children: .combine)
    }
}

struct KindBadge: View {
    @Environment(\.palette) private var palette
    let kind: AssetKind

    var body: some View {
        Text(kind.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(palette.accent.opacity(0.12), in: Capsule())
            .foregroundStyle(palette.accent)
    }
}

private struct SourceStatusRow: View {
    @Environment(MarketStore.self) private var market
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationLink {
            MarketDataSettingsView()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                status("India (Upstox)", ok: market.upstoxLoggedIn,
                       detail: market.upstoxLoggedIn ? "Connected" : (market.hasUpstoxKeys ? "Log in needed today" : "Not set up"))
                status("US · Forex · Gold (Twelve Data)", ok: market.hasTwelveDataKey,
                       detail: market.hasTwelveDataKey ? "Connected" : "Not set up")
                status("Crypto (Binance)", ok: true, detail: "Ready — no key needed")
                if case .loading(let message) = market.universeState {
                    Label(message, systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func status(_ title: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? palette.up : palette.neutral)
            Text(title)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(palette.textSecondary)
        }
    }
}
