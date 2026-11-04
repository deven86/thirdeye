import Foundation
import Testing
@testable import ThirdEye

// Fixtures below are copied from the live Upstox/Binance responses captured on 2026-11-04.

@Suite("Gzip")
struct GzipTests {
    /// Real gzip output (with FNAME header flag) containing one Upstox record.
    static let fixture = Data(base64Encoded: "H4sICAAAAAAC/05TRS5qc29uAF2PQWuDQBCF/4rsuYQ1EJDcpNmDYDZE01Mpi7UTs6ir7o4Q0+S/N6PFSvc2b+d77837N3NQ1GCQbT0mU6HEkb14zGQ1kJKIOArlq/AiuXtLT0kkUi8+7WgFrvklMwX8giRppw2NkRScr0Pucz8YdePQ9pSicGhHYopZfJQw/FW4/3eoGlRO3wj1n+PZAtxAdX1mUCOBPqe34otiCpsSxj7rINiQC+q8nG2mZbTZlzaFckP92VTLkwnocFB1X6FuKw2WqBFykPf2mTtfIw/JPozZ4+MHMVk6DlABAAA=")!

    @Test func decompressesRealGzip() throws {
        #expect(Gzip.isGzip(Self.fixture))
        let json = try Gzip.decompress(Self.fixture)
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"trading_symbol\": \"RELIANCE\""))
    }

    @Test func rejectsNonGzip() {
        #expect(throws: Gzip.GzipError.notGzip) { try Gzip.decompress(Data(repeating: 0x41, count: 40)) }
    }

    @Test func parsesGzippedInstrumentFile() throws {
        let instruments = try UpstoxInstruments.parse(Self.fixture)
        #expect(instruments.count == 1)
        let r = try #require(instruments.first)
        #expect(r.symbol == "RELIANCE")
        #expect(r.kind == .equity)
        #expect(r.tickSize == 0.1, "Upstox tick_size is in paise: 10.0 → ₹0.10")
    }
}

@Suite("Upstox instruments")
struct UpstoxInstrumentTests {
    static let json = """
    [
     {"segment": "NSE_EQ", "name": "ENVIRO INFRA ENGINEERS L", "exchange": "NSE", "isin": "INE0LLY01014", "instrument_type": "EQ", "instrument_key": "NSE_EQ|INE0LLY01014", "lot_size": 1, "freeze_quantity": 100000.0, "exchange_token": "27213", "tick_size": 1.0, "trading_symbol": "EIEL", "qty_multiplier": 1.0, "security_type": "NORMAL"},
     {"segment": "NSE_EQ", "name": "SDL RJ 7.49% 2035", "exchange": "NSE", "isin": "IN2920250163", "instrument_type": "SG", "instrument_key": "NSE_EQ|IN2920250163", "lot_size": 100, "tick_size": 1.0, "trading_symbol": "749RJ35", "security_type": "NORMAL"},
     {"segment": "NSE_INDEX", "name": "NIFTY100 Qualty30", "exchange": "NSE", "instrument_type": "INDEX", "instrument_key": "NSE_INDEX|NIFTY100 Qualty30", "exchange_token": "26048", "trading_symbol": "NIFTY100 QUALTY30"},
     {"weekly": false, "segment": "NSE_FO", "name": "NIFTY", "exchange": "NSE", "expiry": 1798568999000, "instrument_type": "CE", "asset_symbol": "NIFTY", "underlying_symbol": "NIFTY", "instrument_key": "NSE_FO|50978", "lot_size": 65, "freeze_quantity": 1755.0, "exchange_token": "50978", "minimum_lot": 65, "asset_key": "NSE_INDEX|Nifty 50", "underlying_key": "NSE_INDEX|Nifty 50", "tick_size": 5.0, "asset_type": "INDEX", "underlying_type": "INDEX", "trading_symbol": "NIFTY 27000 CE 29 DEC 26", "strike_price": 27000.0, "qty_multiplier": 1.0},
     {"weekly": false, "segment": "NSE_FO", "name": "VEDANTA LIMITED", "exchange": "NSE", "expiry": 1798568999000, "instrument_type": "FUT", "asset_symbol": "VEDL", "underlying_symbol": "VEDL", "instrument_key": "NSE_FO|59150", "lot_size": 1150, "tick_size": 1.0, "trading_symbol": "VEDL FUT 29 DEC 26", "strike_price": 0.0},
     {"segment": "MCX_FO", "name": "SILVER", "exchange": "MCX", "expiry": 1814812199000, "instrument_type": "FUT", "underlying_symbol": "SILVER", "instrument_key": "MCX_FO|579304", "lot_size": 30, "tick_size": 100.0, "trading_symbol": "SILVER FUT 05 JUN 27"},
     {"weekly": true, "segment": "NCD_FO", "name": "GBPINR", "exchange": "NSE", "expiry": 1798828199000, "instrument_type": "FUT", "underlying_symbol": "GBPINR", "instrument_key": "NCD_FO|7022", "lot_size": 1, "tick_size": 0.25, "trading_symbol": "GBPINR FUT 01 JAN 27", "strike_price": 0.0},
     {"segment": "BSE_EQ", "name": "Global Health Limited", "exchange": "BSE", "isin": "INE474Q01031", "instrument_type": "A", "instrument_key": "BSE_EQ|INE474Q01031", "lot_size": 1, "tick_size": 5.0, "trading_symbol": "MEDANTA"},
     {"segment": "BSE_EQ", "name": "Some Debt", "exchange": "BSE", "instrument_type": "F", "instrument_key": "BSE_EQ|X1", "trading_symbol": "DEBT1"}
    ]
    """

