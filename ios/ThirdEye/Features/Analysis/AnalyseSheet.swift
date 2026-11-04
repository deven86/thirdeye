import SwiftUI

/// Choose holding profile → see cost → run → watch stages → report.
struct AnalyseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(AppSettings.self) private var settings
    @Environment(MarketStore.self) private var market
    @Environment(AnalysisStore.self) private var store
    let instrument: Instrument

    @State private var profile: HoldingProfile = .swing
    @State private var engine = AnalysisEngine()

    var body: some View {
        NavigationStack {
            Group {
                switch engine.phase {
                case .idle:
                    setup
                case .done:
                    if let run = engine.run { AnalysisReportView(run: run) }
                default:
                    AnalysisProgressView(engine: engine)
                }
            }
            .navigationTitle(instrument.symbol)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(engine.isRunning ? "Stop" : "Close") {
                        if engine.isRunning { engine.cancel() } else { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(engine.isRunning)
    }

    private var setup: some View {
        let blockers = AnalysisEngine.blockers(settings: settings)
        let estimate = AnalysisEngine.estimate(settings: settings)
        return Form {
            if !blockers.isEmpty {
                Section {
                    ForEach(blockers, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(palette.warning) }
                }
            }
            Section {
                ForEach(HoldingProfile.allCases) { p in
                    Button {
                        profile = p
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).foregroundStyle(palette.textPrimary)
                                Text(p.subtitle).font(.caption).foregroundStyle(palette.textSecondary)
                            }
                            Spacer()
                            if p == profile { Image(systemName: "checkmark").foregroundStyle(palette.accent) }
                        }
                    }
                    .accessibilityAddTraits(p == profile ? .isSelected : [])
                }
            } header: {
                Text("How long would you hold?")
            } footer: {
                Text("This sets how much each of the 10 stages counts. Short holds weight today's chart; long holds weight history, leadership and the sector.")
            }

            Section("What happens") {
                ForEach(StageSpec.all) { s in
                    HStack {
                        Text("\(s.id)").font(.caption.monospacedDigit()).foregroundStyle(palette.textSecondary).frame(width: 20)
                        Text(s.name)
                        Spacer()
                        Text(s.tier.title).font(.caption).foregroundStyle(palette.accent)
                        if s.webSearch { Image(systemName: "globe").font(.caption).foregroundStyle(palette.textSecondary) }
                    }
                }
            }

            Section {
                LabeledContent("Estimated cost", value: "≈ $\(String(format: "%.2f", estimate))")
                LabeledContent("Spent this month", value: "$\(String(format: "%.2f", store.monthToDateCost))")
                LabeledContent("Mode", value: settings.paperMode ? "Paper — no real money" : "Real money")
            } footer: {
                Text("Charged to your own AI account. Takes about 1–3 minutes. Scores are an analytical aid, not advice.")
            }

            Section {
                Button {
                    engine.start(instrument: instrument, profile: profile,
                                 context: .init(market: market, settings: settings, store: store))
                } label: {
                    Label("Run 10-stage analysis", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .font(.body.weight(.semibold))
                }
                .disabled(!blockers.isEmpty)
            }
        }
    }
}

struct AnalysisProgressView: View {
    @Environment(\.palette) private var palette
    let engine: AnalysisEngine

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    if case .failed = engine.phase {
                        Image(systemName: "xmark.octagon").foregroundStyle(palette.down)
                    } else {
                        ProgressView()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phaseText).font(.headline)
                        Text("Cost so far $\(String(format: "%.3f", engine.runningCost))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
            Section("Stages") {
                ForEach(StageSpec.all) { spec in
                    let status = engine.stageStatus[spec.id] ?? .pending
                    let result = engine.run?.stages.first { $0.stage == spec.id }
                    HStack(spacing: 12) {
                        statusIcon(status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(spec.id). \(spec.name)")
                            if let result, result.status == .done {
                                Text(result.summary).font(.caption).foregroundStyle(palette.textSecondary).lineLimit(2)
                            } else if let result, result.status == .unavailable {
                                Text(result.summary).font(.caption).foregroundStyle(palette.warning).lineLimit(2)
                            }
                        }
                        Spacer()
                        if let result, result.status == .done {
                            Text("\(result.score)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(result.score >= 56 ? palette.up : result.score <= 44 ? palette.down : palette.neutral)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: status)
                }
            }
        }
    }

    private var phaseText: String {
        switch engine.phase {
        case .idle: "Ready"
        case .fetchingData: "Fetching charts and computing technicals…"
        case .runningStages: "Running stages 1–9…"
        case .finalStage: "Stage 10: final verdict and plan…"
        case .verifying: "Checking the plan…"
        case .done: "Done"
        case .failed(let message): message
        }
    }

    @ViewBuilder
    private func statusIcon(_ s: StageStatus) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(palette.neutral)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.up)
        case .unavailable: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(palette.warning)
        }
    }
}
