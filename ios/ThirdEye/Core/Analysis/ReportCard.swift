import Foundation
import Observation

/// What actually happened after an analysis, measured once its holding period is over.
nonisolated struct AnalysisOutcome: Codable, Hashable, Sendable {
    var runID: UUID
    var gradedAt: Date
    var horizonDays: Int
    var composite: Int              // version-2 score recomputed from the stages, so old and new runs compare
    var startPrice: Double
    var endPrice: Double
    var forwardReturnPct: Double
    var side: String                // where the score pointed: long (≥ 500) or short
    var directionRight: Bool?       // nil when the score was near 500 (no direction)
    var bestPct: Double             // best move in the score's direction during the period, %
    var worstPct: Double            // worst move against it, % (negative)
    var entered: Bool?              // plan runs only: did price reach the entry zone?
    var planR: Double?              // plan runs only: result of the plan, managed with the ladder, in R
    var targetsHit: Int?
    var stopHit: Bool?
}

nonisolated enum OutcomeGrader {
    /// Days to judge an analysis without a plan.
    static func defaultHorizon(_ p: HoldingProfile) -> Int {
        switch p {
        case .scalpIntraday: 1
        case .swing: 10
        case .positional: 60
        case .longTerm: 180
        case .equal: 30
        }
    }

    static func horizonDays(_ run: AnalysisRun) -> Int {
        max(run.plan?.holdingDays ?? defaultHorizon(run.profile), 1)
    }

    static func isDue(_ run: AnalysisRun, now: Date) -> Bool {
        guard run.finishedAt != nil, run.lastPrice != nil else { return false }
        return now >= run.startedAt.addingTimeInterval(Double(horizonDays(run)) * 86_400)
    }

    /// Grades from daily candles. Only bars that start after the analysis count.
    static func grade(_ run: AnalysisRun, candles: [Candle], now: Date) -> AnalysisOutcome? {
        guard let start = run.lastPrice, start > 0 else { return nil }
        let days = horizonDays(run)
        let end = run.startedAt.addingTimeInterval(Double(days) * 86_400)
        let window = candles.filter { $0.time > run.startedAt && $0.time <= end }
        guard let last = window.last, !window.isEmpty else { return nil }
        let composite = Scoring.composite(run.stages, profile: run.profile).value
        let long = composite >= 500
        let ret = (last.close / start - 1) * 100
        let hi = window.map(\.high).max() ?? start, lo = window.map(\.low).min() ?? start
        let best = long ? (hi / start - 1) * 100 : (1 - lo / start) * 100
        let worst = long ? (lo / start - 1) * 100 : (1 - hi / start) * 100
        var outcome = AnalysisOutcome(runID: run.id, gradedAt: now, horizonDays: days, composite: composite,
                                      startPrice: start, endPrice: last.close, forwardReturnPct: ret,
                                      side: long ? "long" : "short",
                                      directionRight: abs(composite - 500) < 30 ? nil : (long ? last.close > start : last.close < start),
                                      bestPct: best, worstPct: worst)
        if let plan = run.plan {
            let sideSign = plan.side == "short" ? -1 : 1
            if let entryIndex = window.firstIndex(where: { $0.low <= plan.entryHigh && $0.high >= plan.entryLow }) {
                // Fill at the zone's middle on the bar that reached it; manage from the next bar on.
                var bars = Array(window[entryIndex...])
                bars[0] = Candle(time: bars[0].time, open: plan.entryMid, high: plan.entryMid, low: plan.entryMid,
                                 close: plan.entryMid, volume: 0)
                let targets: [(price: Double, fraction: Double)] = plan.takeProfits.compactMap { tp -> (price: Double, fraction: Double)? in
                    guard let price = tp.price else { return nil }
                    return (price: price, fraction: tp.bookPercent / 100)
                }
                let result = PlanReplay.simulateLevels(bars, side: sideSign, entry: plan.entryMid, stop: plan.stopLoss, targets: targets)
                outcome.entered = true
                outcome.planR = result?.r
                outcome.targetsHit = result?.targetsHit
                outcome.stopHit = result?.stopHit
            } else {
                outcome.entered = false
            }
        }
        return outcome
    }
}

