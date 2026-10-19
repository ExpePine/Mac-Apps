import Foundation

/// Small statistics toolkit used by the pattern detectors.
enum Stats {
    static func normalCDF(_ x: Double) -> Double { 0.5 * (1 + erf(x / 2.0.squareRoot())) }

    /// Inverse normal CDF (Acklam's rational approximation, |error| < 1.2e-9).
    static func normalQuantile(_ p: Double) -> Double {
        let p = min(max(p, 1e-12), 1 - 1e-12)
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let lo = 0.02425, hi = 1 - lo
        if p < lo {
            let q = (-2 * log(p)).squareRoot()
            return (((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
        }
        if p > hi {
            let q = (-2 * log(1 - p)).squareRoot()
            return -(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
        }
        let q = p - 0.5, r = q * q
        return (((((a[0]*r+a[1])*r+a[2])*r+a[3])*r+a[4])*r+a[5])*q / (((((b[0]*r+b[1])*r+b[2])*r+b[3])*r+b[4])*r+1)
    }

    /// One-sided P(X ≥ k) for X ~ Binomial(n, p): exact sum in log space (n ≤ 300), normal approximation above.
    static func binomialUpperTail(k: Int, n: Int, p: Double) -> Double {
        guard n > 0, k > 0 else { return 1 }
        guard p > 0 else { return 0 }
        guard p < 1 else { return 1 }
        if n > 300 {
            let mu = Double(n) * p, sd = (Double(n) * p * (1 - p)).squareRoot()
            return 1 - normalCDF((Double(k) - 0.5 - mu) / sd)
        }
        let lp = log(p), lq = log(1 - p)
        func logChoose(_ n: Int, _ k: Int) -> Double { lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1)) }
        var terms: [Double] = []
        for i in k...n { terms.append(logChoose(n, i) + Double(i) * lp + Double(n - i) * lq) }
        let m = terms.max() ?? 0
        return min(1, exp(m) * terms.reduce(0) { $0 + exp($1 - m) })
    }

    /// Benjamini–Hochberg q-values for p-values out of `m` total tests (m ≥ count).
    static func benjaminiHochberg(_ p: [Double], totalTests m: Int? = nil) -> [Double] {
        let n = p.count
        guard n > 0 else { return [] }
        let tests = Double(max(n, m ?? n))
        let order = p.indices.sorted { p[$0] < p[$1] }
        var q = [Double](repeating: 1, count: n)
        var running = 1.0
        for (rank, i) in order.enumerated().reversed() {
            running = min(running, p[i] * tests / Double(rank + 1))
            q[i] = min(1, running)
        }
        return q
    }

    static func moments(_ v: [Double]) -> (mean: Double, sd: Double, skew: Double, kurt: Double) {
        let n = Double(v.count)
        guard n >= 2 else { return (v.first ?? 0, 0, 0, 3) }
        let m = v.reduce(0, +) / n
        let m2 = v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / n
        let m3 = v.reduce(0) { $0 + pow($1 - m, 3) } / n
        let m4 = v.reduce(0) { $0 + pow($1 - m, 4) } / n
        let sd = m2.squareRoot()
        return (m, sd, sd > 0 ? m3 / pow(sd, 3) : 0, sd > 0 ? m4 / (m2 * m2) : 3)
    }

    /// Deflated Sharpe Ratio (Bailey & López de Prado): probability that a strategy's true Sharpe is above zero,
    /// after allowing for how many strategies were tried (`trials`) and how much their Sharpes varied.
    static func deflatedSharpe(returns: [Double], trials: Int, sharpeVarianceAcrossTrials: Double) -> Double? {
        let mo = moments(returns)
        guard mo.sd > 0 else { return nil }
        return deflatedSharpe(sr: mo.mean / mo.sd, observations: returns.count, skew: mo.skew, kurtosis: mo.kurt,
                              trials: trials, sharpeVarianceAcrossTrials: sharpeVarianceAcrossTrials)
    }

    static func deflatedSharpe(sr: Double, observations: Int, skew: Double, kurtosis: Double,
                               trials: Int, sharpeVarianceAcrossTrials: Double) -> Double? {
        let t = Double(observations)
        guard t >= 10 else { return nil }
        let n = Double(max(2, trials))
        let gamma = 0.5772156649
        let sr0 = max(0, sharpeVarianceAcrossTrials).squareRoot()
            * ((1 - gamma) * normalQuantile(1 - 1 / n) + gamma * normalQuantile(1 - 1 / (n * M_E)))
        let denom = 1 - skew * sr + (kurtosis - 1) / 4 * sr * sr
        guard denom > 0 else { return nil }
        return normalCDF((sr - sr0) * (t - 1).squareRoot() / denom.squareRoot())
    }
}

// MARK: - Gradient-boosted trees (binary) with exact Shapley explanations

/// Small gradient-boosting classifier: logistic loss, Newton leaf values, depth ≤ 3, row subsampling,
/// learned default direction for blanks. Features are grouped (a one-hot block counts as one feature for SHAP).
struct GBM {
    struct Node {
        var feature = -1          // -1 = leaf
        var threshold = 0.0
        var missingLeft = true
        var left = -1, right = -1
        var value = 0.0           // leaf output (log-odds)
        var cover = 0.0           // training rows that reached this node (for SHAP expectations)
    }
    var trees: [[Node]] = []
    var base = 0.0
    var learningRate = 0.1

    static func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-max(-30, min(30, z)))) }

    func rawScore(_ x: [Double?]) -> Double {
        var s = base
        for t in trees {
            var i = 0
            while t[i].feature >= 0 {
                let n = t[i]
                if let v = x[n.feature] { i = v <= n.threshold ? n.left : n.right } else { i = n.missingLeft ? n.left : n.right }
            }
            s += learningRate * t[i].value
        }
        return s
    }

    func predict(_ x: [Double?]) -> Double { Self.sigmoid(rawScore(x)) }

    static func train(_ xs: [[Double?]], _ ys: [Bool], rounds: Int = 120, depth: Int = 3, minLeaf: Int = 20,
                      lambda: Double = 1, learningRate: Double = 0.1, subsample: Double = 0.8, seed: UInt64 = 5) -> GBM {
        var model = GBM()
        model.learningRate = learningRate
        let n = xs.count, d = xs.first?.count ?? 0
        guard n > 0, d > 0 else { return model }
        let pos = Double(ys.filter { $0 }.count)
        let p0 = min(0.99, max(0.01, pos / Double(n)))
        model.base = log(p0 / (1 - p0))
        var score = [Double](repeating: model.base, count: n)
        // candidate thresholds: up to 16 quantiles per feature
        var cuts: [[Double]] = []
        for j in 0..<d {
            let v = Array(Set(xs.compactMap { $0[j] })).sorted()
            if v.count <= 16 { cuts.append(v.count > 1 ? Array(v.dropLast()) : []) }
            else { cuts.append((1..<16).map { v[$0 * v.count / 16] }) }
        }
        // bin index per row/feature: bin b means value ≤ cuts[b] (b == cuts.count: above all cuts); -1 = blank
        var bins = [[Int]](repeating: [Int](repeating: -1, count: d), count: n)
        for i in 0..<n {
            for j in 0..<d {
                guard let v = xs[i][j] else { continue }
                var lo = 0, hi = cuts[j].count
                while lo < hi { let mid = (lo + hi) / 2; if v <= cuts[j][mid] { hi = mid } else { lo = mid + 1 } }
                bins[i][j] = lo
            }
        }
        var rng = SeededRandom(seed: seed)
        for _ in 0..<rounds {
            var g = [Double](repeating: 0, count: n), h = g
            for i in 0..<n {
                let p = sigmoid(score[i])
                g[i] = p - (ys[i] ? 1 : 0); h[i] = max(1e-6, p * (1 - p))
            }
            let rows = (0..<n).filter { _ in Double(rng.next() % 10_000) / 10_000 < subsample }
            var nodes: [Node] = []
            func build(_ idx: [Int], _ level: Int) -> Int {
                let G = idx.reduce(0) { $0 + g[$1] }, H = idx.reduce(0) { $0 + h[$1] }
                let me = nodes.count
                nodes.append(Node(value: -G / (H + lambda), cover: Double(idx.count)))
                guard level < depth, idx.count >= 2 * minLeaf else { return me }
                let parentScore = G * G / (H + lambda)
                var best: (gain: Double, f: Int, t: Double, missLeft: Bool) = (1e-6, -1, 0, true)
                for j in 0..<d where !cuts[j].isEmpty {
                    let K = cuts[j].count
                    var hg = [Double](repeating: 0, count: K + 1), hh = hg, hc = [Int](repeating: 0, count: K + 1)
                    var GM = 0.0, HM = 0.0, nM = 0
                    for i in idx {
                        let b = bins[i][j]
                        if b < 0 { GM += g[i]; HM += h[i]; nM += 1 } else { hg[b] += g[i]; hh[b] += h[i]; hc[b] += 1 }
                    }
                    var GL = 0.0, HL = 0.0, nL = 0
                    let nPresent = idx.count - nM
                    for k in 0..<K {
                        GL += hg[k]; HL += hh[k]; nL += hc[k]
                        let GR = G - GM - GL, HR = H - HM - HL, nR = nPresent - nL
                        for missLeft in [true, false] {
                            let gl = GL + (missLeft ? GM : 0), hl = HL + (missLeft ? HM : 0), cl = nL + (missLeft ? nM : 0)
                            let gr = GR + (missLeft ? 0 : GM), hr = HR + (missLeft ? 0 : HM), cr = nR + (missLeft ? 0 : nM)
                            guard cl >= minLeaf, cr >= minLeaf else { continue }
                            let gain = gl * gl / (hl + lambda) + gr * gr / (hr + lambda) - parentScore
                            if gain > best.gain { best = (gain, j, cuts[j][k], missLeft) }
                        }
                    }
                }
                guard best.f >= 0 else { return me }
                let goesLeft: (Int) -> Bool = { i in xs[i][best.f].map { $0 <= best.t } ?? best.missLeft }
                let l = build(idx.filter(goesLeft), level + 1)
                let r = build(idx.filter { !goesLeft($0) }, level + 1)
                nodes[me].feature = best.f; nodes[me].threshold = best.t; nodes[me].missingLeft = best.missLeft
                nodes[me].left = l; nodes[me].right = r
                return me
            }
            _ = build(rows.isEmpty ? Array(0..<n) : rows, 0)
            // covers for SHAP should reflect all rows: recount on the full data
            var t = nodes
            for k in t.indices { t[k].cover = 0 }
            for i in 0..<n {
                var k = 0
                t[0].cover += 1
                while t[k].feature >= 0 {
                    let nd = t[k]
                    k = xs[i][nd.feature].map { $0 <= nd.threshold ? nd.left : nd.right } ?? (nd.missingLeft ? nd.left : nd.right)
                    t[k].cover += 1
                }
            }
            model.trees.append(t)
            for i in 0..<n {
                var k = 0
                while t[k].feature >= 0 {
                    let nd = t[k]
                    k = xs[i][nd.feature].map { $0 <= nd.threshold ? nd.left : nd.right } ?? (nd.missingLeft ? nd.left : nd.right)
                }
                score[i] += learningRate * t[k].value
            }
        }
        return model
    }

    /// E[f(x) | features in `known` fixed to x] using the trees' training covers (path-dependent expectation).
    private func conditional(_ x: [Double?], known: (Int) -> Bool) -> Double {
        var s = base
        for t in trees {
            func walk(_ k: Int) -> Double {
                let nd = t[k]
                guard nd.feature >= 0 else { return nd.value }
                if known(nd.feature) {
                    let next = x[nd.feature].map { $0 <= nd.threshold ? nd.left : nd.right } ?? (nd.missingLeft ? nd.left : nd.right)
                    return walk(next)
                }
                let cl = t[nd.left].cover, cr = t[nd.right].cover
                guard cl + cr > 0 else { return nd.value }
                return (cl * walk(nd.left) + cr * walk(nd.right)) / (cl + cr)
            }
            s += learningRate * walk(0)
        }
        return s
    }

    /// Exact Shapley values (log-odds) for feature GROUPS (`groupOf[feature] = group`), enumerating all subsets.
    func shap(_ x: [Double?], groupOf: [Int], groups: Int) -> [Double] {
        let m = groups
        guard m <= 12 else { return [Double](repeating: 0, count: m) }
        var v = [Double](repeating: 0, count: 1 << m)
        for mask in 0..<(1 << m) { v[mask] = conditional(x, known: { mask & (1 << groupOf[$0]) != 0 }) }
        var fact = [1.0]; for i in 1...max(1, m) { fact.append(fact[i - 1] * Double(i)) }
        var phi = [Double](repeating: 0, count: m)
        for i in 0..<m {
            for mask in 0..<(1 << m) where mask & (1 << i) == 0 {
                let s = mask.nonzeroBitCount
                let w = fact[s] * fact[m - s - 1] / fact[m]
                phi[i] += w * (v[mask | (1 << i)] - v[mask])
            }
        }
        return phi
    }
}
