import Foundation

/// How long the user intends to hold. Sets stage weights, which timeframes drive the plan,
/// and (later) the monitoring cadence.
nonisolated enum HoldingProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case scalpIntraday = "scalp_intraday"
    case swing
    case positional
    case longTerm = "long_term"
    case equal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scalpIntraday: "Scalp / Intraday"
        case .swing: "Swing"
        case .positional: "Positional"
        case .longTerm: "Long-term"
        case .equal: "Equal weights"
        }
    }

    var subtitle: String {
        switch self {
        case .scalpIntraday: "Minutes to one day · 5m/15m charts lead"
        case .swing: "2 days to 6 weeks · daily and hourly charts lead"
        case .positional: "1–6 months · daily and weekly charts lead"
        case .longTerm: "6 months or more · fundamentals and history lead"
        case .equal: "Your original method: all 10 stages count the same"
        }
    }

    /// Chart the trade plan is built on.
    var planTimeframe: Timeframe {
        switch self {
        case .scalpIntraday: .m15
        case .swing: .d1
        case .positional, .equal: .d1
        case .longTerm: .w1
        }
    }

    /// Default maximum holding period in calendar days (complete-by date).
    var maxHoldingDays: Int {
        switch self {
        case .scalpIntraday: 1
        case .swing: 30
        case .positional: 120
        case .longTerm: 365
        case .equal: 60
        }
    }

    /// Stage weights 1…10 (sum 100). Mirrors shared/config/scoring_weights.json.
    var weights: [Double] {
        switch self {
        case .scalpIntraday: [8, 4, 0, 0, 2, 10, 4, 8, 24, 40]
        case .swing: [10, 8, 3, 4, 10, 15, 8, 8, 14, 20]
        case .positional: [10, 10, 8, 10, 14, 12, 10, 8, 6, 12]
        case .longTerm: [8, 10, 15, 20, 10, 5, 12, 8, 2, 10]
        case .equal: [10, 10, 10, 10, 10, 10, 10, 10, 10, 10]
        }
    }
}

nonisolated enum StageStatus: String, Codable, Sendable {
    case pending, running, done, unavailable
    /// Turned off by the user before the run: not asked, not counted — its weight goes to the other stages.
    case skipped
}

nonisolated struct StageReason: Codable, Hashable, Sendable {
    var point: String
    var impact: Int
    var evidence: [String]
}

nonisolated struct StageSourceRef: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var url: String
    var publishedAt: String?
}

/// Validated output of one stage.
nonisolated struct StageResult: Codable, Hashable, Sendable, Identifiable {
    var stage: Int
    var name: String
    var status: StageStatus
    var score: Int            // 1 bearish … 50 neutral … 100 bullish
    var direction: String
    var confidence: Double    // 0…1
    var summary: String
    var reasons: [StageReason]
    var sources: [StageSourceRef]
    var warnings: [String]
    var provider: AIProviderKind?
    var model: String?
    var usedWebSearch: Bool
    var usage: AIUsage
    var costUSD: Double
    var rawOutput: String     // audit trail
    var extra: [String: String] = [:]

    var id: Int { stage }

    /// Version-1 confidence-shrunk score (low confidence pulls toward 50). Only used to explain older runs.
    var effectiveScore: Double { 50 + confidence * (Double(score) - 50) }

    static func skipped(_ stage: Int, name: String) -> StageResult {
        StageResult(stage: stage, name: name, status: .skipped, score: 50, direction: "neutral", confidence: 0,
                    summary: "Skipped by you — its weight is shared by the other stages.", reasons: [], sources: [], warnings: [],
                    provider: nil, model: nil, usedWebSearch: false, usage: AIUsage(), costUSD: 0, rawOutput: "")
    }

    static func unavailable(_ stage: Int, name: String, reason: String) -> StageResult {
        StageResult(stage: stage, name: name, status: .unavailable, score: 50, direction: "neutral", confidence: 0,
                    summary: reason, reasons: [], sources: [], warnings: [reason], provider: nil, model: nil,
                    usedWebSearch: false, usage: AIUsage(), costUSD: 0, rawOutput: "")
    }
}

nonisolated struct TakeProfit: Codable, Hashable, Sendable {
    var stage: Int
    var price: Double?        // nil = runner with trailing stop
    var rMultiple: Double?
    var bookPercent: Double
    var then: String
}

nonisolated enum HoldingBadge: String, Codable, Sendable {
    case scalp, intraday, shortTerm = "short_term", swing, positional, longTerm = "long_term"

    var title: String {
        switch self {
        case .scalp: "Scalp"
        case .intraday: "Intraday"
        case .shortTerm: "Short-term"
        case .swing: "Swing"
        case .positional: "Positional"
        case .longTerm: "Long-term"
        }
    }

    static func from(days: Int) -> HoldingBadge {
        switch days {
        case ..<1: .intraday
        case 1...10: .shortTerm
        case 11...45: .swing
        case 46...180: .positional
        default: .longTerm
        }
    }
}

nonisolated struct TradePlan: Codable, Hashable, Sendable {
    var side: String          // long / short
    var entryLow: Double
    var entryHigh: Double
    var stopLoss: Double
    var takeProfits: [TakeProfit]
    var riskPerUnit: Double
    var rewardRiskAtTP2: Double
    var holdingDays: Int
    var badge: HoldingBadge
    var completeBy: Date
    var invalidation: String
    var rationale: String
    var issues: [String]      // code + verifier findings; non-empty → no trade

    var entryMid: Double { (entryLow + entryHigh) / 2 }
}

/// One full analysis — persisted for the audit trail and later calibration.
nonisolated struct AnalysisRun: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var instrument: Instrument
    var profile: HoldingProfile
    var startedAt: Date
    var finishedAt: Date?
    var lastPrice: Double?
    var stages: [StageResult]
    var composite: Int?
    var verdict: String?      // Verdict rawValue
    var vetoes: [String]
    var cautions: [String]? = nil
    var plan: TradePlan?
    var verifierNotes: [String]
    var totalCostUSD: Double
    var promptVersion: String
    var featurePackHash: String
    // 0.8+ (absent in older saved runs, so all optional)
    var scoringVersion: Int? = nil
    var checks: [ScoreCheck]? = nil
    var grade: String? = nil
    var lean: String? = nil
    var watchLevels: [String]? = nil
    var evidence: Double? = nil
    var baseRate: PlanReplay.BaseRate? = nil
    // 0.9.1+
    var atr: Double? = nil                 // ATR(14) on the plan's timeframe when analysed
    var planTimeframe: Timeframe? = nil
    var watchBaseline: WatchParams? = nil  // the parameters the trade watch compares against

    /// Stages the user turned off for this run.
    var skippedStages: [Int] { stages.filter { $0.status == .skipped }.map(\.stage) }

    var buyScore: Int? { composite }
    var sellScore: Int? { composite.map { 1010 - $0 } }
}
