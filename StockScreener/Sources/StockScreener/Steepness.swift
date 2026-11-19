import Foundation

/// "Sustained steepness" (your Pine indicator), on NSE delivery value (DELIV_QTY × CLOSE):
///   src = ta.ema(delVal, 66) · g = (src / src[span] − 1) × 100
///   mu = ta.sma(g, norm) · sd = ta.stdev(g, norm) · z = sd > 0 ? (g − mu) / sd : 0
///   isSteep = z > trig · run = isSteep ? ta.barssince(not isSteep) : 0 · energy = isSteep ? energy + z : 0
enum Steep {
    static var ema: Int { v("steep.ema", 66) }
    static var span: Int { v("steep.span", 5) }
    static var norm: Int { v("steep.norm", 250) }
    /// What the steepness is measured on: "delsma" (default) = DELSMA itself; "value" = ta.ema(DELIV_QTY×CLOSE, 66).
    static var source: String { UserDefaults.standard.string(forKey: "steep.source") ?? "delsma" }
    static var trig: Double { let d = UserDefaults.standard.double(forKey: "steep.trig"); return d > 0 ? d : 2.0 }
    private static func v(_ k: String, _ def: Int) -> Int { let i = UserDefaults.standard.integer(forKey: k); return i > 0 ? i : def }

    struct Result { var z: [Double?]; var run: [Int]; var energy: [Double]; var steep: [Bool] }

    static func series(_ s: DeliverySeries) -> Result {
        let n = min(s.qty.count, s.close.count)
        if source == "delsma" {
            // DELSMA = ta.percentrank(ta.sma(DELIV_QTY×CLOSE, 22 / as the Delivery signal), 300), 0–100 — already smooth,
            // so it is used as src directly (no extra EMA)
            let m = Array(s.metric(value: true).prefix(n))
            let L = DeliveryColumns.hiSma
            let sm = DeliverySignal.avg(m, L, ema: DeliveryMetric.signalIsEMA)
            var src = [Double?](repeating: nil, count: n)
            if n > L - 1 {
                let valid = Array(sm[(L - 1)...])
                for k in valid.indices { src[k + L - 1] = DeliveryColumns.percentRank(valid, length: 300, at: k) }
            }
            return compute(src: src, span: span, norm: norm, trig: trig)
        }
        let delVal = (0..<n).map { s.qty[$0] * s.close[$0] }
        return compute(delVal, ema: ema, span: span, norm: norm, trig: trig)
    }

    /// ta.percentrank(z, 300) on bar i: % of the previous 300 z values ≤ today's z (z = 0 where Pine's z is 0 / na).
    /// nil until 300 earlier bars exist.
    static func zPRankAt(_ s: DeliverySeries, at i: Int, length: Int = 300) -> Double? {
        guard i >= length else { return nil }
        let zs = zTail(s, at: i, count: length + 1)
        guard zs.count == length + 1 else { return nil }
        let x = zs.map { $0 ?? 0 }
        var c = 0
        for k in 0..<length where x[k] <= x[length] { c += 1 }
        return Double(c) / Double(length) * 100
    }

    /// Z_PRANK_DAYS threshold: days since Z_PRANK > this (UserDefaults "zprankDays.value", default 99).
    static var daysLevel: Double { let v = UserDefaults.standard.object(forKey: "zprankDays.value") as? Double; return v ?? 99 }
    static let daysLookback = 300

    /// STEEP_Z, Z_PRANK and Z_PRANK_DAYS on bar i (one pass). days = ta.barssince(Z_PRANK > level), searched over
    /// the last 300 bars (nil = not within them).
    static func zAndPRank(_ s: DeliverySeries, at i: Int, length: Int = 300) -> (z: Double?, pr: Double?, days: Int?) {
        let back = daysLookback
        let zs = zTail(s, at: i, count: length + back + 1)
        guard let zi = zs.last else { return (nil, nil, nil) }
        let x = zs.map { $0 ?? 0 }
        let firstBar = i - (x.count - 1)                     // bar number of x[0]
        func pr(_ k: Int) -> Double? {                       // k = index in x
            guard k >= length, firstBar + k >= length else { return nil }
            var c = 0
            for j in (k - length)..<k where x[j] <= x[k] { c += 1 }
            return Double(c) / Double(length) * 100
        }
        let today = pr(x.count - 1)
        var days: Int? = nil
        let level = daysLevel
        for d in 0...back where x.count - 1 - d >= 0 {
            if let p = pr(x.count - 1 - d), p > level { days = d; break }
        }
        return (zi, today, days)
    }

    /// percentrank(z, 300) for every bar of a full z series (charts' legend).
    static func zPRank(_ z: [Double?], length: Int = 300) -> [Double?] {
        let x = z.map { $0 ?? 0 }
        var out = [Double?](repeating: nil, count: x.count)
        guard x.count > length else { return out }
        for i in length..<x.count {
            var c = 0
            for k in (i - length)..<i where x[k] <= x[i] { c += 1 }
            out[i] = Double(c) / Double(length) * 100
        }
        return out
    }

