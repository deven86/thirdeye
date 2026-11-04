import Foundation

/// Turns raw model text into a validated `StageResult`. Nothing reaches the UI without passing through here.
nonisolated enum StageParser {
    nonisolated enum ParseError: Error, Equatable { case noJSON, notAnObject }

    /// Finds the JSON object in a reply (tolerates code fences or stray prose).
    static func extractObject(_ text: String) throws -> [String: Any] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end else { throw ParseError.noJSON }
        let slice = String(t[start...end])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        return obj
    }

    static func normalizeURL(_ s: String) -> String {
        var u = s.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://", "www."] where u.hasPrefix(p) { u.removeFirst(p.count) }
        if u.hasSuffix("/") { u.removeLast() }
        if let hash = u.firstIndex(of: "#") { u = String(u[..<hash]) }
        return u
    }

    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// - allowedFeatureIDs: IDs present in the feature packs this stage received.
    /// - searched: pages the model really retrieved; any other URL is treated as invented and dropped.
    static func validate(_ obj: [String: Any], spec: StageSpec, allowedFeatureIDs: Set<String>,
                         searched: [AISource], searchAvailable: Bool) -> (result: StageResultCore, warnings: [String]) {
        var warnings: [String] = []

        var score = Int((number(obj["score"]) ?? 50).rounded())
        if score < 1 || score > 100 { warnings.append("Score \(score) was outside 1–100 and was clamped."); score = min(max(score, 1), 100) }

        var confidence = number(obj["confidence"]) ?? 0.3
        if confidence > 1, confidence <= 100 { confidence /= 100 }
        confidence = min(max(confidence, 0), 1)

        var direction = (obj["direction"] as? String ?? "neutral").lowercased()
        if !["bullish", "bearish", "neutral"].contains(direction) { direction = "neutral" }
        let implied = score >= 56 ? "bullish" : score <= 44 ? "bearish" : "neutral"
        if direction != implied {
            warnings.append("Model said \(direction) but scored \(score); direction set from the score.")
            direction = implied
        }

        // Sources: keep only pages that were actually retrieved this turn.
        let realURLs = Set(searched.map { normalizeURL($0.url) })
        var sources: [StageSourceRef] = []
        var droppedInvented = 0
        for (i, raw) in ((obj["sources"] as? [[String: Any]]) ?? []).enumerated() {
            guard let url = raw["url"] as? String, !url.isEmpty else { continue }
            guard spec.webSearch, realURLs.contains(normalizeURL(url)) else { droppedInvented += 1; continue }
            let id = (raw["id"] as? String).flatMap { $0.hasPrefix("src:") ? $0 : nil } ?? "src:\(i + 1)"
            let title = raw["title"] as? String ?? searched.first { normalizeURL($0.url) == normalizeURL(url) }?.title ?? url
            sources.append(StageSourceRef(id: id, title: title, url: url, publishedAt: raw["published_at"] as? String))
        }
        if droppedInvented > 0 {
            warnings.append("\(droppedInvented) source\(droppedInvented == 1 ? "" : "s") dropped: not among the pages actually retrieved.")
        }
        let sourceIDs = Set(sources.map(\.id))

        // Reasons: keep only evidence that exists; drop reasons left with none.
        var reasons: [StageReason] = []
        var droppedReasons = 0
        for raw in (obj["reasons"] as? [[String: Any]]) ?? [] {
            guard let point = raw["point"] as? String, !point.isEmpty else { continue }
            let evidence = ((raw["evidence"] as? [Any]) ?? []).compactMap { $0 as? String }
                .filter { allowedFeatureIDs.contains($0) || sourceIDs.contains($0) }
            guard !evidence.isEmpty else { droppedReasons += 1; continue }
            let impact = min(max(Int((number(raw["impact"]) ?? 0).rounded()), -3), 3)
            reasons.append(StageReason(point: point, impact: impact, evidence: evidence))
        }
        if droppedReasons > 0 {
            warnings.append("\(droppedReasons) reason\(droppedReasons == 1 ? "" : "s") dropped for lacking valid evidence.")
        }
        if reasons.isEmpty {
            warnings.append("No reason survived validation — confidence reduced.")
            confidence = min(confidence, 0.15)
        }
        if spec.webSearch && !searchAvailable {
            warnings.append("This provider has no web search; the stage used model knowledge only, which may be outdated.")
            confidence = min(confidence, 0.4)
        }

        var summary = (obj["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = summary.split(separator: " ")
        if words.count > 80 { summary = words.prefix(80).joined(separator: " ") + "…" }

        var extra: [String: String] = [:]
        if let d = number(obj["next_major_event_days"]) { extra["next_major_event_days"] = String(Int(d.rounded())) }
        for key in ["side", "invalidation"] {
            if let v = obj[key] as? String { extra[key] = v }
        }
        for key in ["entry_low", "entry_high", "stop_loss", "holding_days"] {
            if let v = number(obj[key]) { extra[key] = String(v) }
        }
        warnings += ((obj["warnings"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(5)

        return (StageResultCore(score: score, direction: direction, confidence: confidence, summary: summary,
                                reasons: reasons, sources: sources, extra: extra), warnings)
    }
}

nonisolated struct StageResultCore: Sendable, Equatable {
    var score: Int
    var direction: String
    var confidence: Double
    var summary: String
    var reasons: [StageReason]
    var sources: [StageSourceRef]
    var extra: [String: String]
}
