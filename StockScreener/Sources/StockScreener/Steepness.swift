import Foundation

/// "Sustained steepness" (your Pine indicator), on NSE delivery value (DELIV_QTY × CLOSE):
///   src = ta.ema(delVal, 66) · g = (src / src[span] − 1) × 100
///   mu = ta.sma(g, norm) · sd = ta.stdev(g, norm) · z = sd > 0 ? (g − mu) / sd : 0
///   isSteep = z > trig · run = isSteep ? ta.barssince(not isSteep) : 0 · energy = isSteep ? energy + z : 0
enum Steep {
    static var ema: Int { v("steep.ema", 66) }
    static var span: Int { v("steep.span", 5) }
    static var norm: Int { v("steep.norm", 250) }
    static var trig: Double { let d = UserDefaults.standard.double(forKey: "steep.trig"); return d > 0 ? d : 2.0 }
    private static func v(_ k: String, _ def: Int) -> Int { let i = UserDefaults.standard.integer(forKey: k); return i > 0 ? i : def }

    struct Result { var z: [Double?]; var run: [Int]; var energy: [Double]; var steep: [Bool] }

    static func series(_ s: DeliverySeries) -> Result {
        let n = min(s.qty.count, s.close.count)
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
        var g = [Double?](repeating: nil, count: n)
        for i in 0..<n where i >= span {
            if let c = src[i], let p = src[i - span], p != 0 { g[i] = (c / p - 1) * 100 }
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
