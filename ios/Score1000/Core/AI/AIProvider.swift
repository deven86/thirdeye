import Foundation

/// AI providers the user can connect with their own API key.
/// Nothing about specific models is hard-coded: models are always listed live from the provider.
nonisolated enum AIProviderKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case anthropic
    case openai
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        }
    }

    var shortName: String {
        switch self {
        case .anthropic: "Claude"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai: "sk-…"
        case .gemini: "AIza…"
        }
    }

    var consoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    /// Keychain account name for this provider's key.
    var keychainAccount: String { "ai.\(rawValue).apiKey" }

    var client: any ModelListingClient {
        switch self {
        case .anthropic: AnthropicClient()
        case .openai: OpenAIClient()
        case .gemini: GeminiClient()
        }
    }
}

/// Cost/quality tiers. Each analysis stage asks for a tier, never for a model name.
nonisolated enum ModelTier: String, CaseIterable, Identifiable, Codable, Sendable {
    case fast
    case balanced
    case deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .deep: "Deep"
        }
    }

    var purpose: String {
        switch self {
        case .fast: "News classification, reading computed features, verifier checks, alert wording."
        case .balanced: "Event impact, sector news, connected products, 1-week outlook, daily position reviews."
        case .deep: "Multi-year history and the final buy/sell verdict with the trade plan."
        }
    }

    var symbolName: String {
        switch self {
        case .fast: "hare"
        case .balanced: "scalemass"
        case .deep: "brain"
        }
    }
}

/// A model returned by a provider's live "list models" endpoint.
nonisolated struct AIModelInfo: Identifiable, Hashable, Codable, Sendable {
    var provider: AIProviderKind
    /// Exact API model ID, e.g. as returned by the provider.
    var modelID: String
    var displayName: String
    var createdAt: Date?
    var inputTokenLimit: Int?
    var outputTokenLimit: Int?

    var id: String { "\(provider.rawValue):\(modelID)" }
}

/// A user's choice of model for a tier.
nonisolated struct ModelRef: Hashable, Codable, Sendable {
    var provider: AIProviderKind
    var modelID: String
}

nonisolated enum AIProviderError: LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case rateLimited
    case http(status: Int, message: String)
    case decoding(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "No API key saved for this provider."
        case .invalidKey: "The provider rejected this key. Check it was copied completely and is active."
        case .rateLimited: "The provider is rate-limiting requests. Try again in a minute."
        case .http(let status, let message): "Provider error \(status): \(message)"
        case .decoding(let detail): "Unexpected response from the provider (\(detail))."
        case .network(let detail): "Network problem: \(detail)"
        }
    }
}

/// Anything that can list a provider's available models.
nonisolated protocol ModelListingClient: Sendable {
    func listModels(apiKey: String) async throws -> [AIModelInfo]
}

// MARK: - Shared HTTP helper

nonisolated enum ProviderHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral // no disk cache of responses that carry keys
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "SCORE1000-iOS"]
        return URLSession(configuration: config)
    }()

    static func get(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.network("No HTTP response")
        }
        try check(status: http.statusCode, body: data)
        return data
    }

    static func check(status: Int, body: Data) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw AIProviderError.invalidKey
        case 429: throw AIProviderError.rateLimited
        default: throw AIProviderError.http(status: status, message: errorMessage(from: body))
        }
    }

    /// Pulls `error.message` (Anthropic, OpenAI, Gemini all use this shape) or falls back to raw text.
    static func errorMessage(from body: Data) -> String {
        if let env = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: body), let msg = env.error?.message {
            return msg
        }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }
}

nonisolated struct ProviderErrorEnvelope: Decodable {
    nonisolated struct Inner: Decodable { let message: String? }
    let error: Inner?
}

// MARK: - Tier suggestion

nonisolated enum TierSuggester {
    /// Heuristic tier for a model ID. Returns nil when the name gives no clear signal.
    static func tier(for modelID: String) -> ModelTier? {
        let id = modelID.lowercased()
        let fast = ["haiku", "nano", "-mini", "flash-lite", "-lite", "luna"] // "-mini", not "mini": "gemini" contains "mini"
        let deep = ["opus", "-pro", "astra", "argon"]
        let balanced = ["sonnet", "flash", "-sol"]
        if fast.contains(where: { id.contains($0) }) { return .fast }
        if deep.contains(where: { id.contains($0) }) { return .deep }
        if balanced.contains(where: { id.contains($0) }) { return .balanced }
        return nil
    }

    /// Picks the newest model per tier, preferring providers in the given order.
    static func defaultAssignments(
        from models: [AIModelInfo],
        providerOrder: [AIProviderKind] = AIProviderKind.allCases
    ) -> [ModelTier: ModelRef] {
        var result: [ModelTier: ModelRef] = [:]
        for tier in ModelTier.allCases {
            for provider in providerOrder {
                let candidates = models
                    .filter { $0.provider == provider && Self.tier(for: $0.modelID) == tier }
                    .sorted(by: newerFirst)
                if let best = candidates.first {
                    result[tier] = ModelRef(provider: best.provider, modelID: best.modelID)
                    break
                }
            }
        }
        return result
    }

    static func newerFirst(_ a: AIModelInfo, _ b: AIModelInfo) -> Bool {
        switch (a.createdAt, b.createdAt) {
        case let (da?, db?) where da != db: return da > db
        default: return a.modelID.localizedStandardCompare(b.modelID) == .orderedDescending
        }
    }
}
