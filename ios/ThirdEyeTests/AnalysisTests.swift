import Foundation
import Testing
@testable import ThirdEye

@Suite("Claude response parsing")
struct ClaudeResponseTests {
    /// Shape from Anthropic's web-search docs: thinking text → search → results → cited answer.
    static let webSearchResponse = """
    {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-5-5","stop_reason":"end_turn",
     "content":[
      {"type":"text","text":"I'll search for recent news."},
      {"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"Reliance news"}},
      {"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[
         {"type":"web_search_result","url":"https://www.example-news.com/reliance-q2","title":"Reliance Q2 results","page_age":"2 days ago","encrypted_content":"x"},
         {"type":"web_search_result","url":"https://another.example.org/jio","title":"Jio tariff hike","encrypted_content":"y"}]},
      {"type":"text","text":"{\\"stage\\":1,\\"score\\":","citations":[{"type":"web_search_result_location","url":"https://www.example-news.com/reliance-q2","title":"Reliance Q2 results","cited_text":"..."}]},
      {"type":"text","text":"64}"}],
     "usage":{"input_tokens":5200,"output_tokens":410,"cache_read_input_tokens":1800,"cache_creation_input_tokens":0,
              "server_tool_use":{"web_search_requests":2}}}
    """

    @Test func parsesAnswerSourcesAndUsage() throws {
        let p = try AnthropicChat.parse(Data(Self.webSearchResponse.utf8))
        #expect(p.text == "{\"stage\":1,\"score\":64}", "only text after the last search result, joined")
        #expect(Set(p.sources.map(\.url)).count == 2)
        #expect(p.usage.webSearches == 2)
        #expect(p.usage.inputTokens == 5200)
        #expect(p.usage.cacheReadTokens == 1800)
        #expect(p.stopReason == "end_turn")
    }

    @Test func requestBodyUsesSearchOrSchemaNeverBoth() throws {
        var r = AIRequest(system: "s", user: "u", webSearch: true, maxSearches: 3, jsonSchema: Prompts.stageSchema)
        let withSearch = AnthropicChat.body(r, model: "claude-haiku-5-5")
        #expect(withSearch["tools"] != nil)
        #expect(withSearch["output_config"] == nil, "structured output cannot be combined with web-search citations")
        r.webSearch = false
        let withSchema = AnthropicChat.body(r, model: "claude-haiku-5-5")
        #expect(withSchema["tools"] == nil)
        let config = try #require(withSchema["output_config"] as? [String: Any])
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(try JSONSerialization.data(withJSONObject: withSchema).count > 0, "body must be valid JSON")
        #expect(withSchema["temperature"] == nil && withSearch["temperature"] == nil,
                "Claude 5.x models reject `temperature` (400: deprecated for this model)")
    }

    @Test func schemaAvoidsUnsupportedKeywords() throws {
        let json = String(decoding: try Prompts.stageSchema.data(), as: UTF8.self)
        for banned in ["minimum", "maximum", "minLength", "maxLength", "maxItems"] {
            #expect(!json.contains("\"\(banned)\""), "Claude structured outputs reject \(banned)")
        }
        #expect(json.contains("\"additionalProperties\":false"))
    }
}

@Suite("Stage validation")
struct StageParserTests {
    let spec = StageSpec.spec(1)
    let searched = [AISource(url: "https://www.example-news.com/reliance-q2", title: "Q2")]

    @Test func extractsJSONFromFencesAndProse() throws {
        let obj = try StageParser.extractObject("Here you go:\n```json\n{\"score\": 70}\n```")
        #expect(obj["score"] as? Int == 70)
        #expect(throws: StageParser.ParseError.noJSON) { try StageParser.extractObject("no json here") }
        let fenced = try StageParser.extractObject("```json\n{\"score\": 55, \"x\": {\"y\": 1}}\n```")
        #expect(fenced["score"] as? Int == 55)
    }

