import SwiftUI

struct HomeView: View {
    @Environment(\.palette) private var palette
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @State private var demoScore = 712

    private var connectedCount: Int {
        AIProviderKind.allCases.filter { catalog.hasKey[$0] == true }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if settings.paperMode {
                    Label("Paper mode — no real money", systemImage: "doc.text")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .floatingGlass(in: Capsule())
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Score preview")
                        .font(.headline)
                        .foregroundStyle(palette.textPrimary)
                    ScoreGauge(score: demoScore, caption: "Sample only — real scores arrive in M4")
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity)
                    Slider(value: Binding(get: { Double(demoScore) }, set: { demoScore = Int($0) }),
                           in: 10...1000, step: 1)
                        .accessibilityLabel("Sample score")
                    Text("Drag to see how the verdict bands and colours behave in this theme.")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .dataCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Setup")
                        .font(.headline)
                        .foregroundStyle(palette.textPrimary)
                    SetupRow(done: connectedCount > 0,
                             title: "Connect an AI provider",
                             detail: connectedCount > 0 ? "\(connectedCount) connected" : "Settings → AI Providers")
                    SetupRow(done: settings.tierAssignments.count == ModelTier.allCases.count,
                             title: "Choose Fast / Balanced / Deep models",
                             detail: "\(settings.tierAssignments.count) of 3 tiers set")
                    SetupRow(done: false, title: "Connect market data", detail: "Arrives in M2 with the backend server")
                }
                .dataCard()
            }
            .padding()
        }
        .background(palette.background)
        .navigationTitle("Home")
    }
}

private struct SetupRow: View {
    @Environment(\.palette) private var palette
    let done: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? palette.up : palette.neutral)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(palette.textPrimary)
                Text(detail).font(.caption).foregroundStyle(palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
