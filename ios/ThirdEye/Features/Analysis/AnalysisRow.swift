import SwiftUI

struct AnalysisRow: View {
    @Environment(\.palette) private var palette
    let run: AnalysisRun

    var body: some View {
        let verdict = Verdict(rawValue: run.verdict ?? "") ?? .noTrade
        HStack(spacing: 12) {
            Text("\(run.composite ?? 0)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(palette.color(forComposite: run.composite ?? 500))
                .frame(minWidth: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(run.instrument.symbol) · \(verdict.title)").font(.callout.weight(.semibold)).foregroundStyle(palette.textPrimary)
                Text("\(run.profile.title) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.textSecondary)
        }
        .contentShape(Rectangle())
    }
}