    /// z for the last `count` bars ending at i (only the src values those need are computed).
    static func zTail(_ s: DeliverySeries, at i: Int, count: Int) -> [Double?] {
        let n = min(s.qty.count, s.close.count)
        guard i < n, count > 0 else { return [] }
        let need = norm + span + count - 1
        let from = max(0, i - need + 1)
        var src = [Double?](repeating: nil, count: i - from + 1)
        if source == "delsma" {
            let m = Array(s.metric(value: true).prefix(i + 1))
            let L = DeliveryColumns.hiSma
            guard m.count > L - 1 else { return [] }
            let sm = DeliverySignal.avg(m, L, ema: DeliveryMetric.signalIsEMA)
            let valid = Array(sm[(L - 1)...])
            for bar in from...i { let vk = bar - (L - 1); if vk >= 0 { src[bar - from] = DeliveryColumns.percentRank(valid, length: 300, at: vk) } }
            let z = compute(src: src, span: span, norm: norm, trig: trig).z
            return Array(z.suffix(count))
        }
        let x = (0...i).map { s.qty[$0] * s.close[$0] }
        return Array(compute(x, ema: ema, span: span, norm: norm, trig: trig).z.suffix(count))
    }

    /// z on bar i only (the Filter's STEEP_Z) — computes just the src values the window needs.
    static func zAt(_ s: DeliverySeries, at i: Int) -> Double? {
        let n = min(s.qty.count, s.close.count)
        guard i < n else { return nil }
        let sp = span, nm = norm
        let need = nm + sp                                     // src[i − need + 1 … i]
        guard i - need + 1 >= 0 else { return nil }
        var src = [Double?](repeating: nil, count: need)
        if source == "delsma" {
            let m = Array(s.metric(value: true).prefix(i + 1))
            let L = DeliveryColumns.hiSma
            let sm = DeliverySignal.avg(m, L, ema: DeliveryMetric.signalIsEMA)
            guard m.count > L - 1 else { return nil }
            let valid = Array(sm[(L - 1)...])
            for k in 0..<need {
                let bar = i - need + 1 + k, vk = bar - (L - 1)
                if vk >= 0 { src[k] = DeliveryColumns.percentRank(valid, length: 300, at: vk) }
            }
        } else {
            let x = (0...i).map { s.qty[$0] * s.close[$0] }
            let all = compute(x, ema: ema, span: sp, norm: nm, trig: trig)
            return all.z[i]
        }
        return compute(src: src, span: sp, norm: nm, trig: trig).z.last ?? nil
    }

    /// Pine semantics: ta.ema seeded with the SMA of the first `ema` values; ta.stdev = population (biased) σ;
    /// z = 0 while mu / sd are na (fewer than `norm` values of g).
    static func compute(_ x: [Double], ema L: Int, span: Int, norm: Int, trig: Double) -> Result {
        let n = x.count
        var src = [Double?](repeating: nil, count: n)
        let a = 2.0 / Double(L + 1)
        var prev: Double?, sum = 0.0
        for i in 0..<n {
            if let p = prev { prev = a * x[i] + (1 - a) * p }
            else { sum += x[i]; if i >= L - 1 { prev = sum / Double(L) } }
            src[i] = prev
        }
        return compute(src: src, span: span, norm: norm, trig: trig)
    }

    /// Steepness of any src. g = (src / src[span] − 1) × 100; for DELSMA (0–100) the divisor is floored at 1 so a
    /// rank of 0 doesn't divide by zero.
    static func compute(src: [Double?], span: Int, norm: Int, trig: Double) -> Result {
        let n = src.count
        var g = [Double?](repeating: nil, count: n)
        for i in 0..<n where i >= span {
            if let c = src[i], let p = src[i - span] { g[i] = (c / max(p, 1) - 1) * 100 }
        }
        var z = [Double?](repeating: nil, count: n), run = [Int](repeating: 0, count: n)
        var energy = [Double](repeating: 0, count: n), steep = [Bool](repeating: false, count: n)
        var e = 0.0, lastNot = -1
        for i in 0..<n {
            var zi = 0.0
            if let gi = g[i], i >= norm - 1 {
                let w = g[(i - norm + 1)...i]
                if !w.contains(where: { $0 == nil }) {
                    let vals = w.map { $0! }
                    let mu = vals.reduce(0, +) / Double(norm)
                    let sd = (vals.reduce(0) { $0 + ($1 - mu) * ($1 - mu) } / Double(norm)).squareRoot()
                    zi = sd > 0 ? (gi - mu) / sd : 0
                    z[i] = zi
                }
            }
            let isSteep = zi > trig
            steep[i] = isSteep
            if !isSteep { lastNot = i }
            run[i] = isSteep ? (lastNot >= 0 ? i - lastNot : 0) : 0
            e = isSteep ? e + zi : 0
            energy[i] = e
        }
        return Result(z: z, run: run, energy: energy, steep: steep)
    }
}