    @Test func mapsKindsAndSkipsDebt() throws {
        let list = try UpstoxInstruments.parse(Data(Self.json.utf8))
        let byKey = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        #expect(list.count == 7, "SDL bond and BSE debt must be skipped")
        #expect(byKey["NSE_EQ|INE0LLY01014"]?.kind == .equity)
        #expect(byKey["NSE_INDEX|NIFTY100 Qualty30"]?.kind == .index)
        #expect(byKey["MCX_FO|579304"]?.kind == .commodity)
        #expect(byKey["NCD_FO|7022"]?.kind == .forex)
        #expect(byKey["NSE_FO|59150"]?.kind == .future)
        #expect(byKey["BSE_EQ|INE474Q01031"]?.symbol == "MEDANTA")

        let option = try #require(byKey["NSE_FO|50978"])
        #expect(option.kind == .option)
        #expect(option.strike == 27000)
        #expect(option.optionType == "CE")
        #expect(option.tickSize == 0.05)
        #expect(option.lotSize == 65)
        #expect(option.underlying == "NIFTY")
        #expect(option.expiry == Date(timeIntervalSince1970: 1_798_568_999))
    }

    @Test func searchRanksIndexAndHidesContractsUnlessAsked() throws {
        let list = try UpstoxInstruments.parse(Data(Self.json.utf8))
        let index = InstrumentIndex(list)
        let now = Date(timeIntervalSince1970: 1_793_750_400) // 2026-11-04

        let nifty = index.search("nifty", now: now)
        #expect(nifty.first?.kind == .index)
        #expect(!nifty.contains { $0.kind == .option }, "options only when the query looks like a contract")

        let contract = index.search("nifty 27000", now: now)
        #expect(contract.contains { $0.id == "NSE_FO|50978" })

        #expect(index.search("medanta", now: now).first?.exchange == "BSE")
        #expect(index.search("global health", now: now).first?.symbol == "MEDANTA")
        #expect(index.search("vedl", filter: .futuresOptions, now: now).first?.kind == .future)
        #expect(index.search("eiel", filter: .crypto, now: now).isEmpty)
    }

    @Test func expiredContractsAreHidden() throws {
        let list = try UpstoxInstruments.parse(Data(Self.json.utf8))
        let afterExpiry = Date(timeIntervalSince1970: 1_798_568_999 + 3 * 86_400)
        #expect(InstrumentIndex(list).search("vedl fut", now: afterExpiry).isEmpty)
    }
}

@Suite("Upstox login & candles")
struct UpstoxClientTests {
    @Test func callbackParsing() {
        let state = "abc123"
        let ok = URL(string: "https://127.0.0.1/thirdeye?code=XyZ9&state=abc123")!
        #expect(UpstoxAuth.parseCallback(ok, expectedState: state) == .code("XyZ9"))

        let wrongState = URL(string: "https://127.0.0.1/thirdeye?code=XyZ9&state=evil")!
        if case .error = UpstoxAuth.parseCallback(wrongState, expectedState: state) {} else {
            Issue.record("state mismatch must be rejected")
        }
        #expect(UpstoxAuth.parseCallback(URL(string: "https://api.upstox.com/v2/login")!, expectedState: state) == .notCallback)
    }