    @Test func extractsLastStageObjectAmongProseAndBraces() throws {
        let text = #"""
        I'll check {the news} first. Interim note: {"draft": true}
        Final answer:
        {"stage":1,"score":61,"summary":"Uses braces } and \"quotes\" inside strings","reasons":[],"sources":[],"warnings":[]}
        Hope this helps.
        """#
        let obj = try StageParser.extractObject(text)
        #expect(obj["score"] as? Int == 61)
        #expect((obj["summary"] as? String)?.contains("braces }") == true)
    }

    @Test func truncatedAnswerIsNotAccepted() {
        #expect(throws: StageParser.ParseError.notAnObject) {
            try StageParser.extractObject(#"{"stage":1,"score":61,"summary":"cut off mid-sente"#)
        }
    }

    @Test func repairSchemaAddsStageFields() throws {
        let s10 = String(decoding: try Prompts.schema(forStage: 10).data(), as: UTF8.self)
        for field in ["side", "entry_low", "entry_high", "stop_loss", "holding_days", "invalidation"] {
            #expect(s10.contains("\"\(field)\""))
        }
        let s2 = String(decoding: try Prompts.schema(forStage: 2).data(), as: UTF8.self)
        #expect(s2.contains("next_major_event_days"))
        let s6 = String(decoding: try Prompts.schema(forStage: 6).data(), as: UTF8.self)
        #expect(!s6.contains("next_major_event_days"))
        #expect(!s10.contains("minimum"))
    }

    @Test func dropsInventedSourcesAndUnsupportedReasons() throws {
        let obj = try StageParser.extractObject("""
        {"stage":1,"score":72,"direction":"bullish","confidence":0.7,"summary":"Strong quarter.",
         "reasons":[
           {"point":"Profit beat estimates","impact":2,"evidence":["src:1"]},
           {"point":"Made-up analyst upgrade","impact":3,"evidence":["src:2"]},
           {"point":"RSI healthy","impact":1,"evidence":["D.RSI14"]},
           {"point":"Vibes","impact":2,"evidence":[]}],
         "sources":[
           {"id":"src:1","title":"Q2","url":"https://example-news.com/reliance-q2/","published_at":"2026-11-02"},
           {"id":"src:2","title":"Fake","url":"https://not-retrieved.example.com/x","published_at":null}],
         "warnings":[]}
        """)
        let (core, warnings) = StageParser.validate(obj, spec: spec, allowedFeatureIDs: ["D.RSI14"],
                                                    searched: searched, searchAvailable: true)
        #expect(core.sources.map(\.id) == ["src:1"], "URL normalisation must match www/trailing slash; invented URL dropped")
        #expect(core.reasons.map(\.point) == ["Profit beat estimates", "RSI healthy"])
        #expect(warnings.contains { $0.contains("dropped: not among the pages") })
        #expect(warnings.contains { $0.contains("lacking valid evidence") })
        #expect(core.score == 72)
    }

    @Test func clampsAndAlignsDirection() throws {
        let obj = try StageParser.extractObject("""
        {"score":140,"direction":"bearish","confidence":80,"summary":"x","reasons":[],"sources":[],"warnings":[]}
        """)
        let (core, warnings) = StageParser.validate(obj, spec: StageSpec.spec(6), allowedFeatureIDs: [], searched: [], searchAvailable: true)
        #expect(core.score == 100)
        #expect(core.direction == "bullish", "direction follows the score")
        #expect(core.confidence <= 0.15, "no surviving reasons → low confidence")
        #expect(warnings.count >= 3)
    }

    @Test func noSearchProviderCapsConfidence() throws {
        let obj = try StageParser.extractObject("""
        {"score":80,"direction":"bullish","confidence":0.9,"summary":"x","reasons":[{"point":"p","impact":2,"evidence":["D.MACD"]}],"sources":[],"warnings":[]}
        """)
        let (core, _) = StageParser.validate(obj, spec: spec, allowedFeatureIDs: ["D.MACD"], searched: [], searchAvailable: false)
        #expect(core.confidence == 0.4)
    }

    @Test func readsStage10PlanFields() throws {
        let obj = try StageParser.extractObject("""
        {"stage":10,"score":75,"direction":"bullish","confidence":0.6,"summary":"Go long.",
         "reasons":[{"point":"Trend up","impact":2,"evidence":["D.SMA50"]}],"sources":[],"warnings":[],
         "side":"long","entry_low":100.5,"entry_high":101.5,"stop_loss":97,"holding_days":20,"invalidation":"Close below 97"}
        """)
        let (core, _) = StageParser.validate(obj, spec: StageSpec.spec(10), allowedFeatureIDs: ["D.SMA50"], searched: [], searchAvailable: true)
        #expect(core.extra["side"] == "long")
        #expect(core.extra["stop_loss"] == "97.0")
        #expect(core.extra["holding_days"] == "20.0")
    }
}

@Suite("Scoring & plan")
struct ScoringTests {
    func stage(_ n: Int, _ score: Int, conf: Double = 1, status: StageStatus = .done, extra: [String: String] = [:]) -> StageResult {
        StageResult(stage: n, name: "S\(n)", status: status, score: score, direction: "neutral", confidence: conf,
                    summary: "", reasons: [], sources: [], warnings: [], provider: .anthropic, model: "m",
                    usedWebSearch: false, usage: AIUsage(), costUSD: 0, rawOutput: "", extra: extra)
    }

    @Test func allNinetyAtFullConfidenceIs900() {
        let stages = (1...10).map { stage($0, 90) }
        #expect(Scoring.composite(stages, profile: .equal).value == 900)
        #expect(Scoring.composite(stages, profile: .swing).value == 900, "any weights summing to 100 give 900")
    }

    @Test func lowConfidencePullsTowardNeutral() {
        let stages = (1...10).map { stage($0, 90, conf: 0.5) }
        // effective = 50 + 0.5 × 40 = 70 → 700
        #expect(Scoring.composite(stages, profile: .equal).value == 700)
    }

    @Test func unavailableStagesCountAsNeutralAndVeto() {
        var stages = (1...10).map { stage($0, 90) }
        for i in 0..<4 { stages[i].status = .unavailable }
        let c = Scoring.composite(stages, profile: .equal).value
        #expect(c == 740) // 6 × 90 + 4 × 50 = 740
        let v = Scoring.vetoes(stages: stages, plan: nil, lastCandleAge: 60, timeframe: .d1, profile: .equal)
        #expect(v.contains { $0.contains("Only 6 of 10") })
        #expect(Scoring.verdict(composite: c, vetoes: v) == .noTrade)
    }

    @Test func eventInsideHoldingWindowVetoes() {
        var stages = (1...10).map { stage($0, 80) }
        stages[1] = stage(2, 80, extra: ["next_major_event_days": "3"])
        let v = Scoring.vetoes(stages: stages, plan: nil, lastCandleAge: 60, timeframe: .d1, profile: .swing)
        #expect(v.contains { $0.contains("major scheduled event") })
        let late = Scoring.vetoes(stages: [stage(2, 80, extra: ["next_major_event_days": "90"])] + (3...10).map { stage($0, 80) } + [stage(1, 80)],
                                  plan: nil, lastCandleAge: 60, timeframe: .d1, profile: .swing)
        #expect(!late.contains { $0.contains("major scheduled event") })
    }

    @Test func staleDataVetoes() {
        let stages = (1...10).map { stage($0, 80) }
        let v = Scoring.vetoes(stages: stages, plan: nil, lastCandleAge: 10 * 86_400, timeframe: .d1, profile: .swing)
        #expect(v.contains { $0.contains("stale") })
    }

    @Test func ladderFromEntryAndStop() throws {
        let plan = TradePlanner.build(.init(side: "long", entryLow: 99, entryHigh: 101, stopLoss: 95, holdingDays: 20,
                                            invalidation: "", rationale: ""),
                                      lastPrice: 100, atr: 3, tick: 0.05)
        #expect(plan.issues.isEmpty)
        #expect(plan.riskPerUnit == 5)
        #expect(plan.takeProfits.map(\.price) == [105, 110, 115, 120, nil])
        #expect(plan.takeProfits.map(\.bookPercent).reduce(0, +) == 100)
        #expect(plan.badge == .swing)
    }

    @Test func badPlansAreFlagged() {
        let wrongStop = TradePlanner.build(.init(side: "long", entryLow: 99, entryHigh: 101, stopLoss: 102, holdingDays: 5,
                                                 invalidation: "", rationale: ""), lastPrice: 100, atr: 3, tick: nil)
        #expect(wrongStop.issues.contains { $0.contains("not below") })
        let farEntry = TradePlanner.build(.init(side: "short", entryLow: 130, entryHigh: 131, stopLoss: 135, holdingDays: 5,
                                                invalidation: "", rationale: ""), lastPrice: 100, atr: 3, tick: nil)
        #expect(farEntry.issues.contains { $0.contains("3 ATR") })
        let shortPlan = TradePlanner.build(.init(side: "short", entryLow: 100, entryHigh: 100, stopLoss: 104, holdingDays: 5,
                                                 invalidation: "", rationale: ""), lastPrice: 100, atr: 3, tick: nil)
        #expect(shortPlan.takeProfits.first?.price == 96)
    }

    @Test func pricingByPrefix() {
        let cost = Pricing.cost(AIUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, webSearches: 10), model: "claude-opus-5-5")
        #expect(abs(cost - (4 + 20 + 0.10)) < 1e-9)
        #expect(Pricing.price(for: "some-unknown-model").input == Pricing.fallback.input)
    }
}
