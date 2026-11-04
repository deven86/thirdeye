import SwiftUI

/// Map each tier (Fast / Balanced / Deep) to a live model. Every analysis stage asks for a tier.
struct ModelTiersView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.palette) private var palette

    var body: some View {
        Form {
            if catalog.allModels.isEmpty {
                Section {
                    Label("Connect an AI provider first, then come back here.", systemImage: "key")
                        .foregroundStyle(palette.textSecondary)
                }
            }
            ForEach(ModelTier.allCases) { tier in
                Section {
                    Picker(selection: binding(for: tier)) {
                        Text("Not set").tag(ModelRef?.none)
                        ForEach(AIProviderKind.allCases) { provider in
                            if let models = catalog.models[provider], !models.isEmpty {
                                Section(provider.shortName) {
                                    ForEach(models) { model in
                                        Text(model.displayName)
                                            .tag(Optional(ModelRef(provider: provider, modelID: model.modelID)))
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(tier.title, systemImage: tier.symbolName)
                    }
                    .pickerStyle(.navigationLink)
                    if let ref = settings.tierAssignments[tier] {
                        Text("\(ref.provider.shortName) · \(ref.modelID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.textSecondary)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text(tier.purpose)
                }
            }
            Section {
                Button("Suggest newest model for each tier") {
                    settings.tierAssignments = TierSuggester.defaultAssignments(from: catalog.allModels)
                }
                .disabled(catalog.allModels.isEmpty)
            } footer: {
                Text("Suggestions use the model name (e.g. Haiku → Fast, Sonnet → Balanced, Opus → Deep). Check them — model line-ups change often.")
            }
        }
        .navigationTitle("Model Tiers")
    }

    private func binding(for tier: ModelTier) -> Binding<ModelRef?> {
        Binding(
            get: { settings.tierAssignments[tier] },
            set: { newValue in settings.tierAssignments[tier] = newValue }
        )
    }
}

struct ThemePickerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        List {
            ForEach(AppTheme.allCases) { theme in
                let palette = theme.palette(colorBlindSafe: settings.colorBlindSafe, systemScheme: systemScheme)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { settings.theme = theme }
                } label: {
                    HStack(spacing: 14) {
                        HStack(spacing: 0) {
                            palette.background
                            palette.surface
                            palette.accent
                            palette.up
                            palette.down
                        }
                        .frame(width: 70, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.secondary.opacity(0.3)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.title).foregroundStyle(.primary)
                            Text(theme.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.theme == theme {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityAddTraits(settings.theme == theme ? .isSelected : [])
            }
        }
        .navigationTitle("Theme")
    }
}
