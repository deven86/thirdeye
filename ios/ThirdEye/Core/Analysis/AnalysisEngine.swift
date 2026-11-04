import Foundation
import Observation

/// Runs one 10-stage analysis: fetch data → compute feature packs → stages 1–9 (≤ 2 at a time)
/// → stage 10 → trade plan (code) → verifier → scoring (code) → save.
@Observable
final class AnalysisEngine {
    enum Phase: Equatable {
        case idle
        case fetchingData
        case runningStages
        case finalStage
        case verifying
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var stageStatus: [Int: StageStatus] = [:]
    private(set) var run: AnalysisRun?
    private(set) var runningCost: Double = 0
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .fetchingData, .runningStages, .finalStage, .verifying: true
        default: false
        }
    }

    struct Context {
        var market: MarketStore
        var settings: AppSettings
        var store: AnalysisStore
    }

    /// Missing setup that blocks a run (e.g. no model for a tier).
    static func blockers(settings: AppSettings) -> [String] {
        var out: [String] = []
        for tier in ModelTier.allCases where settings.tierAssignments[tier] == nil {
            out.append("Choose a \(tier.title) model in Settings → Model Tiers.")
        }
        let keychain = KeychainStore()
        for ref in Set(settings.tierAssignments.values.map(\.provider)) where !keychain.contains(ref.keychainAccount) {
            out.append("Add your \(ref.displayName) key in Settings → AI Providers.")
        }
        return out
    }

    /// Rough per-run estimate from the stage token budgets and current tier models.
    static func estimate(settings: AppSettings) -> Double {
        var total = 0.0
        for s in StageSpec.all {
            guard let model = settings.tierAssignments[s.tier]?.modelID else { continue }
            let input = s.packs.isEmpty ? 3_000 : 2_500 + 2_000 * s.packs.count
            let searchTokens = s.webSearch ? 6_000 * s.maxSearches : 0
            total += Pricing.cost(AIUsage(inputTokens: input + searchTokens, outputTokens: s.maxTokens / 2,
                                          webSearches: s.webSearch ? s.maxSearches : 0), model: model)
        }
        if let fast = settings.tierAssignments[.fast]?.modelID {
            total += Pricing.cost(AIUsage(inputTokens: 2_000, outputTokens: 300), model: fast) // verifier
        }
        return total
    }

    func start(instrument: Instrument, profile: HoldingProfile, context: Context) {
        guard !isRunning else { return }
        stageStatus = Dictionary(uniqueKeysWithValues: StageSpec.all.map { ($0.id, .pending) })
        runningCost = 0
        run = AnalysisRun(id: UUID(), instrument: instrument, profile: profile, startedAt: Date(), finishedAt: nil,
                          lastPrice: nil, stages: [], composite: nil, verdict: nil, vetoes: [], plan: nil,
                          verifierNotes: [], totalCostUSD: 0, promptVersion: StageSpec.promptVersion, featurePackHash: "")
        task = Task { await execute(instrument: instrument, profile: profile, context: context) }
    }

    func cancel() {
        task?.cancel()
        phase = .failed("Cancelled.")
    }

    // MARK: - Pipeline

    private func execute(instrument: Instrument, profile: HoldingProfile, context: Context) async {
        // 1. Data → feature packs (computed in code).
        phase = .fetchingData
        var packs: [Timeframe: String] = [:]
        var featureIDs = Set<String>()
        var snapshots: [Timeframe: FeatureEngine.Snapshot] = [:]
        var lastCandle: Candle?
        var dataErrors: [String] = []
        for tf in [Timeframe.mo1, .w1, .d1, .h1, .m15] {
            do {
                let candles = try await context.market.candles(for: instrument, timeframe: tf)
                if tf == .d1 || lastCandle == nil || (candles.last?.time ?? .distantPast) > (lastCandle?.time ?? .distantPast) {
                    if let l = candles.last { lastCandle = l }
                }
                if let snap = await Task.detached(priority: .userInitiated, operation: { FeatureEngine.snapshot(candles, timeframe: tf) }).value {
                    snapshots[tf] = snap
                    packs[tf] = FeatureEngine.featurePackJSON(snap, instrument: instrument)
                    featureIDs.formUnion(snap.features.map(\.id))
                }
            } catch {
                dataErrors.append("\(tf.label): \(error.localizedDescription)")
            }
            if Task.isCancelled { return }
        }
        guard !packs.isEmpty, let lastCandle else {
            phase = .failed(dataErrors.first ?? "No price data for this product.")
            return
        }
        run?.lastPrice = lastCandle.close
        run?.featurePackHash = String(packs.values.sorted().joined().hashValue, radix: 16)

        // 2. Stages 1–9, two at a time (keeps within typical new-account rate limits).
        phase = .runningStages
        var results: [StageResult] = []
        let specs = StageSpec.all.filter { $0.id <= 9 }
        let settings = context.settings
        // Build every job on the main actor first; child tasks receive only Sendable values.
        let jobs: [(spec: StageSpec, prompt: String, ref: ModelRef?)] = specs.map { spec in
            (spec,
             Prompts.user(spec: spec, instrument: instrument, profile: profile, lastPrice: lastCandle.close,
                          packs: packs, priorStages: [], today: Date()),
             settings.tierAssignments[spec.tier])
        }
        let ids = featureIDs
        await withTaskGroup(of: StageResult.self) { group in
            var next = 0
            while next < min(2, jobs.count) {
                let job = jobs[next]
                stageStatus[job.spec.id] = .running
                group.addTask { await AnalysisEngine.runStage(job.spec, prompt: job.prompt, ref: job.ref, featureIDs: ids) }
                next += 1
            }
            for await result in group {
                results.append(result)
                stageStatus[result.stage] = result.status
                runningCost += result.costUSD
                run?.stages = results.sorted { $0.stage < $1.stage }
                if next < jobs.count, !Task.isCancelled {
                    let job = jobs[next]
                    stageStatus[job.spec.id] = .running
                    group.addTask { await AnalysisEngine.runStage(job.spec, prompt: job.prompt, ref: job.ref, featureIDs: ids) }
                    next += 1
                }
            }
        }
        if Task.isCancelled { return }

        // 3. Stage 10.
        phase = .finalStage
        let spec10 = StageSpec.spec(10)
        stageStatus[10] = .running
        let prompt10 = Prompts.user(spec: spec10, instrument: instrument, profile: profile, lastPrice: lastCandle.close,
                                    packs: packs, priorStages: results, today: Date())
        let final = await Self.runStage(spec10, prompt: prompt10, ref: settings.tierAssignments[.deep], featureIDs: featureIDs)
        results.append(final)
        stageStatus[10] = final.status
        runningCost += final.costUSD
        run?.stages = results.sorted { $0.stage < $1.stage }

        // 4. Trade plan in code, then an independent verifier.
        phase = .verifying
        let planSnap = snapshots[profile.planTimeframe] ?? snapshots[.d1] ?? snapshots.values.first
        let atr = planSnap?.features.first { $0.id.hasSuffix(".ATR14") }?.value
        var plan: TradePlan?
        if final.status == .done, let side = final.extra["side"], side == "long" || side == "short",
           let lo = final.extra["entry_low"].flatMap(Double.init), let hi = final.extra["entry_high"].flatMap(Double.init),
           let stop = final.extra["stop_loss"].flatMap(Double.init) {
            let days = final.extra["holding_days"].flatMap(Double.init).map { Int($0) } ?? profile.maxHoldingDays
            plan = TradePlanner.build(.init(side: side, entryLow: lo, entryHigh: hi, stopLoss: stop,
                                            holdingDays: min(days, profile.maxHoldingDays),
                                            invalidation: final.extra["invalidation"] ?? "", rationale: final.summary),
                                      lastPrice: lastCandle.close, atr: atr, tick: instrument.tickSize)
        }
        var verifierNotes: [String] = []
        if var p = plan, let fastRef = settings.tierAssignments[.fast] {
            let facts = planSnap.map { FeatureEngine.featurePackJSON($0, instrument: instrument) } ?? ""
            let (ok, issues, cost) = await Self.verify(plan: p, instrument: instrument, lastPrice: lastCandle.close, facts: facts, ref: fastRef)
            runningCost += cost
            verifierNotes = issues
            if !ok, !issues.isEmpty {
                p.issues.append(contentsOf: issues.prefix(3).map { "Verifier: \($0)" })
                plan = p
            }
        }

        // 5. Score (code only), vetoes, verdict, save.
        let (composite, _) = Scoring.composite(results, profile: profile)
        let vetoes = Scoring.vetoes(stages: results, plan: plan, lastCandleAge: Date().timeIntervalSince(lastCandle.time),
                                    timeframe: profile.planTimeframe, profile: profile)
        var verdict = Scoring.verdict(composite: composite, vetoes: vetoes)
        // A plan direction that contradicts the score is not tradable.
        if let plan, (plan.side == "long" && composite < 620) || (plan.side == "short" && composite > 380) {
            verdict = .noTrade
        }
        run?.composite = composite
        run?.verdict = verdict.rawValue
        run?.vetoes = vetoes + dataErrors.map { "Data: \($0)" }
        run?.plan = plan
        run?.verifierNotes = verifierNotes
        run?.totalCostUSD = runningCost
        run?.finishedAt = Date()
        if let run { context.store.save(run) }
        phase = .done
    }

    // MARK: - One stage (off the main actor)

    nonisolated static func runStage(_ spec: StageSpec, prompt: String, ref: ModelRef?, featureIDs: Set<String>) async -> StageResult {
        guard let ref else { return .unavailable(spec.id, name: spec.name, reason: "No \(spec.tier.title) model selected.") }
        guard let key = try? KeychainStore().get(ref.provider.keychainAccount) else {
            return .unavailable(spec.id, name: spec.name, reason: "No \(ref.provider.displayName) key.")
        }
        let client = ref.provider.chatClient
        let useSearch = spec.webSearch && ref.provider == .anthropic
        var request = AIRequest(system: Prompts.system, user: prompt, maxTokens: spec.maxTokens,
                                webSearch: useSearch, maxSearches: spec.maxSearches,
                                jsonSchema: useSearch || spec.id == 10 || spec.id == 2 ? nil : Prompts.stageSchema)
        var usage = AIUsage()
        var lastError = ""
        // One retry: on invalid JSON the second attempt is told what went wrong.
        for attempt in 0..<2 {
            do {
                let response = try await client.complete(request, model: ref.modelID, apiKey: key)
                usage = usage + response.usage
                let obj = try StageParser.extractObject(response.text)
                let (core, warnings) = StageParser.validate(obj, spec: spec, allowedFeatureIDs: featureIDs,
                                                            searched: response.searchedSources,
                                                            searchAvailable: response.searchAvailable)
                return StageResult(stage: spec.id, name: spec.name, status: .done, score: core.score, direction: core.direction,
                                   confidence: core.confidence, summary: core.summary, reasons: core.reasons,
                                   sources: core.sources, warnings: warnings, provider: ref.provider, model: ref.modelID,
                                   usedWebSearch: useSearch, usage: usage, costUSD: Pricing.cost(usage, model: ref.modelID),
                                   rawOutput: response.text, extra: core.extra)
            } catch let error as StageParser.ParseError {
                lastError = "The model did not return valid JSON (\(error))."
                if attempt == 0 {
                    request.user += "\n\nYour previous reply was not a single valid JSON object. Reply again with ONLY the JSON object."
                }
            } catch {
                lastError = error.localizedDescription
                break
            }
        }
        var failed = StageResult.unavailable(spec.id, name: spec.name, reason: lastError)
        failed.provider = ref.provider
        failed.model = ref.modelID
        failed.usage = usage
        failed.costUSD = Pricing.cost(usage, model: ref.modelID)
        return failed
    }

    nonisolated static func verify(plan: TradePlan, instrument: Instrument, lastPrice: Double, facts: String,
                                   ref: ModelRef) async -> (ok: Bool, issues: [String], cost: Double) {
        guard let key = try? KeychainStore().get(ref.provider.keychainAccount) else { return (true, [], 0) }
        let request = AIRequest(system: Prompts.verifierSystem,
                                user: Prompts.verifierUser(plan: plan, instrument: instrument, lastPrice: lastPrice, facts: facts),
                                maxTokens: 600, jsonSchema: Prompts.verifierSchema)
        do {
            let response = try await ref.provider.chatClient.complete(request, model: ref.modelID, apiKey: key)
            let obj = try StageParser.extractObject(response.text)
            let ok = obj["ok"] as? Bool ?? true
            let issues = ((obj["issues"] as? [Any]) ?? []).compactMap { $0 as? String }
            return (ok, issues, Pricing.cost(response.usage, model: ref.modelID))
        } catch {
            return (true, ["Verifier unavailable: \(error.localizedDescription)"], 0)
        }
    }
}

/// Saves every run (with raw model output) as JSON in Application Support — the audit trail
/// and, from Milestone 8, the data for calibration.
@Observable
final class AnalysisStore {
    private(set) var runs: [AnalysisRun] = []

    private static var dir: URL {
        let d = URL.applicationSupportDirectory.appending(path: "analyses", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() { load() }

    func runs(for instrument: Instrument) -> [AnalysisRun] {
        runs.filter { $0.instrument.id == instrument.id }
    }

    var monthToDateCost: Double {
        let start = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? .distantPast
        return runs.filter { $0.startedAt >= start }.reduce(0) { $0 + $1.totalCostUSD }
    }

    func save(_ run: AnalysisRun) {
        runs.removeAll { $0.id == run.id }
        runs.insert(run, at: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(run) {
            try? data.write(to: Self.dir.appending(path: "\(run.id.uuidString).json"), options: [.atomic, .completeFileProtection])
        }
    }

    func delete(_ run: AnalysisRun) {
        runs.removeAll { $0.id == run.id }
        try? FileManager.default.removeItem(at: Self.dir.appending(path: "\(run.id.uuidString).json"))
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        runs = files.compactMap { try? decoder.decode(AnalysisRun.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
