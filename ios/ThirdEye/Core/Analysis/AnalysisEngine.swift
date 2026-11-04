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
            let searchTokens = s.webSearch ? 12_000 * s.maxSearches : 0
            total += Pricing.cost(AIUsage(inputTokens: input + searchTokens, outputTokens: 1_200,
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

    /// Runs to completion and returns the saved run (used by Hot trades). Honours task cancellation.
    func runAndWait(instrument: Instrument, profile: HoldingProfile, context: Context) async -> AnalysisRun? {
        guard !isRunning else { return nil }
        stageStatus = Dictionary(uniqueKeysWithValues: StageSpec.all.map { ($0.id, .pending) })
        runningCost = 0
        run = AnalysisRun(id: UUID(), instrument: instrument, profile: profile, startedAt: Date(), finishedAt: nil,
                          lastPrice: nil, stages: [], composite: nil, verdict: nil, vetoes: [], plan: nil,
                          verifierNotes: [], totalCostUSD: 0, promptVersion: StageSpec.promptVersion, featurePackHash: "")
        await execute(instrument: instrument, profile: profile, context: context)
        return phase == .done ? run : nil
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
        var planCandles: [Candle] = []
        var dataErrors: [String] = []
        for tf in [Timeframe.mo1, .w1, .d1, .h1, .m15] {
            do {
                let candles = try await context.market.candles(for: instrument, timeframe: tf)
                if tf == profile.planTimeframe { planCandles = candles }
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
        // Slow-changing stages (news, events, leadership, history, sector, connected products) are reused from a
        // recent analysis of the same product and profile — cheaper repeat analyses and Hot-trades scans.
        let reused = Self.reusableStages(for: instrument, profile: profile, hours: settings.stageReuseHours,
                                         runs: context.store.runs, now: Date())
        for s in reused.values { stageStatus[s.stage] = .done }
        // Build every job on the main actor first; child tasks receive only Sendable values.
        let jobs: [(spec: StageSpec, prompt: String, ref: ModelRef?)] = specs.filter { reused[$0.id] == nil }.map { spec in
            (spec,
             Prompts.user(spec: spec, instrument: instrument, profile: profile, lastPrice: lastCandle.close,
                          packs: packs, priorStages: [], today: Date()),
             settings.tierAssignments[spec.tier])
        }
        let ids = featureIDs
        let repairRef = settings.tierAssignments[.fast]
        var abortReason: String?
        await withTaskGroup(of: StageResult.self) { group in
            var next = 0
            while next < min(2, jobs.count) {
                let job = jobs[next]
                stageStatus[job.spec.id] = .running
                group.addTask { await AnalysisEngine.runStage(job.spec, prompt: job.prompt, ref: job.ref, repairRef: repairRef, featureIDs: ids) }
                next += 1
            }
            var fresh: [StageResult] = []
            for await result in group {
                results.append(result)
                fresh.append(result)
                stageStatus[result.stage] = result.status
                runningCost += result.costUSD
                run?.stages = (results + reused.values).sorted { $0.stage < $1.stage }
                // Stop early when the first two stages hit the same request/key error — the rest would too.
                if fresh.count == 2, fresh.allSatisfy({ $0.status == .unavailable }),
                   let reason = fresh.first?.summary, reason == fresh.last?.summary,
                   reason.hasPrefix("Provider error 4") || reason.contains("rejected this key") {
                    abortReason = reason
                }
                if abortReason != nil {
                    while next < jobs.count {
                        let skipped = StageResult.unavailable(jobs[next].spec.id, name: jobs[next].spec.name,
                                                              reason: "Skipped — \(abortReason!)")
                        results.append(skipped)
                        stageStatus[skipped.stage] = .unavailable
                        next += 1
                    }
                    run?.stages = results.sorted { $0.stage < $1.stage }
                    continue
                }
                if next < jobs.count, !Task.isCancelled {
                    let job = jobs[next]
                    stageStatus[job.spec.id] = .running
                    group.addTask { await AnalysisEngine.runStage(job.spec, prompt: job.prompt, ref: job.ref, repairRef: repairRef, featureIDs: ids) }
                    next += 1
                }
            }
        }
        if Task.isCancelled { return }
        results.append(contentsOf: reused.values)
        run?.stages = results.sorted { $0.stage < $1.stage }
        if let abortReason {
            results.append(StageResult.unavailable(10, name: StageSpec.spec(10).name, reason: "Skipped — \(abortReason)"))
            stageStatus[10] = .unavailable
            run?.stages = results.sorted { $0.stage < $1.stage }
            run?.composite = 500
            run?.verdict = Verdict.noTrade.rawValue
            run?.scoringVersion = Scoring.version
            run?.vetoes = ["The AI provider rejected the request: \(abortReason)"]
            run?.totalCostUSD = runningCost
            run?.finishedAt = Date()
            if let run { context.store.save(run) }
            phase = .done
            return
        }

        // 3. Stage 10.
        phase = .finalStage
        let spec10 = StageSpec.spec(10)
        stageStatus[10] = .running
        let prompt10 = Prompts.user(spec: spec10, instrument: instrument, profile: profile, lastPrice: lastCandle.close,
                                    packs: packs, priorStages: results, today: Date(),
                                    canShort: !Scoring.cannotHoldShort(instrument, profile: profile))
        let final = await Self.runStage(spec10, prompt: prompt10, ref: settings.tierAssignments[.deep],
                                        repairRef: settings.tierAssignments[.fast], featureIDs: featureIDs)
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

        // 5. Score, checks and verdict (code only), then the plan's history replay (information only), save.
        let evaluation = Scoring.evaluate(stages: results, plan: plan, lastCandleAge: Date().timeIntervalSince(lastCandle.time),
                                          profile: profile, instrument: instrument)
        var baseRate: PlanReplay.BaseRate?
        if let plan, let atr, atr > 0, snapshots[profile.planTimeframe] != nil, !planCandles.isEmpty {
            let stopATR = min(max(plan.riskPerUnit / atr, 0.25), 6)
            let horizon = PlanReplay.horizonBars(days: plan.holdingDays, timeframe: profile.planTimeframe, instrument: instrument)
            let cost = PlanReplay.roundTripCostPct(instrument)
            let candles = planCandles
            let side = plan.side
            baseRate = await Task.detached(priority: .userInitiated) {
                PlanReplay.baseRate(candles, side: side, stopATR: stopATR, horizon: horizon, costPct: cost)
            }.value
        }
        run?.composite = evaluation.composite
        run?.verdict = evaluation.verdict.rawValue
        run?.vetoes = evaluation.vetoes + dataErrors.map { "Data: \($0)" }
        run?.cautions = evaluation.cautions
        run?.scoringVersion = Scoring.version
        run?.checks = evaluation.checks
        run?.grade = evaluation.grade
        run?.lean = evaluation.lean
        run?.evidence = evaluation.consensus.evidence
        run?.baseRate = baseRate
        run?.watchLevels = Scoring.watchLevels(zones: planSnap?.zones ?? [], lastPrice: lastCandle.close,
                                               lean: evaluation.lean ?? evaluation.side, currency: instrument.currency,
                                               includeShort: !Scoring.cannotHoldShort(instrument, profile: profile))
        run?.plan = plan
        run?.verifierNotes = verifierNotes
        run?.totalCostUSD = runningCost
        run?.finishedAt = Date()
        if let run { context.store.save(run) }
        phase = .done
    }

    // MARK: - Stage reuse

    static let reusableStageIDs: [Int] = [1, 2, 3, 4, 7, 8]

    /// Completed stages from the newest analysis of the same product and profile within `hours`, made with the
    /// same prompts. Never chains (a reused stage is not reused again) and counts no cost.
    nonisolated static func reusableStages(for instrument: Instrument, profile: HoldingProfile, hours: Int,
                                           runs: [AnalysisRun], now: Date) -> [Int: StageResult] {
        guard hours > 0 else { return [:] }
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
        let recent = runs.filter {
            $0.instrument.id == instrument.id && $0.profile == profile && $0.startedAt >= cutoff && $0.startedAt <= now
                && $0.finishedAt != nil && $0.promptVersion == StageSpec.promptVersion
        }.sorted { $0.startedAt > $1.startedAt }
        var out: [Int: StageResult] = [:]
        for id in reusableStageIDs {
            for source in recent {
                guard var s = source.stages.first(where: { $0.stage == id && $0.status == .done }),
                      s.extra["reusedFrom"] == nil else { continue }
                let elapsedDays = Int(now.timeIntervalSince(source.startedAt) / 86_400)
                for key in ["next_major_event_days", "next_macro_event_days"] {
                    if let d = s.extra[key].flatMap(Int.init) { s.extra[key] = String(max(d - elapsedDays, 0)) }
                }
                s.extra["reusedFrom"] = source.id.uuidString
                s.costUSD = 0
                s.usage = AIUsage()
                s.warnings.insert("Reused from the analysis of \(source.startedAt.formatted(date: .abbreviated, time: .shortened)) — no new AI cost.", at: 0)
                out[id] = s
                break
            }
        }
        return out
    }

    // MARK: - One stage (off the main actor)

    nonisolated static func runStage(_ spec: StageSpec, prompt: String, ref: ModelRef?, repairRef: ModelRef?,
                                     featureIDs: Set<String>) async -> StageResult {
        guard let ref else { return .unavailable(spec.id, name: spec.name, reason: "No \(spec.tier.title) model selected.") }
        guard let key = try? KeychainStore().get(ref.provider.keychainAccount) else {
            return .unavailable(spec.id, name: spec.name, reason: "No \(ref.provider.displayName) key.")
        }
        let useSearch = spec.webSearch && ref.provider == .anthropic
        let request = AIRequest(system: Prompts.system, user: prompt, maxTokens: spec.maxTokens,
                                webSearch: useSearch, maxSearches: spec.maxSearches,
                                jsonSchema: useSearch ? nil : Prompts.schema(forStage: spec.id))
        var usage = AIUsage()
        var costUSD = 0.0
        var notes: [String] = []
        let response: AIResponse
        do {
            response = try await ref.provider.chatClient.complete(request, model: ref.modelID, apiKey: key)
        } catch {
            return .unavailable(spec.id, name: spec.name, reason: error.localizedDescription)
        }
        usage = response.usage
        costUSD = Pricing.cost(usage, model: ref.modelID)
        if response.stopReason == "max_tokens" { notes.append("The model's answer hit the length limit and was cut off.") }

        var obj = try? StageParser.extractObject(response.text)
        if obj == nil || obj?["score"] == nil {
            // Cheap repair: a Fast model reformats the draft with guaranteed JSON — no new searches, no new facts.
            if let repairRef, let repairKey = try? KeychainStore().get(repairRef.provider.keychainAccount) {
                let fix = AIRequest(system: Prompts.repairSystem, user: Prompts.repairUser(stage: spec.id, draft: response.text),
                                    maxTokens: 3000, jsonSchema: Prompts.schema(forStage: spec.id))
                if let repaired = try? await repairRef.provider.chatClient.complete(fix, model: repairRef.modelID, apiKey: repairKey) {
                    costUSD += Pricing.cost(repaired.usage, model: repairRef.modelID)
                    usage = usage + repaired.usage
                    if let o = try? StageParser.extractObject(repaired.text), o["score"] != nil {
                        obj = o
                        notes.append("Answer was reformatted by \(repairRef.modelID) (no new facts added).")
                    }
                }
            }
        }
        guard let obj, obj["score"] != nil else {
            var failed = StageResult.unavailable(spec.id, name: spec.name,
                                                 reason: response.stopReason == "max_tokens"
                                                    ? "The answer was cut off before it finished."
                                                    : "The model did not return a usable answer.")
            failed.provider = ref.provider
            failed.model = ref.modelID
            failed.usage = usage
            failed.costUSD = costUSD
            failed.rawOutput = response.text
            return failed
        }
        let (core, warnings) = StageParser.validate(obj, spec: spec, allowedFeatureIDs: featureIDs,
                                                    searched: response.searchedSources,
                                                    searchAvailable: response.searchAvailable)
        return StageResult(stage: spec.id, name: spec.name, status: .done, score: core.score, direction: core.direction,
                           confidence: core.confidence, summary: core.summary, reasons: core.reasons,
                           sources: core.sources, warnings: notes + warnings, provider: ref.provider, model: ref.modelID,
                           usedWebSearch: useSearch, usage: usage, costUSD: costUSD,
                           rawOutput: response.text, extra: core.extra)
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
