import Foundation
import Observation

/// Runs one Extra Search on a finished analysis: bull and bear cases in parallel (Balanced model), then a judge
/// (Deep model) that also sees code-computed disagreements and the product's track record. About 3 AI calls,
/// no web search. Reads the analysis; never changes it.
@Observable
final class ExtraSearchEngine {
    enum Phase: Equatable {
        case idle
        case debating
        case judging
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var result: ExtraSearchResult?
    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .debating || phase == .judging }

    /// Models needed: Balanced for the two cases, Deep for the judge.
    static func blockers(settings: AppSettings) -> [String] {
        var out: [String] = []
        for tier in [ModelTier.balanced, .deep] where settings.tierAssignments[tier] == nil {
            out.append("Choose a \(tier.title) model in Settings → Model Tiers.")
        }
        let keychain = KeychainStore()
        let refs = [ModelTier.balanced, .deep].compactMap { settings.tierAssignments[$0] }
        for ref in Set(refs.map(\.provider)) where !keychain.contains(ref.keychainAccount) {
            out.append("Add your \(ref.displayName) key in Settings → AI Providers.")
        }
        return out
    }

    /// Rough estimate: two cases (~7k tokens in, 900 out) and a judge (~10k in, 1.2k out).
    static func estimate(settings: AppSettings) -> Double {
        var total = 0.0
        if let m = settings.tierAssignments[.balanced]?.modelID {
            total += 2 * Pricing.cost(AIUsage(inputTokens: 7_000, outputTokens: 900), model: m)
        }
        if let m = settings.tierAssignments[.deep]?.modelID {
            total += Pricing.cost(AIUsage(inputTokens: 10_000, outputTokens: 1_200), model: m)
        }
        return total
    }

    func start(_ run: AnalysisRun, settings: AppSettings, store: ExtraSearchStore, analyses: AnalysisStore, outcomes: OutcomeStore) {
        guard !isRunning else { return }
        task = Task { await execute(run, settings: settings, store: store, analyses: analyses, outcomes: outcomes) }
    }

    func cancel() {
        task?.cancel()
        phase = .failed("Cancelled.")
    }

    private func execute(_ run: AnalysisRun, settings: AppSettings, store: ExtraSearchStore,
                         analyses: AnalysisStore, outcomes: OutcomeStore) async {
        result = nil
        let leans = ExtraConflicts.leans(run.stages, profile: run.profile)
        let conflicts = ExtraConflicts.conflicts(run.stages, profile: run.profile)
        let memoryItems = DecisionMemory.items(for: run.instrument, excluding: run.id, runs: analyses.runs,
                                               outcomes: outcomes.outcomes, extras: store.results)
        let memoryText = DecisionMemory.promptText(memoryItems, card: ReportCard.build(runs: analyses.runs, outcomes: outcomes.outcomes))
        var out = ExtraSearchResult(id: UUID(), runID: run.id, instrumentID: run.instrument.id, createdAt: Date(),
                                    normalComposite: run.composite ?? 500, normalVerdict: run.verdict ?? Verdict.noTrade.rawValue,
                                    spread: ExtraSpread.points(run.stages, profile: run.profile), leans: leans,
                                    conflicts: conflicts, memory: memoryItems, bull: nil, bear: nil, judge: nil,
                                    failures: [], totalCostUSD: 0, promptVersion: ExtraPrompts.version)

        // 1. Bull and bear in parallel.
        phase = .debating
        let balanced = settings.tierAssignments[.balanced]
        let bullPrompt = ExtraPrompts.advocateUser(run, bull: true)
        let bearPrompt = ExtraPrompts.advocateUser(run, bull: false)
        async let bullCall = Self.call(system: ExtraPrompts.advocateSystem(bull: true), user: bullPrompt,
                                       schema: ExtraPrompts.advocateSchema, maxTokens: 1_500, ref: balanced)
        async let bearCall = Self.call(system: ExtraPrompts.advocateSystem(bull: false), user: bearPrompt,
                                       schema: ExtraPrompts.advocateSchema, maxTokens: 1_500, ref: balanced)
        let (bullReply, bearReply) = await (bullCall, bearCall)
        if Task.isCancelled { return }
        for (reply, bull) in [(bullReply, true), (bearReply, false)] {
            out.totalCostUSD += reply.cost
            if let text = reply.text, let parsed = ExtraPrompts.parseCase(text, bull: bull, model: balanced?.modelID, cost: reply.cost) {
                if bull { out.bull = parsed } else { out.bear = parsed }
            } else {
                out.failures.append("\(bull ? "Bull" : "Bear") case: \(reply.error ?? "the model did not return a usable answer.")")
            }
        }
        guard out.bull != nil || out.bear != nil else {
            out.failures.append("Judge skipped — neither case was available.")
            result = out
            store.save(out)
            phase = .failed(out.failures.first ?? "Extra Search failed.")
            return
        }

        // 2. Judge.
        phase = .judging
        let deep = settings.tierAssignments[.deep]
        let judgeReply = await Self.call(system: ExtraPrompts.judgeSystem,
                                         user: ExtraPrompts.judgeUser(run, bull: out.bull, bear: out.bear, conflicts: conflicts,
                                                                      leans: leans, memory: memoryText),
                                         schema: ExtraPrompts.judgeSchema, maxTokens: 2_000, ref: deep)
        if Task.isCancelled { return }
        out.totalCostUSD += judgeReply.cost
        if let text = judgeReply.text, let j = ExtraPrompts.parseJudgement(text, model: deep?.modelID, cost: judgeReply.cost) {
            out.judge = j
        } else {
            out.failures.append("Judge: \(judgeReply.error ?? "the model did not return a usable answer.")")
        }
        result = out
        store.save(out)
        phase = out.judge == nil ? .failed(out.failures.last ?? "Extra Search failed.") : .done
    }

