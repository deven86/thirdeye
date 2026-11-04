import Foundation

/// Parses Upstox's BOD instrument files (NSE/BSE/MCX `.json.gz`) into `Instrument`s.
///
/// Formats confirmed against the live files on 2026-11-04:
/// - NSE ≈ 80k records (≈2 MB gz), BSE ≈ 28k, MCX ≈ 16k.
/// - `tick_size` is in paise (5.0 = ₹0.05); `expiry` is epoch milliseconds.
/// - Debt (bonds, T-bills, SGBs, NCDs) is excluded — not useful for this app.
nonisolated enum UpstoxInstruments {
    static let files = ["NSE", "BSE", "MCX"].map {
        URL(string: "https://assets.upstox.com/market-quote/instruments/exchange/\($0).json.gz")!
    }

    nonisolated struct Record: Decodable {
        let segment: String
        let name: String?
        let exchange: String?
        let instrument_type: String
        let instrument_key: String
        let trading_symbol: String?
        let lot_size: Double?
        let tick_size: Double?
        let expiry: Double?
        let strike_price: Double?
        let underlying_symbol: String?
        let security_type: String?
    }

    /// NSE cash-segment instrument types worth showing (equities, SME, REITs/InvITs, trade-to-trade).
    static let nseEquityTypes: Set<String> = ["EQ", "BE", "BZ", "SM", "ST", "SZ", "IV", "RR", "IT"]
    /// BSE equity groups (A, B, T, X, XT, M, MT, MS, Z, ZP, P, TS). F/G/IF/E are debt or similar.
    static let bseEquityTypes: Set<String> = ["A", "B", "T", "X", "XT", "M", "MT", "MS", "Z", "ZP", "P", "TS"]
    static let derivativeSegments: Set<String> = ["NSE_FO", "BSE_FO", "MCX_FO", "NCD_FO", "BCD_FO", "NSE_COM"]

    static func parse(_ data: Data) throws -> [Instrument] {
        let json = Gzip.isGzip(data) ? try Gzip.decompress(data) : data
        let records: [Record]
        do { records = try JSONDecoder().decode([Record].self, from: json) } catch {
            throw MarketDataError.decoding("Upstox instrument file")
        }
        return records.compactMap(map)
    }

    static func map(_ r: Record) -> Instrument? {
        let kind: AssetKind
        switch (r.segment, r.instrument_type) {
        case ("NSE_EQ", let t) where nseEquityTypes.contains(t): kind = .equity
        case ("BSE_EQ", let t) where bseEquityTypes.contains(t): kind = .equity
        case ("NSE_INDEX", _), ("BSE_INDEX", _): kind = .index
        case (let s, "FUT") where derivativeSegments.contains(s):
            kind = (s == "NCD_FO" || s == "BCD_FO") ? .forex : (s == "MCX_FO" || s == "NSE_COM") ? .commodity : .future
        case (let s, "CE"), (let s, "PE"):
            guard derivativeSegments.contains(s) else { return nil }
            kind = .option
        case ("NSE_COM", "COM"): kind = .commodity
        default: return nil
        }

        let symbol = (r.trading_symbol ?? r.name ?? r.instrument_key).trimmingCharacters(in: .whitespaces)
        let exchange = r.exchange ?? String(r.segment.prefix(while: { $0 != "_" }))
        let isDerivative = kind == .future || kind == .option || (r.expiry != nil)
        return Instrument(
            id: r.instrument_key,
            provider: .upstox,
            symbol: symbol,
            name: (r.name ?? symbol).trimmingCharacters(in: .whitespaces),
            exchange: exchange,
            segment: r.segment,
            kind: kind,
            currency: "INR",
            expiry: r.expiry.map { Date(timeIntervalSince1970: $0 / 1000) },
            strike: (r.strike_price ?? 0) > 0 ? r.strike_price : nil,
            optionType: kind == .option ? r.instrument_type : nil,
            lotSize: r.lot_size,
            tickSize: r.tick_size.map { $0 / 100 },
            underlying: isDerivative ? r.underlying_symbol : nil
        )
    }
}
