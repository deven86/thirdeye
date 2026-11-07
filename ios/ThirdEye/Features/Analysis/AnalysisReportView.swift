import SwiftUI

/// The full report: score, verdict, vetoes, trade plan, every stage's "why", and the exact maths.
struct AnalysisReportView: View {
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(AppSettings.self) private var settings
    let run: AnalysisRun
    @State private var showNewTrade = false

    private var verdict: Verdict { Verdict(rawValue: run.verdict ?? "") ?? .noTrade }
    private var isV2: Bool { (run.scoringVersion ?? 1) >= 2 }
    private var breakdown: [Scoring.Breakdown] {
        isV2 ? Scoring.composite(run.stages, profile: run.profile).breakdown
             : Scoring.compositeV1(run.stages, profile: run.profile).breakdown
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scoreCard
                if settings.extraSearchEnabled {
                    ExtraSearchCard(run: run)
                }
                ActionPlanCard(plan: ActionPlanner.build(run, inputs: .init(capital: settings.capital[run.instrument.currency],
                                                                             riskPercent: settings.riskPercent,
                                                                             paperMode: settings.paperMode)))
                if let checks = run.checks, !checks.isEmpty {
                    checksCard(checks)
                } else if !run.vetoes.isEmpty {
                    vetoCard
                }
                if verdict == .noTrade, let levels = run.watchLevels, !levels.isEmpty {
                    watchCard(levels)
                }
                if let cautions = run.cautions, !cautions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Caution", systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold)).foregroundStyle(palette.textSecondary)
                        ForEach(cautions, id: \.self) { Text($0).font(.callout).foregroundStyle(palette.textPrimary) }
                    }
                    .dataCard()
                }
                if let plan = run.plan {
                    PlanCard(plan: plan, tradable: verdict != .noTrade, currency: run.instrument.currency)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Plan on the chart").font(.headline).foregroundStyle(palette.textPrimary)
                        TradeChartView(instrument: run.instrument, levels: TradeChart.levels(plan),
                                       markers: [ChartMarker(time: run.startedAt, kind: .plan, text: "Analysed", below: plan.side != "long")],
                                       defaultTimeframe: run.planTimeframe ?? run.profile.planTimeframe, height: 260)
                    }
                    .dataCard(padding: 10)
                    if let base = run.baseRate { BaseRateCard(base: base, symbol: run.instrument.symbol) }
                    AdaptiveButton(title: "Save as upcoming trade", systemImage: "bookmark", kind: verdict == .noTrade ? .secondary : .primary) {
                        showNewTrade = true
                    }
                    .sheet(isPresented: $showNewTrade) { NewTradeSheet(run: run, plan: plan) }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No trade plan").font(.headline).foregroundStyle(palette.textPrimary)
                        Text("The final stage found no sound entry and stop, so it did not propose a trade. Waiting is a valid decision.")
                            .font(.callout).foregroundStyle(palette.textSecondary)
                        Button("Create my own plan anyway") { showNewTrade = true }
                            .font(.callout.weight(.semibold))
                    }
                    .dataCard()
                    .sheet(isPresented: $showNewTrade) { NewTradeSheet(run: run, plan: nil) }
                }
                Text("Stages").font(.title3.weight(.semibold)).foregroundStyle(palette.textPrimary)
                ForEach(run.stages) { StageCard(result: $0, weight: run.profile.weights[$0.stage - 1]) }
                mathsCard
                footer
            }
            .padding()
        }
        .skinScreen()
        .background(palette.background)
    }

    private var scoreCard: some View {
        VStack(spacing: 10) {
            Text("\(run.instrument.fullSymbol) · \(run.instrument.identityLine)")
                .font(.caption.weight(.semibold)).foregroundStyle(palette.textSecondary)
            ScoreGauge(score: run.composite ?? 500)
                .frame(maxWidth: 340)
            HStack(spacing: 20) {
                label("Buy score", "\(run.buyScore ?? 0)")
                label("Sell score", "\(run.sellScore ?? 0)")
                label("Profile", run.profile.title)
                if let grade = run.grade { label("Grade", grade) }
            }
            if verdict == .noTrade, let lean = run.lean {
                Text("No trade yet, but the analysis leans \(lean == "short" ? "down" : "up") — on watch.")
                    .font(.caption).foregroundStyle(palette.accent).multilineTextAlignment(.center)
            }
            if verdict == .noTrade, let c = run.composite, Verdict(composite: c) != .noTrade {
                Text("The number alone says \(Verdict(composite: c).title), but the checks below block the trade.")
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .dataCard()
    }

    private func label(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(palette.textPrimary)
            Text(title).font(.caption).foregroundStyle(palette.textSecondary)
        }
    }

    private var vetoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Why this is “No trade” or needs care", systemImage: "hand.raised")
                .font(.headline)
                .foregroundStyle(palette.warning)
            ForEach(run.vetoes, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(palette.textPrimary) }
        }
        .dataCard()
    }

    private func watchCard(_ levels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(run.lean == nil ? "Levels to watch" : "On watch — leaning \(run.lean == "short" ? "short" : "long")",
                  systemImage: "binoculars")
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
            ForEach(levels, id: \.self) { Text($0).font(.callout).foregroundStyle(palette.textPrimary) }
            Text("A close beyond a level is a reason to re-run the analysis, not a trade by itself.")
                .font(.caption2).foregroundStyle(palette.textSecondary)
        }
        .dataCard()
    }

    private func checksCard(_ checks: [ScoreCheck]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(verdict == .noTrade ? "Why this is “No trade”" : checks.allSatisfy(\.passed) ? "Every check passed" : "All blocking checks passed",
                  systemImage: verdict == .noTrade ? "hand.raised" : "checkmark.seal")
                .font(.headline)
                .foregroundStyle(verdict == .noTrade ? palette.warning : palette.up)
            ForEach(checks) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : check.blocking ? "xmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(check.passed ? palette.up : check.blocking ? palette.down : palette.warning)
                        .font(.callout)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.title).font(.callout.weight(.semibold)).foregroundStyle(palette.textPrimary)
                        Text(check.detail).font(.caption).foregroundStyle(palette.textSecondary)
                    }
                }
            }
            let data = run.vetoes.filter { $0.hasPrefix("Data:") }
            ForEach(data, id: \.self) { Text($0).font(.caption).foregroundStyle(palette.warning) }
        }
        .dataCard()
    }

    private var mathsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How this score was calculated").font(.headline).foregroundStyle(palette.textPrimary)
            Text(isV2
                 ? "Score = 10 × the confidence-weighted average of the completed stages: each stage counts by weight (\(run.profile.title) profile) × confidence. Low confidence makes a stage count less; it no longer drags the score toward 500. Failed and skipped stages are left out, so their weight is shared by the others."
                 : "Older method (before 0.8): each stage score was pulled toward 50 when confidence was low — effective = 50 + confidence × (score − 50) — then multiplied by its weight. This squeezed almost every result into the No-trade band.")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Stage").gridColumnAlignment(.leading)
                    Text("Weight"); Text("Score"); Text("Conf."); Text(isV2 ? "Share" : "Points")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
                ForEach(breakdown, id: \.stage) { b in
                    GridRow {
                        Text("\(b.stage). \(b.name)").lineLimit(1).gridColumnAlignment(.leading)
                        Text("\(Int(b.weight))")
                        Text("\(b.score)")
                        Text(String(format: "%.2f", b.confidence))
                        Text(isV2 ? (b.counted ? "\(Int((b.share * 100).rounded()))%" : "—") : String(format: "%.0f", b.contribution))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(b.counted || !isV2 ? palette.textPrimary : palette.textSecondary)
                }
                Divider()
                GridRow {
                    Text("Total (out of 1000)").gridColumnAlignment(.leading)
                    Text(""); Text(""); Text("")
                    Text("\(run.composite ?? 0)").bold()
                }
                .font(.caption.monospacedDigit())
            }
            Text("Bands: ≥750 Strong Buy · 620–749 Buy · 381–619 No trade · 251–380 Sell · ≤250 Strong Sell. Sell score = 1010 − total.\(isV2 ? " Buy/Sell also needs every blocking check above to pass." : "")")
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
        }
        .dataCard()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Analysed \(run.startedAt.formatted(date: .abbreviated, time: .shortened)) at price \(run.lastPrice.map { String($0) } ?? "—")")
            Text("AI cost $\(String(format: "%.3f", run.totalCostUSD)) · prompts \(run.promptVersion)")
            Text("Personal analytical tool, not investment advice. AI output can be wrong — check the sources.")
        }
        .font(.caption2)
        .foregroundStyle(palette.textSecondary)
    }
}