    /// One JSON-mode call off the main actor, with one retry for overloaded/rate-limited answers.
    nonisolated static func call(system: String, user: String, schema: JSONValue, maxTokens: Int,
                                 ref: ModelRef?) async -> (text: String?, cost: Double, error: String?) {
        guard let ref else { return (nil, 0, "no model selected.") }
        guard let key = try? KeychainStore().get(ref.provider.keychainAccount) else {
            return (nil, 0, "no \(ref.provider.displayName) key.")
        }
        let request = AIRequest(system: system, user: user, maxTokens: maxTokens, jsonSchema: schema)
        var lastError = ""
        for attempt in 0..<2 {
            do {
                let r = try await ref.provider.chatClient.complete(request, model: ref.modelID, apiKey: key)
                return (r.text, Pricing.cost(r.usage, model: ref.modelID), nil)
            } catch {
                lastError = error.localizedDescription
                if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        return (nil, 0, lastError)
    }
}

/// Saved Extra Searches (Application Support/extra-searches, complete file protection). Separate from the
/// normal analyses folder, so turning the feature off or deleting these never touches an analysis.
@Observable
final class ExtraSearchStore {
    private(set) var results: [ExtraSearchResult] = []

    private static var dir: URL {
        let d = URL.applicationSupportDirectory.appending(path: "extra-searches", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() { load() }

    func latest(for runID: UUID) -> ExtraSearchResult? {
        results.filter { $0.runID == runID }.max { $0.createdAt < $1.createdAt }
    }

    var monthToDateCost: Double {
        let start = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? .distantPast
        return results.filter { $0.createdAt >= start }.reduce(0) { $0 + $1.totalCostUSD }
    }

    func save(_ r: ExtraSearchResult) {
        results.removeAll { $0.id == r.id }
        results.insert(r, at: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(r) {
            try? data.write(to: Self.dir.appending(path: "\(r.id.uuidString).json"), options: [.atomic, .completeFileProtection])
        }
    }

    func delete(_ r: ExtraSearchResult) {
        results.removeAll { $0.id == r.id }
        try? FileManager.default.removeItem(at: Self.dir.appending(path: "\(r.id.uuidString).json"))
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        results = files.compactMap { try? decoder.decode(ExtraSearchResult.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
