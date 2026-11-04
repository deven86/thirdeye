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
        var onCrosshair: (Candle?) -> Void = { _ in }
        private var sentTheme: ChartTheme?
        private var sentPayloadID: Int?
        private var sentFitToken: String?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                sentTheme = nil
                sentPayloadID = nil
                sentFitToken = nil
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
            if let theme, theme != sentTheme {
                sentTheme = theme
                sentPayloadID = nil // theme rebuild clears series
                web.evaluateJavaScript("thirdEye.setTheme(\(theme.json))")
            }
            if let payload, payload.id != sentPayloadID {
                let fit = fitToken != sentFitToken
                sentPayloadID = payload.id
                sentFitToken = fitToken
                web.evaluateJavaScript("thirdEye.setData(\(payload.json), \(payload.precision), \(fit))")
            }
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
        "border":"\(hex(palette.separator))","up":"\(hex(palette.up))","down":"\(hex(palette.down))"}
        """
    }
}

struct ChartPayload {
    let id: Int
    let json: String
    let precision: Int
    let offset: TimeInterval

    init(candles: [Candle], precision: Int, timeZone: TimeZone) {
        // Lightweight Charts shows UTC; shift so the axis reads in the market's local time.
        let offset = TimeInterval(timeZone.secondsFromGMT(for: candles.last?.time ?? Date()))
        self.offset = offset
        self.precision = precision
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
