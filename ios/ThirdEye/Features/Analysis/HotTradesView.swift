import SwiftUI

struct HotTradesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MarketStore.self) private var market
    @Environment(AnalysisStore.self) private var analyses
    @Environment(HotScanStore.self) private var scans
    @Environment(\.palette) private var palette
    @State private var engine = HotTradesEngine()
    @State private var confirm = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Picker("Market", selection: $settings.hotMarket) {
                    ForEach(HotMarket.allCases) { Text($0.title).tag($0) }
                }
                Picker("Holding style", selection: $settings.hotProfile) {
                    ForEach(HoldingProfile.allCases.filter { $0 != .equal }) { Text($0.title).tag($0) }
                }
                if let needs = settings.hotMarket.needs { Text(needs).font(.caption).foregroundStyle(palette.textSecondary) }
                Button {
                    confirm = true
                } label: {
                    Label(engine.isRunning ? "Scanning…" : "Find hot trades", systemImage: "flame")
                        .font(.body.weight(.semibold))
                }
                .disabled(engine.isRunning || !AnalysisEngine.blockers(settings: settings).isEmpty)
                if engine.isRunning {
                    Button("Stop", role: .destructive) { engine.cancel() }
                }
            } footer: {
                Text("1) Code screens the whole list on its charts (free). 2) A fast AI model shortlists 3. 3) Each gets the full 10-stage analysis. Estimated ≈ $\(String(format: "%.2f", HotTradesEngine.estimate(settings: settings))) per scan. Only results that pass every check are shown as hot trades.")
            }

            if engine.phase != .idle { progressSection }

            if let scan = engine.phase == .idle ? scans.scans.first : engine.scan, !scan.picks.isEmpty {
                resultSection(scan)
            }

            if scans.scans.count > 1 {
                Section("Earlier scans") {
                    ForEach(scans.scans.dropFirst().prefix(10)) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.market.title).font(.callout)
                                Text("\(s.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(s.hotTrades.count) hot · $\(String(format: "%.2f", s.costUSD))")
                                    .font(.caption).foregroundStyle(palette.textSecondary)
                            }
                            Spacer()
                            Text(s.hotTrades.map(\.instrument.symbol).joined(separator: ", ")).font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Hot trades")
        .confirmationDialog("Run a hot-trades scan on \(settings.hotMarket.title)? Estimated cost ≈ $\(String(format: "%.2f", HotTradesEngine.estimate(settings: settings))), charged to your AI account. Takes about 5–10 minutes.",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Run scan") {
                engine.start(market: settings.hotMarket, profile: settings.hotProfile,
                             context: .init(market: market, settings: settings, store: analyses), store: scans)
            }
        }
    }

    private var progressSection: some View {
        Section("Progress") {
            HStack(spacing: 12) {
                switch engine.phase {
                case .failed: Image(systemName: "xmark.octagon").foregroundStyle(palette.down)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.up)
                default: ProgressView()
                }
                Text(progressText)
            }
            if case .analysing = engine.phase {
                ForEach(StageSpec.all) { spec in
                    let status = engine.analysis.stageStatus[spec.id] ?? .pending
                    HStack {
                        Image(systemName: status == .done ? "checkmark.circle.fill" : status == .unavailable ? "exclamationmark.circle" : "circle")
                            .foregroundStyle(status == .done ? palette.up : status == .unavailable ? palette.warning : palette.neutral)
                        Text("\(spec.id). \(spec.name)").font(.caption)
                        if status == .running { ProgressView().controlSize(.mini) }
                    }
                }
            }
        }
    }

    private var progressText: String {
        switch engine.phase {
        case .idle: ""
        case .screening(let done, let total): "Screening charts \(done + 1) of \(total)…"
        case .shortlisting: "AI is shortlisting 3 candidates…"
        case .analysing(let i, let symbol): "Full analysis \(i) of 3: \(symbol)"
        case .done: "Scan complete"
        case .failed(let message): message
        }
    }

    private func resultSection(_ scan: HotScan) -> some View {
        Section {
            let hot = scan.hotTrades
            if scan.finishedAt != nil && hot.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No hot trades right now").font(.headline)
                    Text("The three strongest candidates were analysed in full and none passed every check. Waiting is a valid decision — run again later or try another market.")
                        .font(.callout).foregroundStyle(palette.textSecondary)
                }
            }
            ForEach(scan.picks, id: \.instrument.id) { pick in
                let run = pick.runID.flatMap { id in analyses.runs.first { $0.id == id } }
                let isHot = hot.contains { $0.instrument.id == pick.instrument.id }
                Group {
                    if let run {
                        NavigationLink { AnalysisReportView(run: run).navigationTitle(run.instrument.symbol) } label: { pickRow(pick, isHot: isHot) }
                    } else {
                        pickRow(pick, isHot: false)
                    }
                }
            }
        } header: {
            Text("\(scan.market.title) · \(scan.profile.title)")
        } footer: {
            Text("Screened \(scan.screened.count) products\(scan.skipped.isEmpty ? "" : ", skipped \(scan.skipped.count)") · cost $\(String(format: "%.2f", scan.costUSD)) · \(scan.startedAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    private func pickRow(_ pick: HotPick, isHot: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(pick.composite.map(String.init) ?? "…")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(pick.composite.map { palette.color(forComposite: $0) } ?? palette.neutral)
                .frame(minWidth: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(pick.instrument.symbol).font(.callout.weight(.semibold))
                    if isHot { Chip(text: "HOT", color: palette.up) }
                    if let v = pick.verdict.flatMap(Verdict.init(rawValue:)) { Text(v.title).font(.caption).foregroundStyle(palette.textSecondary) }
                }
                Text(pick.reason).font(.caption).foregroundStyle(palette.textSecondary).lineLimit(3)
            }
        }
    }
}
