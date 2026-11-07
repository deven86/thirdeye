import SwiftUI

// Extra Search screens (0.15.0). Every view here is shown only when Settings → Extra Search is on.

// MARK: - Settings

struct ExtraSearchSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ExtraSearchStore.self) private var extras

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.extraSearchEnabled.animation()) {
                Label("Extra Search", systemImage: "binoculars")
            }
            if settings.extraSearchEnabled {
                Picker(selection: $settings.extraSuggestPercent) {
                    Text("Never").tag(0.0)
                    Text("5% of capital").tag(5.0)
                    Text("10% of capital").tag(10.0)
                    Text("20% of capital").tag(20.0)
                    Text("30% of capital").tag(30.0)
                } label: {
                    Label("Suggest it for trades above", systemImage: "exclamationmark.bubble")
                }
                Toggle(isOn: $settings.extraConflictWarnings) {
                    Label("Warn when stages disagree", systemImage: "arrow.left.arrow.right")
                }
                Toggle(isOn: $settings.extraVIXSizing) {
                    Label("India VIX size advice", systemImage: "gauge.with.dots.needle.33percent")
                }
                if extras.monthToDateCost > 0 {
                    LabeledContent("Spent this month", value: String(format: "$%.2f", extras.monthToDateCost))
                }
            }
        } header: {
            Text("Extra Search")
        } footer: {
            Text(settings.extraSearchEnabled
                 ? "An “Extra Search” button appears on every analysis: a bull analyst and a bear analyst argue the case, then a judge (your Deep model) weighs them with the stage disagreements and this product's track record. It reads the analysis and never changes it. About 3 AI calls per search. Turn this off at any time to go back to the normal app."
                 : "Off — Third Eye works exactly as before. Turn on for a second opinion before big trades.")
        }
    }
}

// MARK: - Card on the analysis report

struct ExtraSearchCard: View {
    @Environment(\.palette) private var palette
    @Environment(AppSettings.self) private var settings
    @Environment(ExtraSearchStore.self) private var extras
    @Environment(AnalysisStore.self) private var analyses
    @Environment(OutcomeStore.self) private var outcomes
    let run: AnalysisRun
    @State private var engine = ExtraSearchEngine()
    @State private var showResult: ExtraSearchResult?
    @State private var confirm = false

    private var conflicts: [ExtraConflicts.Conflict] { ExtraConflicts.conflicts(run.stages, profile: run.profile) }
    private var saved: ExtraSearchResult? { extras.latest(for: run.id) }

    /// Planned position as a share of capital, using the app's own sizing (capital × risk ÷ stop distance).
    private var positionShare: Double? {
        guard let plan = run.plan, let capital = settings.capital[run.instrument.currency], capital > 0 else { return nil }
        let i = run.instrument
        let q = TradeMath.positionSize(capital: capital, riskPercent: settings.riskPercent, entry: plan.entryMid,
                                       stop: plan.stopLoss, lotSize: i.lotSize, contractSize: i.contractSize)
        guard q > 0 else { return nil }
        return q * plan.entryMid * i.contractSize / capital * 100
    }

    private var isBigTrade: Bool {
        guard settings.extraSuggestPercent > 0, let share = positionShare else { return false }
        return share >= settings.extraSuggestPercent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Extra Search", systemImage: "binoculars").font(.headline).foregroundStyle(palette.textPrimary)
                Spacer()
                if let spread = ExtraSpread.points(run.stages, profile: run.profile) {
                    Text("\(run.composite ?? 500) ± \(spread)").font(.callout.monospacedDigit()).foregroundStyle(palette.textSecondary)
                }
            }
            if let spread = ExtraSpread.points(run.stages, profile: run.profile) {
                Text("± \(spread) shows how much the stages disagree with each other\(spread >= 60 ? " — a lot, so treat the exact number with care" : "").")
                    .font(.caption).foregroundStyle(palette.textSecondary)
            }
            if isBigTrade, let share = positionShare {
                Label("Big trade: the planned position is about \(Int(share.rounded()))% of your \(run.instrument.currency) capital. An Extra Search is suggested.",
                      systemImage: "exclamationmark.bubble")
                    .font(.callout).foregroundStyle(palette.warning)
            }
            if settings.showExtraConflicts {
                if conflicts.isEmpty {
                    Label("No disagreement between news, business and chart stages.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(palette.textSecondary)
                } else {
                    ForEach(conflicts) { c in
                        Label(c.text, systemImage: c.strong ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(c.strong ? palette.down : palette.warning)
                    }
                }
            }
            switch engine.phase {
            case .debating:
                ProgressView("Bull and bear analysts are arguing…").font(.callout)
                Button("Cancel", role: .cancel) { engine.cancel() }.font(.callout)
            case .judging:
                ProgressView("The judge is weighing both cases…").font(.callout)
                Button("Cancel", role: .cancel) { engine.cancel() }.font(.callout)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(palette.down)
            default:
                EmptyView()
            }
            if let saved, !engine.isRunning {
                Button { showResult = saved } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        if let x = saved.extraScore, let j = saved.judge {
                            Text("Extra score \(x) · \(j.actionTitle)").font(.callout.weight(.semibold))
                            Text("\(j.stanceTitle) · \(saved.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(palette.textSecondary)
                        } else {
                            Text("Last Extra Search did not finish — open for details").font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !engine.isRunning {
                let blockers = ExtraSearchEngine.blockers(settings: settings)
                if let first = blockers.first {
                    Text(first).font(.caption).foregroundStyle(palette.warning)
                } else {
                    AdaptiveButton(title: saved == nil ? "Run Extra Search" : "Run again",
                                   systemImage: "binoculars", kind: isBigTrade && saved == nil ? .primary : .secondary) {
                        confirm = true
                    }
                }
            }
        }
        .dataCard()
        .confirmationDialog("Run Extra Search?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Run (about \(String(format: "$%.2f", ExtraSearchEngine.estimate(settings: settings))))") {
                engine.start(run, settings: settings, store: extras, analyses: analyses, outcomes: outcomes)
            }
        } message: {
            Text("Two AI analysts argue the bull and bear case from this analysis, then your Deep model judges. No web search. The analysis itself is not changed.")
        }
        .onChange(of: engine.phase) { _, phase in
            if phase == .done, let r = engine.result { showResult = r }
        }
        .sheet(item: $showResult) { r in
            NavigationStack {
                ExtraSearchResultView(result: r, run: run)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showResult = nil } } }
            }
        }
    }
}

