import SwiftUI

struct AIProvidersView: View {
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        List { Group {
            Section {
                ForEach(AIProviderKind.allCases) { provider in
                    NavigationLink {
                        ProviderDetailView(provider: provider)
                    } label: {
                        ProviderRow(provider: provider)
                    }
                }
            } footer: {
                Text("Add at least one key. Claude is the primary provider in the spec; OpenAI and Gemini are optional. Set a monthly spending limit in each provider's console.")
            }
        }.skinRows()
        }
        .skinScreen()
        .navigationTitle("AI Providers")
        .refreshable { await catalog.refreshAllConnected() }
    }
}

private struct ProviderRow: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.palette) private var palette
    let provider: AIProviderKind

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Image(systemName: catalog.hasKey[provider] == true ? "checkmark.seal.fill" : "plus.circle")
                .foregroundStyle(catalog.hasKey[provider] == true ? palette.up : palette.neutral)
        }
    }

    private var statusText: String {
        guard catalog.hasKey[provider] == true else { return "Not connected" }
        switch catalog.state(for: provider) {
        case .loading: return "Checking…"
        case .failed: return "Key saved · last check failed"
        case .loaded: return "\(catalog.models[provider]?.count ?? 0) models available"
        case .idle: return "Key saved · pull to load models"
        }
    }
}

struct ProviderDetailView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    let provider: AIProviderKind

    @State private var keyInput = ""
    @State private var revealedKey: String?
    @State private var confirmRemove = false

    var body: some View {
        Form { Group {
            if catalog.hasKey[provider] == true {
                Section("Saved key") {
                    HStack {
                        Text(revealedKey.map(maskedSecret) ?? "••••••••••••")
                            .font(.body.monospaced())
                        Spacer()
                        Button(revealedKey == nil ? "Reveal" : "Hide") { toggleReveal() }
                    }
                    Button("Refresh model list") {
                        Task { await refresh() }
                    }
                    Button("Remove key", role: .destructive) { confirmRemove = true }
                }
            }

            Section {
                SecureField(provider.keyPlaceholder, text: $keyInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.body.monospaced())
                Button {
                    Task { await saveKey() }
                } label: {
                    HStack {
                        Text(catalog.hasKey[provider] == true ? "Replace & list models" : "Test & list models")
                        Spacer()
                        if catalog.state(for: provider) == .loading { ProgressView() }
                    }
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty || catalog.state(for: provider) == .loading)
                Button("Get a key") { openURL(provider.consoleURL) }
            } header: {
                Text(catalog.hasKey[provider] == true ? "Replace key" : "Add key")
            } footer: {
                Text("The key is saved only after \(provider.shortName) accepts it. It is stored in the Keychain and syncs to your iPad through iCloud Keychain.")
            }

            if case .failed(let message) = catalog.state(for: provider) {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(palette.warning)
                }
            }

            if let models = catalog.models[provider], !models.isEmpty {
                Section("Available models (\(models.count))") {
                    ForEach(models) { model in
                        ModelRow(model: model)
                    }
                }
            }
        }.skinRows()
        }
        .skinScreen()
        .navigationTitle(provider.shortName)
        .confirmationDialog("Remove the \(provider.shortName) key from this iPhone and your iPad?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) {
                catalog.removeKey(for: provider)
                settings.tierAssignments = settings.tierAssignments.filter { $0.value.provider != provider }
                revealedKey = nil
            }
        }
        .task {
            if catalog.hasKey[provider] == true, catalog.models[provider] == nil {
                await refresh()
            }
        }
    }

    private func saveKey() async {
        let ok = await catalog.saveAndVerify(key: keyInput, for: provider)
        if ok {
            keyInput = ""
            revealedKey = nil
            settings.fillMissingTiers(from: catalog.allModels)
        }
    }

    private func refresh() async {
        await catalog.refresh(provider)
        settings.fillMissingTiers(from: catalog.allModels)
    }

    private func toggleReveal() {
        if revealedKey != nil {
            revealedKey = nil
            return
        }
        Task {
            let result = await AppLock.authenticate(reason: "Show your \(provider.shortName) API key")
            if result == .success {
                revealedKey = catalog.revealKey(for: provider)
            }
        }
    }
}

struct ModelRow: View {
    @Environment(\.palette) private var palette
    let model: AIModelInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.displayName)
                if let tier = TierSuggester.tier(for: model.modelID) {
                    Text(tier.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(palette.accent)
                }
            }
            Text(model.modelID)
                .font(.caption.monospaced())
                .foregroundStyle(palette.textSecondary)
            if let input = model.inputTokenLimit {
                Text("Context \(input.formatted()) tokens" + (model.outputTokenLimit.map { " · output \($0.formatted())" } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .textSelection(.enabled)
    }
}
