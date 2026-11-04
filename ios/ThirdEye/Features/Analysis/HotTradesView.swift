import SwiftUI

struct HotTradesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MarketStore.self) private var market
    @Environment(AnalysisStore.self) private var analyses
    @Environment(HotScanStore.self) private var scans
    @Environment(\.palette) private var palette
    @State private var engine = HotTradesEngine()
    @State private var confirm = false

    private var estimate: String { String(format: "%.2f", HotTradesEngine.estimate(settings: settings)) }

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
                Picker("Full analyses", selection: $settings.hotCandidates) {
                    Text("Top 3").tag(3)
                    Text("Top 5").tag(5)
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
                Text("1) Code screens the list on its charts (free) and drops new listings and pegged coins. 2) A fast AI model shortlists \(settings.hotCandidates). 3) Each gets the full 10-stage analysis and every check. Estimated ≈ $\(estimate) per scan. HOT = passed every check; WATCH = leans clearly one way but failed a check.")
            }

            if engine.phase != .idle { progressSection }

            if let scan = engine.phase == .idle ? scans.scans.first : engine.scan, !scan.picks.isEmpty {
                resultSection(scan)
                contextSection(scan)
            }

            if scans.scans.count > 1 {
                Section("Earlier scans") {
                    ForEach(scans.scans.dropFirst().prefix(10)) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.market.title).font(.callout)
                                Text("\(s.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(s.hotTrades.count) hot · \(s.watchList.count) watch · $\(String(format: "%.2f", s.costUSD))")
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
        .confirmationDialog("Run a hot-trades scan on \(settings.hotMarket.title)? \(settings.hotCandidates) full analyses, estimated cost ≈ $\(estimate), charged to your AI account. Takes about \(settings.hotCandidates * 2)–\(settings.hotCandidates * 3) minutes — keep the app open.",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Run scan") {
                engine.start(market: settings.hotMarket, profile: settings.hotProfile, candidates: settings.hotCandidates,
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
        case .shortlisting: "AI is shortlisting candidates…"
        case .analysing(let i, let total, let symbol): "Full analysis \(i) of \(total): \(symbol)"
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
                    Text(scan.watchList.isEmpty
                         ? "The strongest candidates were analysed in full and none passed every check. Waiting is a valid decision — run again later or try another market."
                         : "None passed every check. \(scan.watchList.count) \(scan.watchList.count == 1 ? "leans" : "lean") clearly one way — they are on WATCH with the levels that would strengthen the case.")
                        .font(.callout).foregroundStyle(palette.textSecondary)
                }
            }
            ForEach(scan.ranked, id: \.instrument.id) { pick in
                let run = pick.runID.flatMap { id in analyses.runs.first { $0.id == id } }
                Group {
                    if let run {
                        NavigationLink { AnalysisReportView(run: run).navigationTitle(run.instrument.symbol) } label: { pickRow(pick, run: run) }
                    } else {
                        pickRow(pick, run: nil)
                    }
                }
            }
        } header: {
            Text("\(scan.market.title) · \(scan.profile.title)")
        } footer: {
            Text("Screened \(scan.screened.count) products\(scan.skipped.isEmpty ? "" : ", skipped \(scan.skipped.count)") · cost $\(String(format: "%.2f", scan.costUSD)) · \(scan.startedAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    @ViewBuilder
    private func contextSection(_ scan: HotScan) -> some View {
        if scan.regime != nil || scan.shortlistNote != nil || !scan.skipped.isEmpty || !scan.screened.isEmpty {
            Section("Scan details") {
                if let regime = scan.regime {
                    Label(regime, systemImage: "globe").font(.caption).foregroundStyle(palette.textSecondary)
                }
                if let note = scan.shortlistNote {
                    Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(palette.warning)
                }
                if !scan.screened.isEmpty {
                    DisclosureGroup("Chart screen — top \(min(scan.screened.count, 15)) of \(scan.screened.count)") {
                        ForEach(Array(scan.screened.prefix(15).enumerated()), id: \.element.id) { i, row in
                            HStack(spacing: 8) {
                                Text("\(i + 1).").font(.caption2.monospacedDigit()).foregroundStyle(palette.textSecondary).frame(width: 22, alignment: .trailing)
                                Image(systemName: row.direction == "long" ? "arrow.up.right" : "arrow.down.right")
                                    .font(.caption2).foregroundStyle(row.direction == "long" ? palette.up : palette.down)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.instrument.symbol).font(.caption.weight(.semibold))
                                    if let t = row.trend { Text(t).font(.caption2).foregroundStyle(palette.textSecondary) }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(String(format: "%.0f", row.codeScore)).font(.caption.monospacedDigit())
                                    if let rs = row.relativeStrength {
                                        Text(String(format: "RS %+.1f", rs)).font(.caption2.monospacedDigit())
                                            .foregroundStyle(rs >= 0 ? palette.up : palette.down)
                                    }
                                }
                            }
                        }
                        Text("Chart score ranks clean, liquid candidates for the AI — it is not a forecast. RS = 20-day return vs the list's median.")
                            .font(.caption2).foregroundStyle(palette.textSecondary)
                    }
                    .font(.caption)
                }
                if !scan.skipped.isEmpty {
                    DisclosureGroup("Skipped (\(scan.skipped.count))") {
                        ForEach(scan.skipped, id: \.self) { Text($0).font(.caption2).foregroundStyle(palette.textSecondary) }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func pickRow(_ pick: HotPick, run: AnalysisRun?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(pick.composite.map(String.init) ?? "…")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(pick.composite.map { palette.color(forComposite: $0) } ?? palette.neutral)
                .frame(minWidth: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pick.instrument.symbol).font(.callout.weight(.semibold))
                    statusChip(pick)
                    if let v = pick.verdict.flatMap(Verdict.init(rawValue:)), pick.status == .hot {
                        Text(v.title).font(.caption).foregroundStyle(palette.textSecondary)
                    }
                }
                if !pick.reason.isEmpty {
                    Text(pick.reason).font(.caption).foregroundStyle(palette.textSecondary).lineLimit(3)
                }
                if let error = pick.error {
                    Text(error).font(.caption2).foregroundStyle(palette.warning).lineLimit(3)
                } else if pick.status == .hot, let grade = pick.grade {
                    Text("Grade \(grade) · passed every check").font(.caption2).foregroundStyle(palette.up)
                } else if let blocker = pick.blocker {
                    Text(blocker).font(.caption2).foregroundStyle(palette.textSecondary).lineLimit(3)
                }
                if pick.status == .watch, let level = run?.watchLevels?.first {
                    Text(level).font(.caption2).foregroundStyle(palette.accent).lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func statusChip(_ pick: HotPick) -> some View {
        switch pick.status {
        case .hot:
            Chip(text: pick.grade.map { "HOT · \($0)" } ?? "HOT", color: palette.up)
        case .watch:
            Chip(text: pick.lean == "short" ? "WATCH ↓" : "WATCH ↑", color: palette.accent)
        case .wait:
            Chip(text: "WAIT", color: palette.neutral)
        case .failed:
            Chip(text: "FAILED", color: palette.warning)
        case .pending:
            EmptyView()
        }
    }
}
