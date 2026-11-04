import SwiftUI

/// Code-computed technical snapshot shown under the chart. Every value here is calculated on
/// the device; this is exactly what the AI will receive (and must cite) in Milestone 4.
struct TechnicalsPanel: View {
    @Environment(\.palette) private var palette
    let snapshot: FeatureEngine.Snapshot
    @State private var expanded: Set<FeatureEngine.Category> = [.trend, .momentum, .levels]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(FeatureEngine.Category.allCases, id: \.self) { category in
                let items = snapshot.features(in: category)
                if !items.isEmpty {
                    DisclosureGroup(isExpanded: binding(category)) {
                        VStack(spacing: 10) {
                            ForEach(items) { FeatureRow(feature: $0) }
                            if category == .patterns { patternStats }
                            if category == .history { historyExtras }
                        }
                        .padding(.top, 6)
                    } label: {
                        categoryLabel(category, items)
                    }
                    .tint(palette.textSecondary)
                    if category != FeatureEngine.Category.allCases.last { Divider() }
                }
            }
            Text("Calculated on this device from \(snapshot.bars) bars. Not advice — the AI score arrives in Milestone 4.")
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
        }
        .dataCard()
    }

    private var header: some View {
        let bias = snapshot.bias
        let color = bias.label == "Bullish" ? palette.up : bias.label == "Bearish" ? palette.down : palette.neutral
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Technicals").font(.headline).foregroundStyle(palette.textPrimary)
                Text("\(snapshot.timeframe.label) · \(bias.bullish) bullish · \(bias.bearish) bearish signals")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Text(bias.label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private func categoryLabel(_ category: FeatureEngine.Category, _ items: [FeatureEngine.Feature]) -> some View {
        let up = items.filter { $0.signal > 0 }.count
        let down = items.filter { $0.signal < 0 }.count
        return HStack {
            Text(category.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(palette.textPrimary)
            Spacer()
            if up > 0 { Label("\(up)", systemImage: "arrow.up").labelStyle(.titleAndIcon).foregroundStyle(palette.up) }
            if down > 0 { Label("\(down)", systemImage: "arrow.down").labelStyle(.titleAndIcon).foregroundStyle(palette.down) }
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private var patternStats: some View {
        let reliable = snapshot.patternStats.filter { $0.occurrences >= 5 && $0.kind.bias != 0 }.prefix(5)
        if !reliable.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("How patterns have worked on this product (\(snapshot.timeframe.label), 5 bars later)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                ForEach(Array(reliable), id: \.kind) { s in
                    HStack {
                        Text(s.kind.title).font(.caption)
                        Spacer()
                        Text("\(Int((s.hitRate * 100).rounded()))% of \(s.occurrences) · avg \(String(format: "%+.2f", s.avgReturnPct))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(s.hitRate >= 0.55 ? palette.up : s.hitRate <= 0.45 ? palette.down : palette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var historyExtras: some View {
        if let h = snapshot.history, !h.regimes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Major phases (moves of 20% or more)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                ForEach(Array(h.regimes.suffix(6).enumerated()), id: \.offset) { _, r in
                    HStack {
                        Circle()
                            .fill(r.kind == .bull ? palette.up : r.kind == .bear ? palette.down : palette.neutral)
                            .frame(width: 7, height: 7)
                        Text("\(r.start.formatted(.dateTime.month(.abbreviated).year())) → \(r.end.formatted(.dateTime.month(.abbreviated).year()))")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%+.1f%%", r.changePct)).font(.caption.monospacedDigit())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding(_ c: FeatureEngine.Category) -> Binding<Bool> {
        Binding(get: { expanded.contains(c) }, set: { if $0 { expanded.insert(c) } else { expanded.remove(c) } })
    }
}

private struct FeatureRow: View {
    @Environment(\.palette) private var palette
    let feature: FeatureEngine.Feature

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: feature.signal > 0 ? "arrow.up.circle.fill" : feature.signal < 0 ? "arrow.down.circle.fill" : "circle")
                .foregroundStyle(feature.signal > 0 ? palette.up : feature.signal < 0 ? palette.down : palette.neutral)
                .font(.footnote)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.label).font(.callout).foregroundStyle(palette.textPrimary)
                Text(feature.display).font(.caption.monospacedDigit()).foregroundStyle(palette.textSecondary)
                if let note = feature.note {
                    Text(note).font(.caption.weight(.medium)).foregroundStyle(palette.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint(feature.id)
    }
}
