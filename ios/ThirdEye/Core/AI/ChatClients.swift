import Foundation

/// One request to a language model. Provider-agnostic; each client maps it to its own API.
nonisolated struct AIRequest: Sendable {
    var system: String
    var user: String
    var maxTokens: Int = 2000
    /// Let the model search the web (Claude only; other providers run without it and say so).
    var webSearch = false
    var maxSearches = 3
    /// JSON Schema for guaranteed-shape output (used when web search is off — the two can't be combined on Claude).
    var jsonSchema: JSONValue?
    /// Not sent: newer Claude models reject `temperature` (deprecated). Kept for future providers.
    var temperature: Double? = nil
}

nonisolated struct AISource: Codable, Hashable, Sendable {
    var url: String
    var title: String
    var pageAge: String?
}

nonisolated struct AIUsage: Codable, Hashable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var webSearches = 0

    static func + (a: AIUsage, b: AIUsage) -> AIUsage {
        AIUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
                cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens, cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
                webSearches: a.webSearches + b.webSearches)
    }
}

nonisolated struct AIResponse: Sendable {
    var text: String
    /// Every page the model actually received from web search — used to reject invented URLs.
    var searchedSources: [AISource]
    var usage: AIUsage
    var model: String
    var searchAvailable: Bool
    /// "end_turn", "max_tokens" (answer was cut off), …
    var stopReason: String? = nil
}

nonisolated protocol ChatClient: Sendable {
    func complete(_ request: AIRequest, model: String, apiKey: String) async throws -> AIResponse
}

extension AIProviderKind {
    nonisolated var chatClient: any ChatClient {
        switch self {
        case .anthropic: AnthropicChat()
        case .openai: OpenAIChat()
        case .gemini: GeminiChat()
        }
    }
}

/// Minimal JSON value so request bodies and schemas stay Sendable.
nonisolated indirect enum JSONValue: Sendable, Equatable {
    case string(String), number(Double), int(Int), bool(Bool), null
    case array([JSONValue]), object([(String, JSONValue)])

    static func == (a: JSONValue, b: JSONValue) -> Bool { a.foundation as? NSObject == b.foundation as? NSObject }

    var foundation: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .int(let i): i
        case .bool(let b): b
        case .null: NSNull()
        case .array(let a): a.map(\.foundation)
        case .object(let o): Dictionary(o.map { ($0.0, $0.1.foundation) }, uniquingKeysWith: { _, b in b })
        }
    }

    func data() throws -> Data { try JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys]) }
}

// MARK: - Shared HTTP with retry

nonisolated enum AIHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180   // deep stages with web search can take a while
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    /// POST with up to 3 retries on 429/5xx/529, honouring `retry-after`.
    static func post(_ url: URL, headers: [String: String], body: Data) async throws -> Data {
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request) } catch {
                if attempt < 2, (error as? URLError)?.code == .timedOut { attempt += 1; continue }
                throw AIProviderError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return data }
            let retryable = status == 429 || status == 529 || (500...599).contains(status)
            if retryable, attempt < 3 {
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                let wait = min(header ?? pow(2, Double(attempt + 1)) * 2, 60)
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
                continue
            }
            try ProviderHTTP.check(status: status, body: data)
            return data
        }
    }
}

// MARK: - Anthropic (Messages API)

