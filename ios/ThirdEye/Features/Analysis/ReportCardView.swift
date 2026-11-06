import SwiftUI

/// How the analyses actually did: graded automatically once each holding period is over.
struct ReportCardView: View {
    @Environment(AnalysisStore.self) private var analyses
    @Environment(OutcomeStore.self) private var outcomes
    @Environment(MarketStore.self) private var market
    @Environment(\.palette) private var palette

    var body: some View {
        let card = ReportCard.build(runs: analyses.runs, outcomes: outcomes.outcomes)
        let pending = outcomes.pending(analyses.runs)
        List { Group {
            Section {
                HStack {
                    metric("Graded", "\(card.graded)")
                    metric("Waiting", "\(pending)")
                    metric("Direction right", card.directionRightPct.map { pct($0) } ?? "—")
                }
                if card.graded < ReportCard.minimumForConclusions {
                    Text("Too few results to judge yet — about \(ReportCard.minimumForConclusions) graded analyses are needed before these numbers mean much. Coin-flip luck looks like skill in small samples.")
                        .font(.caption).foregroundStyle(palette.warning)
                }
                Button {
                    Task { await outcomes.gradeDue(analyses.runs, market: market, force: true) }
                } label: {
                    Label(outcomes.isGrading ? "Grading…" : "Grade finished analyses now", systemImage: "checkmark.seal")
                }
                .disabled(outcomes.isGrading || pending == 0)
            } footer: {
                Text("An analysis is graded after its holding period (the plan's days, or 10 days for swing without a plan): did the price go the way the score pointed, and what would the plan have made, managed with the same stop and take-profit ladder?")
            }

            Section {
                LabeledContent("Buy/Sell verdicts", value: "\(card.trades)")
                LabeledContent("Entry zone reached", value: "\(card.tradesEntered)")
                LabeledContent("Ended in profit", value: card.tradeWinPct.map { pct($0) } ?? "—")
                LabeledContent("Average result", value: card.tradeAverageR.map { String(format: "%+.2fR", $0) } ?? "—")
            } header: {
                Text("Trades the app recommended")
            } footer: {
                Text("Counts every Buy/Sell plan as if you had followed it — including ones you didn't take.")
            }

            Section {
                ForEach(card.bands) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.label).font(.callout)
                            Text("\(b.count) graded").font(.caption2).foregroundStyle(palette.textSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(b.rightPct.map { "\(pct($0)) right" } ?? "—").font(.callout.monospacedDigit())
                            Text(b.avgMovePct.map { String(format: "%+.1f%% avg", $0) } ?? "").font(.caption2.monospacedDigit())
                                .foregroundStyle((b.avgMovePct ?? 0) >= 0 ? palette.up : palette.down)
                        }
                    }
                }
                if let rho = card.scoreReturnCorrelation {
                    LabeledContent("Score ↔ later return", value: String(format: "%.2f", rho))
                }
            } header: {
                Text("By score")
            } footer: {
                Text("A useful score shows higher “right” rates and bigger average moves in the outer bands. A correlation near 0 means the number isn't predicting yet.")
            }

            Section {
                ForEach(card.stages) { s in
                    HStack {
                        Text("\(s.stage). \(s.name)").font(.callout).lineLimit(1)
                        Spacer()
                        Text(s.rightPct.map { "\(pct($0)) of \(s.count)" } ?? "—").font(.callout.monospacedDigit())
                            .foregroundStyle(color(s.rightPct, s.count))
                    }
                }
            } header: {
                Text("Each stage's direction calls")
            } footer: {
                Text("How often a stage that leaned up (score ≥ 55) or down (≤ 45) was right. After about 50 results per stage, the weak ones can be given less weight — that is the calibration step.")
            }
        }.skinRows()
        }
        .skinScreen()
        .navigationTitle("Report card")
        .task { await outcomes.gradeDue(analyses.runs, market: market) }
    }

    private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    private func color(_ v: Double?, _ n: Int) -> Color {
        guard let v, n >= 10 else { return palette.textSecondary }
        return v >= 55 ? palette.up : v <= 45 ? palette.down : palette.textPrimary
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
