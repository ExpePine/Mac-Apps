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