    @Test func loginURLCarriesRedirectAndState() throws {
        let url = UpstoxAuth.loginURL(apiKey: "KEY", state: "S1")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "redirect_uri", value: "https://127.0.0.1/thirdeye")))
        #expect(items.contains(URLQueryItem(name: "state", value: "S1")))
        #expect(items.contains(URLQueryItem(name: "response_type", value: "code")))
    }

    @Test func tokenExpiresAtNext0330IST() {
        let ist = TimeZone(identifier: "Asia/Kolkata")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ist
        let morning = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 5))!
        let expected = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 3, minute: 30))!
        #expect(UpstoxAuth.expiry(issuedAt: morning) == expected)

        let earlyMorning = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 2, minute: 0))!
        let sameDay = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 3, minute: 30))!
        #expect(UpstoxAuth.expiry(issuedAt: earlyMorning) == sameDay)
    }

    @Test func tokenRoundTrip() throws {
        let issued = Date(timeIntervalSince1970: 1_793_790_000)
        let stored = MarketStore.encodeToken("eyJ|abc", issued: issued, user: "Devendra")
        let decoded = try #require(MarketStore.decodeToken(stored))
        #expect(decoded.token == "eyJ|abc", "tokens containing | must survive")
        #expect(decoded.user == "Devendra")
        #expect(decoded.issued == issued)
    }

    @Test func parsesV3CandlesNewestFirst() throws {
        let json = """
        {"status":"success","data":{"candles":[
          ["2025-01-12T15:16:00+05:30",2304.65,2306.0,2303.1,2305.2,412000,0],
          ["2025-01-12T15:15:00+05:30",2305.3,2307.05,2301,2304.65,559982,0]
        ]}}
        """
        let candles = try UpstoxCandleClient.parseCandles(Data(json.utf8))
        #expect(candles.count == 2)
        #expect(candles[0].close == 2304.65, "must be sorted oldest first")
        #expect(candles[0].time == ISODate.parse("2025-01-12T09:45:00Z"))
        #expect(candles[1].volume == 412000)
    }

    @Test func historyWindowsStayInsideUpstoxLimits() {
        let now = Date(timeIntervalSince1970: 1_793_750_400)
        let days = { (tf: Timeframe) in now.timeIntervalSince(UpstoxCandleClient.fromDate(tf, now: now)) / 86_400 }
        #expect(days(.m1) <= 31)
        #expect(days(.m15) <= 31)
        #expect(days(.h1) <= 92)
        #expect(days(.d1) <= 3660)
        #expect(UpstoxCandleClient.encodedKey("NSE_EQ|INE002A01018") == "NSE_EQ%7CINE002A01018")
        #expect(UpstoxCandleClient.encodedKey("NSE_INDEX|Nifty 50") == "NSE_INDEX%7CNifty%2050")
    }
}

@Suite("Global providers")
struct GlobalProviderTests {
    @Test func binanceKlinesFromLiveFormat() throws {
        let json = """
        [[1793664000000,"76816.01000000","78063.30000000","76388.88000000","77453.86000000","12560.17626000",1793750399999,"969414430.35264930",2723726,"6168.77522000","476386511.87039140","0"],
         [1793750400000,"77453.85000000","78514.30000000","75736.38000000","78336.74000000","8121.12004000",1793836799999,"627030347.41708350",1865284,"4304.43001000","332595225.29548860","0"]]
        """
        let candles = try BinanceClient.parseKlines(Data(json.utf8))
        #expect(candles.count == 2)
        #expect(candles[1].close == 78336.74)
        #expect(candles[0].time == Date(timeIntervalSince1970: 1_793_664_000))
    }

    @Test func binanceSymbolsKeepUSDTTrading() throws {
        let json = """
        {"symbols":[
          {"symbol":"BTCUSDT","status":"TRADING","baseAsset":"BTC","quoteAsset":"USDT"},
          {"symbol":"ETHBTC","status":"TRADING","baseAsset":"ETH","quoteAsset":"BTC"},
          {"symbol":"OLDUSDT","status":"BREAK","baseAsset":"OLD","quoteAsset":"USDT"}
        ]}
        """
        let list = try BinanceClient.parseInstruments(Data(json.utf8))
        #expect(list.map(\.id) == ["binance:BTCUSDT"])
        #expect(list.first?.providerKey == "BTCUSDT")
    }

    @Test func twelveDataSeriesAndErrors() throws {
        let ok = """
        {"meta":{"symbol":"XAU/USD","interval":"1day"},"values":[
          {"datetime":"2026-11-02","open":"2650.1","high":"2671.0","low":"2641.5","close":"2665.3"},
          {"datetime":"2026-11-03","open":"2665.3","high":"2680.2","low":"2655.0","close":"2678.9"}],"status":"ok"}
        """
        let candles = try TwelveDataClient.parseSeries(Data(ok.utf8))
        #expect(candles.count == 2)
        #expect(candles.last?.close == 2678.9)
        #expect(candles.first?.volume == 0)

        let limited = #"{"code":429,"message":"You have run out of API credits for the current minute.","status":"error"}"#
        #expect(throws: MarketDataError.rateLimited) { try TwelveDataClient.parseSeries(Data(limited.utf8)) }
    }

    @Test func twelveDataListsMarkMetalsAsCommodities() throws {
        let json = """
        {"data":[
          {"symbol":"EUR/USD","currency_group":"Major","currency_base":"Euro","currency_quote":"US Dollar"},
          {"symbol":"XAU/USD","currency_group":"Exotic","currency_base":"Gold Spot","currency_quote":"US Dollar"}
        ],"status":"ok"}
        """
        let list = try TwelveDataClient.parseList(Data(json.utf8), kind: .forex)
        #expect(list.first { $0.symbol == "XAU/USD" }?.kind == .commodity)
        #expect(list.first { $0.symbol == "EUR/USD" }?.name == "Euro / US Dollar")
        #expect(list.first?.providerKey == "EUR/USD")
    }
}
