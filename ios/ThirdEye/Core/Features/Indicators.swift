import Foundation

/// Classic technical indicators. Pure functions over arrays, output aligned with input
/// (`nil` until enough bars exist). Formulas follow the standard definitions:
/// EMA seeded with SMA; RSI/ATR/ADX use Wilder smoothing.
nonisolated enum Indicators {
    static func sma(_ values: [Double], _ period: Int) -> [Double?] {
        guard period > 0 else { return values.map { _ in nil } }
        var out = [Double?](repeating: nil, count: values.count)
        var sum = 0.0
        for i in values.indices {
            sum += values[i]
            if i >= period { sum -= values[i - period] }
            if i >= period - 1 { out[i] = sum / Double(period) }
        }
        return out
    }

    static func ema(_ values: [Double], _ period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count >= period else { return out }
        let k = 2.0 / Double(period + 1)
        var prev = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = prev
        for i in period..<values.count {
            prev = values[i] * k + prev * (1 - k)
            out[i] = prev
        }
        return out
    }

    /// Wilder's RSI.
    static func rsi(_ closes: [Double], _ period: Int = 14) -> [Double?] {
        var out = [Double?](repeating: nil, count: closes.count)
        guard closes.count > period else { return out }
        var gain = 0.0, loss = 0.0
        for i in 1...period {
            let d = closes[i] - closes[i - 1]
            if d >= 0 { gain += d } else { loss -= d }
        }
        var avgGain = gain / Double(period)
        var avgLoss = loss / Double(period)
        func value() -> Double { avgLoss == 0 ? (avgGain == 0 ? 50 : 100) : 100 - 100 / (1 + avgGain / avgLoss) }
        out[period] = value()
        if closes.count > period + 1 {
            for i in (period + 1)..<closes.count {
                let d = closes[i] - closes[i - 1]
                avgGain = (avgGain * Double(period - 1) + max(d, 0)) / Double(period)
                avgLoss = (avgLoss * Double(period - 1) + max(-d, 0)) / Double(period)
                out[i] = value()
            }
        }
        return out
    }

    static func trueRange(_ c: [Candle]) -> [Double] {
        c.indices.map { i in
            let hl = c[i].high - c[i].low
            guard i > 0 else { return hl }
            let pc = c[i - 1].close
            return max(hl, abs(c[i].high - pc), abs(c[i].low - pc))
        }
    }

    /// Wilder-smoothed ATR, seeded with the mean of the first `period` true ranges that have a
    /// previous close (bars 1…period). Matches Wilder's definition and TA-Lib.
    static func atr(_ c: [Candle], _ period: Int = 14) -> [Double?] {
        guard c.count > period else { return [Double?](repeating: nil, count: c.count) }
        return [nil] + wilder(Array(trueRange(c).dropFirst()), period)
    }

    static func wilder(_ values: [Double], _ period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard values.count >= period, period > 0 else { return out }
        var prev = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = prev
        for i in period..<values.count {
            prev = (prev * Double(period - 1) + values[i]) / Double(period)
            out[i] = prev
        }
        return out
    }

    nonisolated struct MACD { var macd: [Double?]; var signal: [Double?]; var histogram: [Double?] }

    /// EMA whose SMA seed window ends at `seedEnd` (so several EMAs can start on the same bar).
    static func ema(_ values: [Double], _ period: Int, seedEnd: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, seedEnd >= period - 1, seedEnd < values.count else { return out }
        let k = 2.0 / Double(period + 1)
        var prev = values[(seedEnd - period + 1)...seedEnd].reduce(0, +) / Double(period)
        out[seedEnd] = prev
        for i in (seedEnd + 1)..<max(values.count, seedEnd + 1) {
            prev = values[i] * k + prev * (1 - k)
            out[i] = prev
        }
        return out
    }

    /// MACD with TA-Lib's seeding: fast and slow EMAs both start on bar `slow − 1`.
    static func macd(_ closes: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9) -> MACD {
        let n = closes.count
        let start = slow - 1
        guard n > start else {
            let empty = [Double?](repeating: nil, count: n)
            return MACD(macd: empty, signal: empty, histogram: empty)
        }
        let f = ema(closes, fast, seedEnd: start), s = ema(closes, slow, seedEnd: start)
        let line: [Double?] = closes.indices.map { i in
            guard let a = f[i], let b = s[i] else { return nil }
            return a - b
        }
        let sigCompact = ema(line[start...].compactMap { $0 }, signal)
        var sig = [Double?](repeating: nil, count: n)
        for (j, v) in sigCompact.enumerated() { sig[start + j] = v }
        let hist: [Double?] = closes.indices.map { i in
            guard let m = line[i], let s = sig[i] else { return nil }
            return m - s
        }
        return MACD(macd: line, signal: sig, histogram: hist)
    }

    nonisolated struct Bands { var middle: [Double?]; var upper: [Double?]; var lower: [Double?] }

    /// Bollinger Bands (population standard deviation, as in the original definition).
    static func bollinger(_ closes: [Double], _ period: Int = 20, _ k: Double = 2) -> Bands {
        let mid = sma(closes, period)
        var up = [Double?](repeating: nil, count: closes.count)
        var lo = up
        for i in closes.indices {
            guard let m = mid[i] else { continue }
            let window = closes[(i - period + 1)...i]
            let variance = window.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(period)
            let sd = variance.squareRoot()
            up[i] = m + k * sd
            lo[i] = m - k * sd
        }
        return Bands(middle: mid, upper: up, lower: lo)
    }

    nonisolated struct DMI { var adx: [Double?]; var plusDI: [Double?]; var minusDI: [Double?] }

    /// Wilder's ADX / +DI / −DI.
    static func adx(_ c: [Candle], _ period: Int = 14) -> DMI {
        let n = c.count
        var plusDM = [Double](repeating: 0, count: n), minusDM = plusDM
        for i in 1..<max(n, 1) where i < n {
            let up = c[i].high - c[i - 1].high
            let down = c[i - 1].low - c[i].low
            plusDM[i] = (up > down && up > 0) ? up : 0
            minusDM[i] = (down > up && down > 0) ? down : 0
        }
        let tr = trueRange(c)
        // TA-Lib/Wilder running sums: seed with bars 1…period−1, then sum − sum/period + value.
        func smoothed(_ v: [Double]) -> [Double?] {
            var out = [Double?](repeating: nil, count: n)
            guard n > period else { return out }
            var prev = v[1..<period].reduce(0, +)
            for i in period..<n {
                prev = prev - prev / Double(period) + v[i]
                out[i] = prev
            }
            return out
        }
        let atrS = smoothed(tr), pS = smoothed(plusDM), mS = smoothed(minusDM)
        var pDI = [Double?](repeating: nil, count: n), mDI = pDI
        var dx = [Double](repeating: .nan, count: n)
        for i in 0..<n {
            guard let a = atrS[i], a > 0, let p = pS[i], let m = mS[i] else { continue }
            pDI[i] = 100 * p / a
            mDI[i] = 100 * m / a
            let sum = pDI[i]! + mDI[i]!
            dx[i] = sum == 0 ? 0 : 100 * abs(pDI[i]! - mDI[i]!) / sum
        }
        var adx = [Double?](repeating: nil, count: n)
        if let first = dx.firstIndex(where: { !$0.isNaN }) {
            let valid = Array(dx[first...])
            let a = wilder(valid, period)
            for (j, v) in a.enumerated() { adx[first + j] = v }
        }
        return DMI(adx: adx, plusDI: pDI, minusDI: mDI)
    }

    /// Rate of change in percent over `period` bars.
    static func roc(_ closes: [Double], _ period: Int) -> [Double?] {
        closes.indices.map { i in
            guard i >= period, closes[i - period] != 0 else { return nil }
            return (closes[i] / closes[i - period] - 1) * 100
        }
    }

    static func obv(_ c: [Candle]) -> [Double] {
        var out = [Double](repeating: 0, count: c.count)
        for i in c.indices.dropFirst() {
            let d = c[i].close - c[i - 1].close
            out[i] = out[i - 1] + (d > 0 ? c[i].volume : d < 0 ? -c[i].volume : 0)
        }
        return out
    }

    /// Simple returns, aligned so `r[i]` is the change from bar i−1 to i (r[0] = nil).
    static func returns(_ closes: [Double]) -> [Double?] {
        closes.indices.map { i in i > 0 && closes[i - 1] != 0 ? closes[i] / closes[i - 1] - 1 : nil }
    }

    static func stdev(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)).squareRoot()
    }

    /// Pearson correlation of two equal-length series.
    static func correlation(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 2 else { return nil }
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        guard da > 0, db > 0 else { return nil }
        return num / (da * db).squareRoot()
    }
}