/// "What to do": the step-by-step playbook, collapsed to the headline and first steps until opened.
private struct ActionPlanCard: View {
    @Environment(\.palette) private var palette
    let plan: ActionPlan
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What to do", systemImage: plan.tone == .trade ? "checklist" : "hourglass")
                .font(.headline)
                .foregroundStyle(plan.tone == .trade ? palette.up : palette.accent)
            Text(plan.headline).font(.callout.weight(.semibold)).foregroundStyle(palette.textPrimary)
            ForEach(expanded ? plan.steps : Array(plan.steps.prefix(2))) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Label(step.title, systemImage: step.icon).font(.subheadline.weight(.semibold)).foregroundStyle(palette.textPrimary)
                    ForEach(step.lines, id: \.self) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(palette.textSecondary)
                            Text(line).font(.callout).foregroundStyle(palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
            if plan.steps.count > 2 {
                Button(expanded ? "Show less" : "Show all \(plan.steps.count) steps — size, stop, targets, trailing, what if it goes wrong") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.callout.weight(.semibold))
            }
            Text("Built in code from this plan and your risk settings. An analytical aid, not investment advice.")
                .font(.caption2).foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dataCard()
    }
}

/// How trades managed exactly like this plan behaved on this product's own history. Information, not a forecast.
private struct BaseRateCard: View {
    @Environment(\.palette) private var palette
    let base: PlanReplay.BaseRate
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("History check — not a forecast", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.textPrimary)
            Text("Every past \(base.side) entry on \(symbol) since \(base.from.formatted(date: .abbreviated, time: .omitted)), managed like this plan: stop \(String(format: "%.1f", base.stopATR)) ATR, the same take-profit ladder, closed after \(base.horizonBars) bars, after ~\(String(format: "%.2g", base.costPct))% costs.")
                .font(.caption).foregroundStyle(palette.textSecondary)
            HStack(alignment: .top) {
                stat("Stop hit first", pct(base.stopFirstPct))
                stat("Reached TP1", pct(base.tp1Pct))
                stat("Reached TP2", pct(base.tp2Pct))
            }
            HStack(alignment: .top) {
                stat("Ended in profit", pct(base.winPct))
                stat("Average result", String(format: "%+.2fR", base.averageR))
                stat("Worst losing run", "\(base.longestLosingStreak) in a row")
            }
            Text("\(base.entries) replays, \(base.independent) of them non-overlapping. Plan your size so \(max(base.longestLosingStreak, 3)) losses in a row are survivable. Past results in similar conditions did not predict the next trade in our tests, so this does not change the verdict.")
                .font(.caption2).foregroundStyle(palette.textSecondary)
        }
        .dataCard()
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(palette.textPrimary)
            Text(title).font(.caption2).foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlanCard: View {
    @Environment(\.palette) private var palette
    let plan: TradePlan
    let tradable: Bool
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Trade plan").font(.headline).foregroundStyle(palette.textPrimary)
                Spacer()
                Text(plan.side.uppercased())
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((plan.side == "long" ? palette.up : palette.down).opacity(0.15), in: Capsule())
                    .foregroundStyle(plan.side == "long" ? palette.up : palette.down)
                Text(plan.badge.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(palette.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(palette.accent)
            }
            if !tradable {
                Text("Shown for reference only — the verdict is No trade.")
                    .font(.caption).foregroundStyle(palette.warning)
            }
            row("Entry zone", "\(fmt(plan.entryLow)) – \(fmt(plan.entryHigh))")
            row("Stop-loss", fmt(plan.stopLoss), color: palette.down)
            ForEach(plan.takeProfits, id: \.stage) { tp in
                row("TP\(tp.stage) · book \(Int(tp.bookPercent))%",
                    tp.price.map(fmt) ?? "Trailing", sub: tp.then, color: palette.up)
            }
            row("Complete by", plan.completeBy.formatted(date: .abbreviated, time: .omitted))
            if !plan.invalidation.isEmpty {
                Text("Plan is wrong if: \(plan.invalidation)").font(.caption).foregroundStyle(palette.textSecondary)
            }
            if !plan.issues.isEmpty {
                ForEach(plan.issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(palette.warning) }
            }
            Text("Place a real stop-loss order at your broker. Alerts can be delayed.")
                .font(.caption2).foregroundStyle(palette.textSecondary)
        }
        .dataCard()
    }

    private func row(_ title: String, _ value: String, sub: String? = nil, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).foregroundStyle(palette.textSecondary)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(color ?? palette.textPrimary)
            }
            .font(.callout)
            if let sub { Text(sub).font(.caption2).foregroundStyle(palette.textSecondary) }
        }
    }

    private func fmt(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 10 ? 4 : 2)).locale(Locale(identifier: currency == "INR" ? "en_IN" : "en_US")))
    }
}

