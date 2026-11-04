import Foundation

/// In-memory search over ~130k instruments. Built once per refresh, queried per keystroke.
nonisolated struct InstrumentIndex: Sendable {
    nonisolated enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, indiaStocks, indices, futuresOptions, commodities, forex, usStocks, crypto

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .indiaStocks: "India stocks"
            case .indices: "Indices"
            case .futuresOptions: "F&O"
            case .commodities: "Commodities"
            case .forex: "Forex"
            case .usStocks: "US stocks"
            case .crypto: "Crypto"
            }
        }

        func matches(_ i: Instrument) -> Bool {
            switch self {
            case .all: true
            case .indiaStocks: i.kind == .equity && i.provider == .upstox
            case .indices: i.kind == .index
            case .futuresOptions: i.kind == .future || i.kind == .option
            case .commodities: i.kind == .commodity
            case .forex: i.kind == .forex
            case .usStocks: i.provider == .twelveData && (i.kind == .equity || i.kind == .etf)
            case .crypto: i.kind == .crypto
            }
        }
    }

    private nonisolated struct Entry: Sendable {
        let instrument: Instrument
        let symbolKey: String
        let nameKey: String
    }

    private let entries: [Entry]
    var count: Int { entries.count }

    init(_ instruments: [Instrument]) {
        entries = instruments.map {
            Entry(instrument: $0, symbolKey: Self.fold($0.symbol), nameKey: Self.fold($0.name))
        }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Ranked results. Options/futures appear only when the query looks like a contract
    /// (contains digits, CE/PE or FUT) or the F&O filter is on — otherwise "NIFTY" would bury the index.
    func search(_ query: String, filter: Filter = .all, limit: Int = 60, now: Date = Date()) -> [Instrument] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        let wantsContracts = filter == .futuresOptions
            || q.rangeOfCharacter(from: .decimalDigits) != nil
            || q.hasSuffix("ce") || q.hasSuffix("pe") || q.contains("fut")

        var scored: [(Int, Instrument)] = []
        scored.reserveCapacity(256)
        for e in entries {
            let i = e.instrument
            guard filter.matches(i) else { continue }
            if (i.kind == .option || i.kind == .future), !wantsContracts { continue }
            if let expiry = i.expiry, expiry < now.addingTimeInterval(-86_400) { continue }

            var score: Int
            if e.symbolKey == q { score = 1000 }
            else if e.symbolKey.hasPrefix(q) { score = 800 - min(e.symbolKey.count - q.count, 100) }
            else if e.nameKey.hasPrefix(q) { score = 600 - min(e.nameKey.count - q.count, 100) }
            else if e.symbolKey.contains(q) { score = 400 }
            else if e.nameKey.contains(q) { score = 300 }
            else { continue }

            switch i.kind {
            case .index: score += 60
            case .equity: score += (i.exchange == "NSE" || i.provider == .twelveData) ? 50 : 30
            case .forex, .crypto, .commodity, .etf: score += 40
            case .future: score += 10
            case .option: score += 0
            }
            if let expiry = i.expiry { // nearer expiries first
                score -= min(Int(expiry.timeIntervalSince(now) / 86_400), 200) / 10
            }
            scored.append((score, i))
        }
        return scored
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.symbol < $1.1.symbol }
            .prefix(limit)
            .map(\.1)
    }

    func instrument(id: String) -> Instrument? {
        entries.first { $0.instrument.id == id }?.instrument
    }
}