// MARK: - Result

struct ExtraSearchResultView: View {
    @Environment(\.palette) private var palette
    let result: ExtraSearchResult
    let run: AnalysisRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                compare
                if let j = result.judge { judgeCard(j) }
                if let bull = result.bull { caseCard(bull, title: "Bull case", icon: "arrow.up.right", color: palette.up) }
                if let bear = result.bear { caseCard(bear, title: "Bear case", icon: "arrow.down.right", color: palette.down) }
                groupsCard
                memoryCard
                if !result.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Problems", systemImage: "exclamationmark.triangle").font(.subheadline.weight(.semibold)).foregroundStyle(palette.warning)
                        ForEach(result.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(palette.textPrimary) }
                    }
                    .dataCard()
                }
                Text("Cost \(String(format: "$%.3f", result.totalCostUSD)) · prompts \(result.promptVersion). A second opinion from the same AI family, not proof. The normal analysis above is unchanged.")
                    .font(.caption2).foregroundStyle(palette.textSecondary)
            }
            .padding()
        }
        .skinScreen()
        .background(palette.background)
        .navigationTitle("Extra Search · \(run.instrument.symbol)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var compare: some View {
        HStack(alignment: .top) {
            column("Normal analysis", "\(result.normalComposite)", Verdict(rawValue: result.normalVerdict)?.title ?? "No trade",
                   detail: result.spread.map { "± \($0) stage spread" })
            Divider()
            column("Extra Search", result.extraScore.map(String.init) ?? "—", result.judge?.actionTitle ?? "Unavailable",
                   detail: result.judge.map { "confidence \(Int(($0.confidence * 100).rounded()))%" })
        }
        .frame(maxWidth: .infinity)
        .dataCard()
    }

    private func column(_ title: String, _ value: String, _ sub: String, detail: String?) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(palette.textSecondary)
            Text(value).font(.largeTitle.weight(.bold).monospacedDigit()).foregroundStyle(palette.textPrimary)
            Text(sub).font(.callout.weight(.semibold)).foregroundStyle(palette.accent)
            if let detail { Text(detail).font(.caption2).foregroundStyle(palette.textSecondary) }
        }
        .frame(maxWidth: .infinity)
    }

    private func judgeCard(_ j: ExtraJudgement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(j.stanceTitle, systemImage: j.stance == "agree" ? "checkmark.seal" : j.stance == "disagree" ? "xmark.seal" : "exclamationmark.shield")
                .font(.headline).foregroundStyle(j.stance == "disagree" ? palette.down : j.stance == "agree" ? palette.up : palette.warning)
            Text(j.summary).font(.callout).foregroundStyle(palette.textPrimary)
            if !j.deciding.isEmpty {
                Text("What decided it").font(.subheadline.weight(.semibold)).foregroundStyle(palette.textSecondary)
                ForEach(j.deciding, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(palette.textPrimary) }
            }
            if !j.risks.isEmpty {
                Text("Biggest risks").font(.subheadline.weight(.semibold)).foregroundStyle(palette.textSecondary)
                ForEach(j.risks, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(palette.textPrimary) }
            }
            if !j.changeMind.isEmpty {
                Text("Would change the decision").font(.subheadline.weight(.semibold)).foregroundStyle(palette.textSecondary)
                Text(j.changeMind).font(.callout).foregroundStyle(palette.textPrimary)
            }
            raw(j.rawOutput, model: j.model)
        }
        .dataCard()
    }

    private func caseCard(_ c: ExtraCase, title: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon).font(.headline).foregroundStyle(color)
                Spacer()
                Text("strength \(c.strength)/100").font(.caption.monospacedDigit()).foregroundStyle(palette.textSecondary)
            }
            Text(c.summary).font(.callout).foregroundStyle(palette.textPrimary)
            ForEach(c.points, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(palette.textPrimary) }
            raw(c.rawOutput, model: c.model)
        }
        .dataCard()
    }

    private var groupsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stage groups").font(.headline).foregroundStyle(palette.textPrimary)
            ForEach(result.leans) { g in
                HStack {
                    Text(g.title).font(.callout)
                    Spacer()
                    Text("\(g.score) · \(g.direction)").font(.callout.monospacedDigit())
                        .foregroundStyle(g.direction == "up" ? palette.up : g.direction == "down" ? palette.down : palette.textSecondary)
                }
            }
            if result.conflicts.isEmpty {
                Text("No disagreements.").font(.caption).foregroundStyle(palette.textSecondary)
            } else {
                ForEach(result.conflicts) { Label($0.text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(palette.warning) }
            }
        }
        .dataCard()
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Track record on \(run.instrument.symbol)").font(.headline).foregroundStyle(palette.textPrimary)
            if result.memory.isEmpty {
                Text("No earlier analyses of this product.").font(.caption).foregroundStyle(palette.textSecondary)
            }
            ForEach(result.memory) { m in
                HStack {
                    Text(m.date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                    Text("\(m.composite) \(m.verdict)").font(.caption.monospacedDigit())
                    Spacer()
                    if let right = m.directionRight {
                        Text(right ? "right" : "wrong").font(.caption.weight(.semibold)).foregroundStyle(right ? palette.up : palette.down)
                    } else {
                        Text(m.graded ? "no call" : "waiting").font(.caption).foregroundStyle(palette.textSecondary)
                    }
                    if let r = m.forwardReturnPct { Text(String(format: "%+.1f%%", r)).font(.caption.monospacedDigit()) }
                }
            }
            Text("From the report card's own grading. A few results prove little.").font(.caption2).foregroundStyle(palette.textSecondary)
        }
        .dataCard()
    }

    private func raw(_ text: String, model: String?) -> some View {
        DisclosureGroup("Show raw AI output\(model.map { " · \($0)" } ?? "")") {
            Text(text).font(.caption2.monospaced()).textSelection(.enabled).foregroundStyle(palette.textSecondary)
        }
        .font(.caption)
    }
}