private struct StageCard: View {
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    let result: StageResult
    let weight: Double
    @State private var expanded = false
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(result.stage). \(result.name)").font(.subheadline.weight(.semibold)).foregroundStyle(palette.textPrimary)
                        Text(result.summary).font(.caption).foregroundStyle(palette.textSecondary)
                            .lineLimit(expanded ? nil : 2).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(result.status == .done ? "\(result.score)" : result.status == .skipped ? "off" : "—")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(result.score >= 56 ? palette.up : result.score <= 44 ? palette.down : palette.neutral)
                        Text("weight \(Int(weight))").font(.caption2).foregroundStyle(palette.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                if !result.reasons.isEmpty {
                    ForEach(result.reasons, id: \.self) { r in
                        HStack(alignment: .top, spacing: 8) {
                            Text(r.impact > 0 ? "+\(r.impact)" : "\(r.impact)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .frame(width: 24)
                                .foregroundStyle(r.impact > 0 ? palette.up : r.impact < 0 ? palette.down : palette.neutral)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.point).font(.caption).foregroundStyle(palette.textPrimary)
                                Text(r.evidence.joined(separator: " · ")).font(.caption2.monospaced()).foregroundStyle(palette.accent)
                            }
                        }
                    }
                }
                if !result.sources.isEmpty {
                    Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(palette.textSecondary)
                    ForEach(result.sources, id: \.self) { s in
                        Button {
                            if let url = URL(string: s.url) { openURL(url) }
                        } label: {
                            Text("[\(s.id)] \(s.title)").font(.caption).multilineTextAlignment(.leading)
                        }
                    }
                }
                ForEach(result.warnings, id: \.self) { w in
                    Label(w, systemImage: "info.circle").font(.caption2).foregroundStyle(palette.warning)
                }
                Text("\(result.model ?? "—")\(result.usedWebSearch ? " · web search \(result.usage.webSearches)" : "") · confidence \(String(format: "%.2f", result.confidence)) · $\(String(format: "%.3f", result.costUSD))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.textSecondary)
                if !result.rawOutput.isEmpty {
                    DisclosureGroup("Show raw AI output", isExpanded: $showRaw) {
                        ScrollView {
                            Text(result.rawOutput)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                    }
                    .font(.caption)
                    .tint(palette.textSecondary)
                }
            }
        }
        .dataCard(padding: 14)
    }
}
