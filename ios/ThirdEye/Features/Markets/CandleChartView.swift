import SwiftUI
import WebKit

/// Interactive candlestick + volume chart (TradingView Lightweight Charts, bundled locally).
/// Data lives on a solid surface — never on glass.
struct CandleChartView: UIViewRepresentable {
    @Environment(\.palette) private var palette
    let candles: [Candle]
    let precision: Int
    let displayTimeZone: TimeZone
    /// Changes when the user switches instrument/timeframe, so the chart re-fits.
    let fitToken: String
    /// Number-format locale for the price axis (en-IN gives lakh grouping for ₹ products).
    var locale: String = "en-US"
    /// Support/resistance lines drawn on the chart.
    var levels: [ChartLevel] = []
    /// Trade events (entries, exits) drawn as arrows on the bar they happened in.
    var markers: [ChartMarker] = []
    var onCrosshair: (Candle?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakMessageProxy(context.coordinator), name: "thirdEye")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        context.coordinator.webView = web
        if let url = Bundle.main.url(forResource: "chart", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: Bundle.main.bundleURL)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.onCrosshair = onCrosshair
        c.theme = ChartTheme(palette: palette)
        c.payload = ChartPayload(candles: candles, precision: precision, timeZone: displayTimeZone)
        c.fitToken = fitToken
        c.locale = locale
        c.levels = levels
        c.markers = markers
        c.flush()
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "thirdEye")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var ready = false
        var theme: ChartTheme?
        var payload: ChartPayload?
        var fitToken = ""
        var locale = "en-US"
        var levels: [ChartLevel] = []
        var markers: [ChartMarker] = []
        var onCrosshair: (Candle?) -> Void = { _ in }
        private var sentTheme: ChartTheme?
        private var sentLocale: String?
        private var sentPayloadID: Int?
        private var sentFitToken: String?
        private var sentLevels: [ChartLevel]?
        private var sentMarkers: [ChartMarker]?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                // Sent once per page load. Everything is re-sent after a (re)load.
                ready = true
                sentTheme = nil
                sentLocale = nil
                sentPayloadID = nil
                sentFitToken = nil
                sentLevels = nil
                sentMarkers = nil
                flush()
            case "crosshair":
                guard let bar = body["bar"] as? [String: Any],
                      let t = (bar["time"] as? NSNumber)?.doubleValue,
                      let o = (bar["open"] as? NSNumber)?.doubleValue, let h = (bar["high"] as? NSNumber)?.doubleValue,
                      let l = (bar["low"] as? NSNumber)?.doubleValue, let c = (bar["close"] as? NSNumber)?.doubleValue,
                      let offset = payload?.offset else {
                    onCrosshair(nil)
                    return
                }
                onCrosshair(Candle(time: Date(timeIntervalSince1970: t - offset), open: o, high: h, low: l, close: c, volume: 0))
            default:
                break
            }
        }

        func flush() {
            guard ready, let web = webView else { return }
            // Theme and locale rebuild the chart in JS, so data and levels must follow.
            if locale != sentLocale {
                sentLocale = locale
                sentPayloadID = nil
                sentLevels = nil
                sentMarkers = nil
                web.evaluateJavaScript("thirdEye.setLocale('\(locale)')")
            }
            if let theme, theme != sentTheme {
                sentTheme = theme
                sentPayloadID = nil
                sentLevels = nil
                sentMarkers = nil
                web.evaluateJavaScript("thirdEye.setTheme(\(theme.json))")
            }
            if let payload, payload.id != sentPayloadID {
                let fit = fitToken != sentFitToken
                sentPayloadID = payload.id
                sentFitToken = fitToken
                web.evaluateJavaScript("thirdEye.setData(\(payload.json), \(payload.precision), \(fit))")
                sentLevels = nil // price lines belong to the series; redraw after new data
                sentMarkers = nil
            }
            if levels != sentLevels, payload != nil {
                sentLevels = levels
                let rows: [[String: Any]] = levels.map {
                    ["price": $0.price, "title": $0.title, "kind": $0.kind.rawValue, "style": $0.dashed ? 2 : 0, "width": $0.width]
                }
                web.evaluateJavaScript("thirdEye.setLevels(\(Self.json(rows)))")
            }
            if markers != sentMarkers, let payload {
                sentMarkers = markers
                let rows: [[String: Any]] = markers.compactMap { m in
                    guard let bar = payload.barTime(containing: m.time) else { return nil }
                    return ["time": bar, "kind": m.kind.rawValue, "text": m.text, "below": m.below]
                }
                web.evaluateJavaScript("thirdEye.setMarkers(\(Self.json(rows)))")
            }
        }

        static func json(_ rows: [[String: Any]]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: rows), let s = String(data: data, encoding: .utf8) else { return "[]" }
            return s
        }
    }
}

/// Avoids the WKUserContentController → handler retain cycle.
private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

struct ChartLevel: Equatable {
    enum Kind: String { case support, resistance, entry, stop, target, muted }
    var price: Double
    var title: String
    var kind: Kind
    var dashed = true
    var width = 1

    init(price: Double, title: String, isSupport: Bool) {
        self.price = price; self.title = title; kind = isSupport ? .support : .resistance
    }

    init(price: Double, title: String, kind: Kind, dashed: Bool = true, width: Int = 1) {
        self.price = price; self.title = title; self.kind = kind; self.dashed = dashed; self.width = width
    }
}

struct ChartMarker: Equatable {
    enum Kind: String { case entry, exit, stop, plan }
    var time: Date
    var kind: Kind
    var text: String
    var below: Bool
}

struct ChartTheme: Equatable {
    let json: String

    init(palette: Palette) {
        func hex(_ color: Color) -> String {
            let ui = UIColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
        }
        json = """
        {"background":"\(hex(palette.surface))","text":"\(hex(palette.textSecondary))","grid":"\(hex(palette.separator))",\
        "border":"\(hex(palette.separator))","up":"\(hex(palette.up))","down":"\(hex(palette.down))","accent":"\(hex(palette.accent))"}
        """
    }
}

struct ChartPayload {
    let id: Int
    let json: String
    let precision: Int
    let offset: TimeInterval
    /// Bar start times (unshifted), ascending — for placing markers.
    let times: [Date]

    /// The shifted time of the bar an event falls in, or nil if it is outside the loaded bars.
    func barTime(containing date: Date) -> Int? {
        guard let first = times.first, date >= first else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= date { lo = mid } else { hi = mid - 1 }
        }
        return Int(times[lo].timeIntervalSince1970 + offset)
    }

    init(candles: [Candle], precision: Int, timeZone: TimeZone) {
        // Lightweight Charts shows UTC; shift so the axis reads in the market's local time.
        let offset = TimeInterval(timeZone.secondsFromGMT(for: candles.last?.time ?? Date()))
        self.offset = offset
        self.precision = precision
        times = candles.map(\.time)
        var hasher = Hasher()
        hasher.combine(candles.count)
        hasher.combine(candles.first?.time)
        hasher.combine(candles.last)
        hasher.combine(precision)
        id = hasher.finalize()
        let rows = candles.map { c in
            "{\"time\":\(Int(c.time.timeIntervalSince1970 + offset)),\"open\":\(c.open),\"high\":\(c.high),\"low\":\(c.low),\"close\":\(c.close),\"volume\":\(c.volume.isFinite ? c.volume : 0)}"
        }
        json = "[" + rows.joined(separator: ",") + "]"
    }
}
