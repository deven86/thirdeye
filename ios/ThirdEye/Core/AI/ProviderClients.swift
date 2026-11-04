import Foundation

// Each client only lists models in M1. Chat/completion calls arrive in M4 behind the same protocol family.
// Parsing is split into static `parse` functions so it can be unit-tested without network access.

// MARK: - Anthropic

nonisolated struct AnthropicClient: ModelListingClient {
    static let baseURL = URL(string: "https://api.anthropic.com/v1/models")!
    static let apiVersion = "2023-06-01"

    nonisolated struct Page: Decodable {
        nonisolated struct Model: Decodable {
            let id: String
            let display_name: String?
            let created_at: String?
            let max_input_tokens: Int?
            let max_tokens: Int?
        }
        let data: [Model]
        let has_more: Bool?
        let last_id: String?
    }

    func listModels(apiKey: String) async throws -> [AIModelInfo] {
        var all: [AIModelInfo] = []
        var afterID: String?
        for _ in 0..<10 { // hard page cap; providers list well under 1,000 models
            var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { items.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = items
            var request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
            let data = try await ProviderHTTP.get(request)
            let (models, more, last) = try Self.parse(data)
            all += models
            guard more, let last else { break }
            afterID = last
        }
        return all
    }

    static func parse(_ data: Data) throws -> (models: [AIModelInfo], hasMore: Bool, lastID: String?) {
        let page: Page
        do { page = try JSONDecoder().decode(Page.self, from: data) } catch {
            throw AIProviderError.decoding("Anthropic models list")
        }
        let models = page.data.map {
            AIModelInfo(provider: .anthropic,
                        modelID: $0.id,
                        displayName: $0.display_name ?? $0.id,
                        createdAt: $0.created_at.flatMap(ISODate.parse),
                        inputTokenLimit: $0.max_input_tokens,
                        outputTokenLimit: $0.max_tokens)
        }
        return (models, page.has_more ?? false, page.last_id)
    }
}

// MARK: - OpenAI

nonisolated struct OpenAIClient: ModelListingClient {
    static let baseURL = URL(string: "https://api.openai.com/v1/models")!

    nonisolated struct Page: Decodable {
        nonisolated struct Model: Decodable {
            let id: String
            let created: Double?
        }
        let data: [Model]
    }

    /// OpenAI lists every model type; keep text-generation ones only.
    static let excludedFragments = [
        "embedding", "whisper", "tts", "dall-e", "moderation", "image", "audio",
        "realtime", "transcribe", "search-preview", "davinci", "babbage", "sora", "computer-use",
    ]

    func listModels(apiKey: String) async throws -> [AIModelInfo] {
        var request = URLRequest(url: Self.baseURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try Self.parse(try await ProviderHTTP.get(request))
    }

    static func parse(_ data: Data) throws -> [AIModelInfo] {
        let page: Page
        do { page = try JSONDecoder().decode(Page.self, from: data) } catch {
            throw AIProviderError.decoding("OpenAI models list")
        }
        return page.data
            .filter { model in
                let id = model.id.lowercased()
                return !excludedFragments.contains(where: { id.contains($0) })
            }
            .map {
                AIModelInfo(provider: .openai,
                            modelID: $0.id,
                            displayName: $0.id,
                            createdAt: $0.created.map { Date(timeIntervalSince1970: $0) },
                            inputTokenLimit: nil,
                            outputTokenLimit: nil)
            }
    }
}

// MARK: - Google Gemini

nonisolated struct GeminiClient: ModelListingClient {
    static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    nonisolated struct Page: Decodable {
        nonisolated struct Model: Decodable {
            let name: String
            let displayName: String?
            let inputTokenLimit: Int?
            let outputTokenLimit: Int?
            let supportedGenerationMethods: [String]?
        }
        let models: [Model]?
        let nextPageToken: String?
    }

    func listModels(apiKey: String) async throws -> [AIModelInfo] {
        var all: [AIModelInfo] = []
        var pageToken: String?
        for _ in 0..<10 {
            var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            var request = URLRequest(url: components.url!)
            // Header, not query string, so the key never appears in URLs or logs.
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (models, next) = try Self.parse(try await ProviderHTTP.get(request))
            all += models
            guard let next, !next.isEmpty else { break }
            pageToken = next
        }
        return all
    }

    static func parse(_ data: Data) throws -> (models: [AIModelInfo], nextPageToken: String?) {
        let page: Page
        do { page = try JSONDecoder().decode(Page.self, from: data) } catch {
            throw AIProviderError.decoding("Gemini models list")
        }
        let models = (page.models ?? [])
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .filter { !$0.name.lowercased().contains("embedding") && !$0.name.lowercased().contains("image") }
            .map { model -> AIModelInfo in
                let id = model.name.hasPrefix("models/") ? String(model.name.dropFirst("models/".count)) : model.name
                return AIModelInfo(provider: .gemini,
                                   modelID: id,
                                   displayName: model.displayName ?? id,
                                   createdAt: nil,
                                   inputTokenLimit: model.inputTokenLimit,
                                   outputTokenLimit: model.outputTokenLimit)
            }
        return (models, page.nextPageToken)
    }
}

// MARK: - Dates

nonisolated enum ISODate {
    static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
