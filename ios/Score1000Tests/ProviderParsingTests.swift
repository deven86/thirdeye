import Foundation
import Testing
@testable import Score1000

@Suite("Provider model-list parsing")
struct ProviderParsingTests {
    @Test func anthropicPageParses() throws {
        let json = """
        {
          "data": [
            {"type": "model", "id": "claude-opus-5-5", "display_name": "Claude Opus 5.5", "created_at": "2026-09-01T00:00:00Z"},
            {"type": "model", "id": "claude-haiku-5-5", "display_name": "Claude Haiku 5.5", "created_at": "2026-08-01T00:00:00.000Z"}
          ],
          "has_more": true,
          "first_id": "claude-opus-5-5",
          "last_id": "claude-haiku-5-5"
        }
        """
        let result = try AnthropicClient.parse(Data(json.utf8))
        #expect(result.models.count == 2)
        #expect(result.hasMore)
        #expect(result.lastID == "claude-haiku-5-5")
        #expect(result.models[0].provider == .anthropic)
        #expect(result.models[0].displayName == "Claude Opus 5.5")
        #expect(result.models[0].createdAt != nil)
        #expect(result.models[1].createdAt != nil, "fractional-second timestamps must parse")
    }

    @Test func openAIFiltersNonTextModels() throws {
        let json = """
        {"object": "list", "data": [
          {"id": "gpt-5.5", "object": "model", "created": 1760000000, "owned_by": "openai"},
          {"id": "text-embedding-3-large", "object": "model", "created": 1700000000, "owned_by": "openai"},
          {"id": "whisper-1", "object": "model", "created": 1690000000, "owned_by": "openai"},
          {"id": "gpt-5-nano", "object": "model", "created": 1750000000, "owned_by": "openai"}
        ]}
        """
        let models = try OpenAIClient.parse(Data(json.utf8))
        #expect(models.map(\.modelID).sorted() == ["gpt-5-nano", "gpt-5.5"])
    }

    @Test func geminiKeepsGenerateContentModelsAndStripsPrefix() throws {
        let json = """
        {"models": [
          {"name": "models/gemini-3.1-pro", "displayName": "Gemini 3.1 Pro", "inputTokenLimit": 1048576, "outputTokenLimit": 65536,
           "supportedGenerationMethods": ["generateContent", "countTokens"]},
          {"name": "models/text-embedding-004", "displayName": "Embedding", "supportedGenerationMethods": ["embedContent"]}
        ], "nextPageToken": ""}
        """
        let result = try GeminiClient.parse(Data(json.utf8))
        #expect(result.models.count == 1)
        #expect(result.models[0].modelID == "gemini-3.1-pro")
        #expect(result.models[0].inputTokenLimit == 1_048_576)
    }

    @Test func malformedResponseThrowsDecodingError() {
        #expect(throws: AIProviderError.self) {
            _ = try AnthropicClient.parse(Data("<html>oops</html>".utf8))
        }
    }

    @Test func httpStatusMapping() {
        #expect(throws: AIProviderError.invalidKey) { try ProviderHTTP.check(status: 401, body: Data()) }
        #expect(throws: AIProviderError.rateLimited) { try ProviderHTTP.check(status: 429, body: Data()) }
        let body = Data(#"{"error": {"type": "overloaded_error", "message": "Overloaded"}}"#.utf8)
        #expect(throws: AIProviderError.http(status: 529, message: "Overloaded")) {
            try ProviderHTTP.check(status: 529, body: body)
        }
    }
}

@Suite("Tier suggestions")
struct TierSuggesterTests {
    @Test(arguments: [
        ("claude-haiku-5-5", ModelTier.fast),
        ("claude-sonnet-5-5", .balanced),
        ("claude-opus-5-5", .deep),
        ("gpt-5-nano", .fast),
        ("gemini-2.5-flash-lite", .fast),
        ("gemini-3.8-flash", .balanced),
        ("gemini-3.1-pro", .deep),
    ])
    func knownNames(id: String, expected: ModelTier) {
        #expect(TierSuggester.tier(for: id) == expected)
    }

    @Test func unknownNameHasNoSuggestion() {
        #expect(TierSuggester.tier(for: "gpt-5.5") == nil)
    }

    @Test func defaultAssignmentsPreferNewestAndProviderOrder() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_800_000_000)
        let models = [
            AIModelInfo(provider: .anthropic, modelID: "claude-haiku-4-5", displayName: "", createdAt: old),
            AIModelInfo(provider: .anthropic, modelID: "claude-haiku-5-5", displayName: "", createdAt: new),
            AIModelInfo(provider: .gemini, modelID: "gemini-3.8-flash", displayName: "", createdAt: nil),
            AIModelInfo(provider: .anthropic, modelID: "claude-opus-5-5", displayName: "", createdAt: new),
        ]
        let map = TierSuggester.defaultAssignments(from: models)
        #expect(map[.fast] == ModelRef(provider: .anthropic, modelID: "claude-haiku-5-5"))
        #expect(map[.balanced] == ModelRef(provider: .gemini, modelID: "gemini-3.8-flash"))
        #expect(map[.deep] == ModelRef(provider: .anthropic, modelID: "claude-opus-5-5"))
    }
}

@Suite("Verdict bands")
struct VerdictTests {
    @Test(arguments: [
        (1000, Verdict.strongBuy), (750, .strongBuy), (749, .buy), (620, .buy), (619, .noTrade),
        (381, .noTrade), (380, .sell), (251, .sell), (250, .strongSell), (10, .strongSell),
    ])
    func bandEdges(score: Int, expected: Verdict) {
        #expect(Verdict(composite: score) == expected)
    }
}

@Suite("Settings & secrets")
struct SettingsTests {
    @Test func maskingNeverShowsWholeKey() {
        let masked = maskedSecret("sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ-9f2c")
        #expect(masked == "sk-ant…9f2c")
        #expect(maskedSecret("short") == "•••••")
    }

    @Test func tierAssignmentsPersist() throws {
        let suite = "score1000.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        #expect(first.paperMode, "paper mode must be the default")
        first.tierAssignments[.deep] = ModelRef(provider: .anthropic, modelID: "claude-opus-5-5")
        first.theme = .paper

        let second = AppSettings(defaults: defaults)
        #expect(second.tierAssignments[.deep]?.modelID == "claude-opus-5-5")
        #expect(second.theme == .paper)
    }

    @Test func fillMissingTiersKeepsUserChoices() throws {
        let suite = "score1000.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let mine = ModelRef(provider: .openai, modelID: "gpt-5.5")
        settings.tierAssignments[.deep] = mine
        settings.fillMissingTiers(from: [
            AIModelInfo(provider: .anthropic, modelID: "claude-opus-5-5", displayName: "", createdAt: nil),
            AIModelInfo(provider: .anthropic, modelID: "claude-haiku-5-5", displayName: "", createdAt: nil),
        ])
        #expect(settings.tierAssignments[.deep] == mine)
        #expect(settings.tierAssignments[.fast]?.modelID == "claude-haiku-5-5")
    }
}