/// Aggregates for the report card screen.
nonisolated struct ReportCard: Sendable {
    nonisolated struct Band: Sendable, Identifiable {
        var id: String { label }
        var label: String
        var count: Int
        var rightPct: Double?        // direction right, % of graded
        var avgMovePct: Double?      // average move in the score's direction, %
    }

    nonisolated struct StageHit: Sendable, Identifiable {
        var id: Int { stage }
        var stage: Int
        var name: String
        var count: Int
        var rightPct: Double?
    }

    var graded = 0
    var trades = 0               // Buy/Sell verdicts with a plan
    var tradesEntered = 0
    var tradeWinPct: Double?
    var tradeAverageR: Double?
    var directionRightPct: Double?
    var bands: [Band] = []
    var stages: [StageHit] = []
    var scoreReturnCorrelation: Double?

    static let minimumForConclusions = 30

    static func build(runs: [AnalysisRun], outcomes: [UUID: AnalysisOutcome]) -> ReportCard {
        var card = ReportCard()
        let pairs = runs.compactMap { run in outcomes[run.id].map { (run, $0) } }
        card.graded = pairs.count
        guard !pairs.isEmpty else { return card }

        let directional = pairs.compactMap { $0.1.directionRight }
        card.directionRightPct = directional.isEmpty ? nil : Double(directional.filter { $0 }.count) / Double(directional.count) * 100

        let tradeRuns = pairs.filter { (Verdict(rawValue: $0.0.verdict ?? "") ?? .noTrade) != .noTrade && $0.0.plan != nil }
        card.trades = tradeRuns.count
        let rs = tradeRuns.compactMap { $0.1.planR }
        card.tradesEntered = rs.count
        if !rs.isEmpty {
            card.tradeWinPct = Double(rs.filter { $0 > 0 }.count) / Double(rs.count) * 100
            card.tradeAverageR = rs.reduce(0, +) / Double(rs.count)
        }

        func band(_ label: String, _ range: ClosedRange<Int>) -> Band {
            let sel = pairs.filter { range.contains($0.1.composite) }
            let right = sel.compactMap { $0.1.directionRight }
            let moves = sel.map { $0.1.side == "long" ? $0.1.forwardReturnPct : -$0.1.forwardReturnPct }
            return Band(label: label, count: sel.count,
                        rightPct: right.isEmpty ? nil : Double(right.filter { $0 }.count) / Double(right.count) * 100,
                        avgMovePct: moves.isEmpty ? nil : moves.reduce(0, +) / Double(moves.count))
        }
        card.bands = [band("Buy (620+)", 620...1000), band("Leaning up (530–619)", 530...619),
                      band("No direction (471–529)", 471...529), band("Leaning down (381–470)", 381...470),
                      band("Sell (≤ 380)", 10...380)]

        card.stages = StageSpec.all.map { spec in
            var right = 0, total = 0
            for (run, o) in pairs {
                guard let s = run.stages.first(where: { $0.stage == spec.id && $0.status == .done }),
                      s.score >= 55 || s.score <= 45, o.endPrice != o.startPrice else { continue }
                total += 1
                if (s.score >= 55) == (o.endPrice > o.startPrice) { right += 1 }
            }
            return StageHit(stage: spec.id, name: spec.name, count: total,
                            rightPct: total == 0 ? nil : Double(right) / Double(total) * 100)
        }

        if pairs.count >= 10 {
            card.scoreReturnCorrelation = Indicators.correlation(pairs.map { Double($0.1.composite - 500) },
                                                                 pairs.map { $0.1.forwardReturnPct })
        }
        return card
    }
}

/// Grades finished analyses in the background (on launch, throttled) and keeps the results on the device.
@Observable
final class OutcomeStore {
    private(set) var outcomes: [UUID: AnalysisOutcome] = [:]
    private(set) var isGrading = false
    private(set) var lastPass: Date?

    private static var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "outcomes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "outcomes.json")
    }

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL),
           let list = try? decoder.decode([AnalysisOutcome].self, from: data) {
            outcomes = Dictionary(list.map { ($0.runID, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func pending(_ runs: [AnalysisRun], now: Date = Date()) -> Int {
        runs.filter { outcomes[$0.id] == nil && OutcomeGrader.isDue($0, now: now) }.count
    }

    /// At most `limit` analyses per pass, one price download per product, not more than every 30 minutes.
    func gradeDue(_ runs: [AnalysisRun], market: MarketStore, limit: Int = 12, force: Bool = false) async {
        let now = Date()
        guard !isGrading, force || lastPass.map({ now.timeIntervalSince($0) > 1800 }) ?? true else { return }
        let due = runs.filter { outcomes[$0.id] == nil && OutcomeGrader.isDue($0, now: now) }.prefix(limit)
        guard !due.isEmpty else { lastPass = now; return }
        isGrading = true
        defer { isGrading = false; lastPass = Date() }
        var candlesByProduct: [String: [Candle]] = [:]
        var twelveCalls = 0
        for run in due {
            let id = run.instrument.id
            if candlesByProduct[id] == nil {
                if run.instrument.provider == .twelveData {
                    guard twelveCalls < 6 else { continue }   // free plan: 8 a minute
                    twelveCalls += 1
                }
                guard let c = try? await market.candles(for: run.instrument, timeframe: .d1) else { continue }
                candlesByProduct[id] = c
            }
            if let c = candlesByProduct[id], let o = OutcomeGrader.grade(run, candles: c, now: now) {
                outcomes[run.id] = o
            }
        }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(outcomes.values)) {
            try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
        }
    }
}
