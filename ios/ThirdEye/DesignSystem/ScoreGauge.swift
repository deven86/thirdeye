import SwiftUI

/// Verdict for a 10–1000 composite score (bands from shared/config/scoring_weights.json).
nonisolated enum Verdict: String, CaseIterable, Sendable {
    case strongBuy, buy, noTrade, sell, strongSell

    init(composite: Int) {
        switch composite {
        case 750...: self = .strongBuy
        case 620...749: self = .buy
        case 381...619: self = .noTrade
        case 251...380: self = .sell
        default: self = .strongSell
        }
    }

    var title: String {
        switch self {
        case .strongBuy: "Strong Buy"
        case .buy: "Buy"
        case .noTrade: "No trade"
        case .sell: "Sell"
        case .strongSell: "Strong Sell"
        }
    }
}

/// Semicircle gauge for the 0–1000 score. Solid (no glass) because it is data.
struct ScoreGauge: View {
    @Environment(\.palette) private var palette
    let score: Int
    var caption: String?

    private var fraction: Double { min(max(Double(score) / 1000, 0), 1) }

    var body: some View {
        let verdict = Verdict(composite: score)
        let color = palette.color(forComposite: score)
        VStack(spacing: 6) {
            ZStack {
                ArcShape(fraction: 1)
                    .stroke(palette.separator, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                ArcShape(fraction: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                VStack(spacing: 2) {
                    Text("\(score)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.textPrimary)
                        .contentTransition(.numericText(value: Double(score)))
                    Text(verdict.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(color)
                }
                .offset(y: 18)
            }
            .aspectRatio(2, contentMode: .fit)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Score \(score) out of 1000, \(verdict.title)")
    }
}

private struct ArcShape: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2, rect.height) - 8
        let center = CGPoint(x: rect.midX, y: rect.maxY - 4)
        var path = Path()
        path.addArc(center: center,
                    radius: radius,
                    startAngle: .degrees(180),
                    endAngle: .degrees(180 + 180 * fraction),
                    clockwise: false)
        return path
    }
}