// MARK: - India VIX advice when saving a trade

struct ExtraVIXSection: View {
    @Environment(\.palette) private var palette
    @Environment(MarketStore.self) private var market
    let instrument: Instrument
    let suggestedQuantity: Double
    @Binding var quantity: String
    @State private var vix: Double?
    @State private var failed = false

    var body: some View {
        Section {
            if let vix {
                let m = VIXSizing.multiplier(vix: vix)
                let adjusted = VIXSizing.adjusted(quantity: suggestedQuantity, multiplier: m, lotSize: instrument.lotSize)
                LabeledContent("India VIX", value: "\(String(format: "%.2f", vix)) · \(VIXSizing.band(vix: vix))")
                LabeledContent("Size advice", value: "\(Int((m * 100).rounded()))% of normal")
                if m < 1, suggestedQuantity > 0 {
                    LabeledContent("Adjusted quantity", value: adjusted.formatted())
                    Button("Use \(adjusted.formatted())") { quantity = adjusted.formatted(.number.grouping(.never)) }
                        .disabled(adjusted <= 0)
                }
            } else if failed {
                Text("India VIX unavailable — log in to Upstox in Settings → Market Data.").font(.caption).foregroundStyle(palette.textSecondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Extra Search · India VIX")
        } footer: {
            Text("Advice only. Normal size below VIX 15, 85% at 15–20, 65% at 20–25, 50% above 25. Your quantity is changed only if you tap “Use”.")
        }
        .task {
            do { vix = try await market.lastPrice(VIXSizing.instrument) } catch { failed = true }
        }
    }
}

// MARK: - Report card section

struct ExtraReportCardSection: View {
    @Environment(\.palette) private var palette
    @Environment(ExtraSearchStore.self) private var extras
    @Environment(OutcomeStore.self) private var outcomes

    var body: some View {
        let c = ExtraReportCard.build(results: extras.results, outcomes: outcomes.outcomes)
        Section {
            LabeledContent("Extra Searches", value: "\(c.searched) (\(c.graded) graded)")
            LabeledContent("Normal analysis right", value: c.normalRightPct.map { "\(Int($0.rounded()))% of \(c.normalCalls)" } ?? "—")
            LabeledContent("Extra Search right", value: c.extraRightPct.map { "\(Int($0.rounded()))% of \(c.extraCalls)" } ?? "—")
            LabeledContent("They disagreed", value: c.disagreed > 0 ? "\(c.disagreed) times, Extra right \(c.extraRightWhenDisagreed)" : "—")
        } header: {
            Text("Extra Search vs normal")
        } footer: {
            Text("Same grading as above, on the analyses where you ran an Extra Search. With fewer than about 30 graded, these numbers are luck — keep both until one clearly wins.")
        }
    }
}
