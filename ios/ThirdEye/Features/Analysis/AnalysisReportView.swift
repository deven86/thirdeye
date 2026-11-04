import SwiftUI

/// The full report: score, verdict, vetoes, trade plan, every stage's "why", and the exact maths.
struct AnalysisReportView: View {
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    let run: AnalysisRun
    @State private var showNewTrade = false

    private var verdict: Verdict { Verdict(rawValue: run.verdict ?? "") ?? .noTrade }
    private var breakdown: [Scoring.Breakdown] { Scoring.composite(run.stages, profile: run.profile).breakdown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scoreCard
                if !run.vetoes.isEmpty { vetoCard }
                if let cautions = run.cautions, !cautions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Caution", systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold)).foregroundStyle(palette.textSecondary)
                        ForEach(cautions, id: \.self) { Text($0).font(.callout).foregroundStyle(palette.textPrimary) }
                    }
                    .dataCard()
                }
                if let plan = run.plan {
                    PlanCard(plan: plan, tradable: verdict != .noTrade, currency: run.instrument.currency)
                    AdaptiveButton(title: "Save as upcoming trade", systemImage: "bookmark", kind: verdict == .noTrade ? .secondary : .primary) {
                        showNewTrade = true
                    }
                    .sheet(isPresented: $showNewTrade) { NewTradeSheet(run: run, plan: plan) }
                }
                Text("Stages").font(.title3.weight(.semibold)).foregroundStyle(palette.textPrimary)
                ForEach(run.stages) { StageCard(result: $0, weight: run.profile.weights[$0.stage - 1]) }
                mathsCard
                footer
            }
            .padding()
        }
        .background(palette.background)
    }

    private var scoreCard: some View {
        VStack(spacing: 10) {
            ScoreGauge(score: run.composite ?? 500)
                .frame(maxWidth: 340)
            HStack(spacing: 20) {
                label("Buy score", "\(run.buyScore ?? 0)")
                label("Sell score", "\(run.sellScore ?? 0)")
                label("Profile", run.profile.title)
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

    private var mathsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How this score was calculated").font(.headline).foregroundStyle(palette.textPrimary)
            Text("Each stage score is pulled toward 50 when confidence is low: effective = 50 + confidence × (score − 50). Then each is multiplied by its weight for the \(run.profile.title) profile.")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Stage").gridColumnAlignment(.leading)
                    Text("Weight"); Text("Score"); Text("Conf."); Text("Points")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
                ForEach(breakdown, id: \.stage) { b in
                    GridRow {
                        Text("\(b.stage). \(b.name)").lineLimit(1).gridColumnAlignment(.leading)
                        Text("\(Int(b.weight))")
                        Text("\(b.score)")
                        Text(String(format: "%.2f", b.confidence))
                        Text(String(format: "%.0f", b.contribution))
                    }
                    .font(.caption.monospacedDigit())
                }
                Divider()
                GridRow {
                    Text("Total (out of 1000)").gridColumnAlignment(.leading)
                    Text(""); Text(""); Text("")
                    Text("\(run.composite ?? 0)").bold()
                }
                .font(.caption.monospacedDigit())
            }
            Text("Bands: ≥750 Strong Buy · 620–749 Buy · 381–619 No trade · 251–380 Sell · ≤250 Strong Sell. Sell score = 1010 − total.")
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
                        Text(result.status == .done ? "\(result.score)" : "—")
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