nonisolated struct AnthropicChat: ChatClient {
    static let url = URL(string: "https://api.anthropic.com/v1/messages")!

    static func body(_ r: AIRequest, model: String, continuing assistant: [Any]? = nil) -> [String: Any] {
        var messages: [[String: Any]] = [["role": "user", "content": r.user]]
        if let assistant { messages.append(["role": "assistant", "content": assistant]) }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": r.maxTokens,
            // Cache the long, identical system prompt across stages.
            "system": [["type": "text", "text": r.system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages,
        ]
        if r.webSearch {
            body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": r.maxSearches]]
        } else if let schema = r.jsonSchema {
            body["output_config"] = ["format": ["type": "json_schema", "schema": schema.foundation]]
        }
        return body
    }

    func complete(_ r: AIRequest, model: String, apiKey: String) async throws -> AIResponse {
        let headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        var usage = AIUsage()
        var sources: [AISource] = []
        var finalText = ""
        var stop: String?
        var continuation: [Any]?
        // `pause_turn` (long search turns): send the paused content back unchanged, at most twice.
        for _ in 0..<3 {
            let data = try JSONSerialization.data(withJSONObject: Self.body(r, model: model, continuing: continuation))
            let raw = try await AIHTTP.post(Self.url, headers: headers, body: data)
            let parsed = try Self.parse(raw)
            usage = usage + parsed.usage
            sources += parsed.sources
            finalText = parsed.text
            stop = parsed.stopReason
            guard parsed.stopReason == "pause_turn" else { break }
            continuation = (continuation ?? []) + parsed.content
        }
        var seen = Set<String>()
        let unique = sources.filter { seen.insert($0.url).inserted }
        return AIResponse(text: finalText, searchedSources: unique, usage: usage, model: model, searchAvailable: true,
                          stopReason: stop)
    }

    nonisolated struct Parsed { var text: String; var sources: [AISource]; var usage: AIUsage; var stopReason: String?; var content: [Any] }

    /// Text = all `text` blocks after the last search result (the answer), joined.
    static func parse(_ data: Data) throws -> Parsed {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            throw AIProviderError.decoding("Claude response")
        }
        var sources: [AISource] = []
        var answerParts: [String] = []
        for block in content {
            switch block["type"] as? String {
            case "web_search_tool_result":
                answerParts = [] // anything before the last search was "thinking out loud"
                for r in (block["content"] as? [[String: Any]]) ?? [] {
                    if let url = r["url"] as? String {
                        sources.append(AISource(url: url, title: r["title"] as? String ?? url, pageAge: r["page_age"] as? String))
                    }
                }
            case "text":
                if let t = block["text"] as? String { answerParts.append(t) }
                for c in (block["citations"] as? [[String: Any]]) ?? [] {
                    if let url = c["url"] as? String { sources.append(AISource(url: url, title: c["title"] as? String ?? url)) }
                }
            default: break
            }
        }
        let u = root["usage"] as? [String: Any] ?? [:]
        let server = u["server_tool_use"] as? [String: Any] ?? [:]
        let usage = AIUsage(inputTokens: u["input_tokens"] as? Int ?? 0, outputTokens: u["output_tokens"] as? Int ?? 0,
                            cacheReadTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                            cacheWriteTokens: u["cache_creation_input_tokens"] as? Int ?? 0,
                            webSearches: server["web_search_requests"] as? Int ?? 0)
        return Parsed(text: answerParts.joined(), sources: sources, usage: usage,
                      stopReason: root["stop_reason"] as? String, content: content)
    }
}

// MARK: - OpenAI (Chat Completions, JSON mode, no web search)

nonisolated struct OpenAIChat: ChatClient {
    static let url = URL(string: "https://api.openai.com/v1/chat/completions")!

    func complete(_ r: AIRequest, model: String, apiKey: String) async throws -> AIResponse {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": r.system], ["role": "user", "content": r.user]],
            "max_completion_tokens": r.maxTokens,
            "response_format": ["type": "json_object"],
        ]
        let raw = try await AIHTTP.post(Self.url, headers: ["Authorization": "Bearer \(apiKey)"],
                                        body: try JSONSerialization.data(withJSONObject: body))
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw AIProviderError.decoding("OpenAI response") }
        let u = root["usage"] as? [String: Any] ?? [:]
        return AIResponse(text: message["content"] as? String ?? "", searchedSources: [],
                          usage: AIUsage(inputTokens: u["prompt_tokens"] as? Int ?? 0, outputTokens: u["completion_tokens"] as? Int ?? 0),
                          model: model, searchAvailable: false)
    }
}

// MARK: - Google Gemini (generateContent, JSON mode, no web search)

nonisolated struct GeminiChat: ChatClient {
    func complete(_ r: AIRequest, model: String, apiKey: String) async throws -> AIResponse {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": r.system]]],
            "contents": [["role": "user", "parts": [["text": r.user]]]],
            "generationConfig": ["responseMimeType": "application/json", "maxOutputTokens": r.maxTokens],
        ]
        let raw = try await AIHTTP.post(url, headers: ["x-goog-api-key": apiKey],
                                        body: try JSONSerialization.data(withJSONObject: body))
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let cand = (root["candidates"] as? [[String: Any]])?.first,
              let content = cand["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw AIProviderError.decoding("Gemini response") }
        let u = root["usageMetadata"] as? [String: Any] ?? [:]
        return AIResponse(text: parts.compactMap { $0["text"] as? String }.joined(), searchedSources: [],
                          usage: AIUsage(inputTokens: u["promptTokenCount"] as? Int ?? 0, outputTokens: u["candidatesTokenCount"] as? Int ?? 0),
                          model: model, searchAvailable: false)
    }
}
