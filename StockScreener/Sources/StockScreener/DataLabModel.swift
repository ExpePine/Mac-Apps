import Foundation

// MARK: - Tomorrow's candle: features from intraday bars, several models, honest walk-forward scoring
//
// For each stock and day d (with intraday bars), features describe how day d traded; the targets are the NEXT
// day's open (gap), high, low and close, all as % of day d's close. Models, all fitted across every stock at once:
//   • Naive        — gap 0, close 0, high / low = the stock's average excursion over its last 10 days
//   • HAR          — volatility model (Corsi 2009): today's, this week's and this month's realised volatility
//   • Ridge        — L2-regularised linear regression on all features
//   • Analogs (kNN)— the 40 most similar past stock-days; what happened the day after them
//   • Ensemble     — the above weighted by 1 / their walk-forward error
// Direction: logistic regression and the analogs' share of up days, averaged.
// Bands: conformal prediction — the 80th percentile of the ensemble's out-of-sample errors.
// Scoring: walk-forward — for each of the last test days, everything is re-fitted on earlier days only.

enum LabFeatures {
    static let names = [
        "Day return", "Gap at open", "First 30-min return", "Last 30-min return", "Last 60-min return",
        "Close in day's range", "Close vs VWAP", "Realised vol (day)", "Realised vol (week)", "Realised vol (month)",
        "Day range", "Last-hour volume share", "Volume vs 10-day avg", "5-day return", "Intraday trend",
        "Upper wick", "Lower wick", "Friday", "NIFTY day return", "Last 15-min return", "Choppiness (last hour)",
    ]
    static var count: Int { names.count }
    static let targets = ["Open (gap)", "High", "Low", "Close"]
    static let harIdx = [7, 8, 9, 10]
}

struct LabSample {
    let sym: String
    let day: String
    var x: [Float]
    var y: [Float]          // gap, high, low, close (fractions of today's close); empty when tomorrow isn't known yet
    var naive: [Float]
    let close: Float
}

enum LabBuild {
    /// Samples for one stock. `market` = NIFTY day returns by day. `m1` adds last-15-min / choppiness from 1-minute bars.
    static func samples(_ sym: String, m5: OHLCV, m1: OHLCV?, market: [String: Float]) -> [LabSample] {
        let days = m5.days()
        guard days.count >= 6 else { return [] }
        let d1 = m1.map { Dictionary($0.days().map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a }) } ?? [:]
        var rv: [Float] = []
        for d in days {
            var s: Float = 0
            for i in d.range.dropFirst() { let r = log(m5.c[i] / max(m5.c[i - 1], 1e-6)); s += r * r }
            rv.append(sqrt(s))
        }
        let cal = { () -> Calendar in var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }()
        let df = { () -> DateFormatter in let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"; return f }()
        var out: [LabSample] = []
        for i in 5..<days.count {
            let d = days[i], p = days[i - 1]
            guard p.c > 0, d.c > 0, d.range.count >= 20 else { continue }
            let ret = d.c / p.c - 1
            if abs(ret) > 0.25 { continue }                                     // split / bad data
            let idx = Array(d.range)
            func closeAt(_ k: Int) -> Float { m5.c[idx[max(0, min(idx.count - 1, k))]] }
            let n = idx.count
            var pv: Float = 0, vv: Float = 0, lastHourV: Float = 0
            for (k, j) in idx.enumerated() {
                let tp = (m5.h[j] + m5.l[j] + m5.c[j]) / 3
                pv += tp * m5.v[j]; vv += m5.v[j]
                if k >= n - 12 { lastHourV += m5.v[j] }
            }
            let vwap = vv > 0 ? pv / vv : d.c
            let rng = d.h - d.l
            let avgV = days[max(0, i - 10)..<i].map(\.v).reduce(0, +) / Float(min(10, i))
            // intraday trend: correlation of price with time
            var sx: Float = 0, sy: Float = 0, sxx: Float = 0, syy: Float = 0, sxy: Float = 0
            for (k, j) in idx.enumerated() { let x = Float(k), y = m5.c[j]; sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y }
            let nf = Float(n)
            let den = sqrt(max(1e-12, (nf * sxx - sx * sx) * (nf * syy - sy * sy)))
            let trend = (nf * sxy - sx * sy) / den
            let wk = rv[max(0, i - 4)...i].reduce(0, +) / Float(min(5, i + 1))
            let mo = rv[max(0, i - 21)...i].reduce(0, +) / Float(min(22, i + 1))
            var last15 = closeAt(n - 1) / closeAt(n - 4) - 1
            var chop: Float = 0
            if let one = d1[d.day], one.range.count >= 60 {
                let j = Array(one.range)
                let c1 = m1!.c
                last15 = c1[j[j.count - 1]] / max(c1[j[max(0, j.count - 16)]], 1e-6) - 1
                var flips = 0, prev: Float = 0
                for k in max(1, j.count - 60)..<j.count {
                    let r = c1[j[k]] - c1[j[k - 1]]
                    if r != 0 { if prev != 0 && (r > 0) != (prev > 0) { flips += 1 }; prev = r }
                }
                chop = Float(flips) / 59
            } else {
                var flips = 0, prev: Float = 0
                for k in max(1, n - 12)..<n {
                    let r = m5.c[idx[k]] - m5.c[idx[k - 1]]
                    if r != 0 { if prev != 0 && (r > 0) != (prev > 0) { flips += 1 }; prev = r }
                }
                chop = Float(flips) / 11
            }
            let friday: Float = df.date(from: d.day).map { cal.component(.weekday, from: $0) == 6 ? 1 : 0 } ?? 0
            let x: [Float] = [
                ret, d.o / p.c - 1, closeAt(5) / d.o - 1, closeAt(n - 1) / closeAt(n - 7) - 1, closeAt(n - 1) / closeAt(n - 13) - 1,
                rng > 0 ? (d.c - d.l) / rng - 0.5 : 0, d.c / vwap - 1, log(rv[i] + 1e-4), log(wk + 1e-4), log(mo + 1e-4),
                rng / p.c, vv > 0 ? lastHourV / vv : 0, log((d.v + 1) / (avgV + 1)), d.c / days[i - 5].c - 1, trend,
                rng > 0 ? (d.h - max(d.o, d.c)) / rng : 0, rng > 0 ? (min(d.o, d.c) - d.l) / rng : 0, friday,
                market[d.day] ?? 0, last15, chop,
            ].map { $0.isFinite ? $0 : 0 }
            // naive: the stock's usual excursion over its last 10 days
            var hiEx: Float = 0, loEx: Float = 0, m: Float = 0
            for k in max(1, i - 9)...i { let pc = days[k - 1].c; if pc > 0 { hiEx += days[k].h / pc - 1; loEx += days[k].l / pc - 1; m += 1 } }
            let naive: [Float] = [0, m > 0 ? hiEx / m : 0, m > 0 ? loEx / m : 0, 0]
            var y: [Float] = []
            if i + 1 < days.count {
                let nx = days[i + 1]
                y = [nx.o / d.c - 1, nx.h / d.c - 1, nx.l / d.c - 1, nx.c / d.c - 1]
                if y.contains(where: { !$0.isFinite || abs($0) > 0.25 }) { continue }
            }
            out.append(LabSample(sym: sym, day: d.day, x: x, y: y, naive: naive, close: d.c))
        }
        return out
    }

    static func marketReturns(_ m5: OHLCV?) -> [String: Float] {
        guard let days = m5?.days(), days.count > 1 else { return [:] }
        var out: [String: Float] = [:]
        for i in 1..<days.count where days[i - 1].c > 0 { out[days[i].day] = days[i].c / days[i - 1].c - 1 }
        return out
    }
}

// MARK: - Maths

enum LabMath {
    struct Scaler {
        var mean: [Double], sd: [Double]
        init(_ rows: [[Float]], dims: Int) {
            var m = [Double](repeating: 0, count: dims), s = m
            for r in rows { for k in 0..<dims { m[k] += Double(r[k]) } }
            let n = Double(max(1, rows.count))
            for k in 0..<dims { m[k] /= n }
            for r in rows { for k in 0..<dims { let d = Double(r[k]) - m[k]; s[k] += d * d } }
            for k in 0..<dims { s[k] = max(1e-9, sqrt(s[k] / n)) }
            mean = m; sd = s
        }
        func apply(_ r: [Float], idx: [Int]? = nil) -> [Double] {
            (idx ?? Array(0..<mean.count)).map { k in max(-5, min(5, (Double(r[k]) - mean[k]) / sd[k])) }
        }
    }

    /// Solves A x = b (A symmetric positive definite) by Gaussian elimination with partial pivoting.
    static func solve(_ A: [[Double]], _ b: [Double]) -> [Double] {
        var a = A, y = b
        let n = b.count
        for i in 0..<n {
            var p = i
            for r in (i + 1)..<n where abs(a[r][i]) > abs(a[p][i]) { p = r }
            a.swapAt(i, p); y.swapAt(i, p)
            let d = a[i][i]
            guard abs(d) > 1e-12 else { continue }
            for r in (i + 1)..<n {
                let f = a[r][i] / d
                if f == 0 { continue }
                for c in i..<n { a[r][c] -= f * a[i][c] }
                y[r] -= f * y[i]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for c in (i + 1)..<n { s -= a[i][c] * x[c] }
            x[i] = abs(a[i][i]) > 1e-12 ? s / a[i][i] : 0
        }
        return x
    }

    struct Linear { var b0: Double; var w: [Double]
        func predict(_ x: [Double]) -> Double { var s = b0; for k in 0..<w.count { s += w[k] * x[k] }; return s }
    }

    /// Ridge regression on standardised X (intercept not penalised).
    static func ridge(_ X: [[Double]], _ y: [Double], lambda: Double) -> Linear {
        let n = X.count, d = X.first?.count ?? 0
        guard n > d + 2 else { return Linear(b0: y.isEmpty ? 0 : y.reduce(0, +) / Double(y.count), w: [Double](repeating: 0, count: d)) }
        let ym = y.reduce(0, +) / Double(n)
        var xm = [Double](repeating: 0, count: d)
        for r in X { for k in 0..<d { xm[k] += r[k] } }
        for k in 0..<d { xm[k] /= Double(n) }
        var A = [[Double]](repeating: [Double](repeating: 0, count: d), count: d), b = [Double](repeating: 0, count: d)
        for (i, r) in X.enumerated() {
            let yy = y[i] - ym
            for p in 0..<d {
                let xp = r[p] - xm[p]
                b[p] += xp * yy
                for q in p..<d { A[p][q] += xp * (r[q] - xm[q]) }
            }
        }
        for p in 0..<d { for q in 0..<p { A[p][q] = A[q][p] }; A[p][p] += lambda * Double(n) }
        let w = solve(A, b)
        var b0 = ym
        for k in 0..<d { b0 -= w[k] * xm[k] }
        return Linear(b0: b0, w: w)
    }

    /// L2 logistic regression by gradient descent; returns P(y = 1).
    static func logistic(_ X: [[Double]], _ y: [Double], lambda: Double = 0.01, iters: Int = 100) -> Linear {
        let n = X.count, d = X.first?.count ?? 0
        let base = y.reduce(0, +) / Double(max(1, n))
        var m = Linear(b0: log(max(1e-6, base) / max(1e-6, 1 - base)), w: [Double](repeating: 0, count: d))
        guard n > 10 else { return m }
        let lr = 0.5
        for _ in 0..<iters {
            var g0 = 0.0, g = [Double](repeating: 0, count: d)
            for (i, r) in X.enumerated() {
                let p = 1 / (1 + exp(-m.predict(r)))
                let e = p - y[i]
                g0 += e
                for k in 0..<d { g[k] += e * r[k] }
            }
            m.b0 -= lr * g0 / Double(n)
            for k in 0..<d { m.w[k] -= lr * (g[k] / Double(n) + lambda * m.w[k]) }
        }
        return m
    }

    static func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-z)) }

    static func quantile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))]
    }
}

/// k nearest neighbours over standardised features (flat Float storage for speed).
struct LabKNN {
    let dims: Int
    var flat: [Float] = []
    var ys: [[Float]] = []
    var keys: [(String, String)] = []

    init(_ X: [[Double]], _ Y: [[Float]], keys: [(String, String)]) {
        dims = X.first?.count ?? 0
        flat.reserveCapacity(X.count * dims)
        for r in X { for v in r { flat.append(Float(v)) } }
        ys = Y; self.keys = keys
    }

    /// Indices of the k nearest rows.
    func nearest(_ x: [Double], k: Int = 40) -> [Int] {
        let n = ys.count
        guard n > 0 else { return [] }
        let q = x.map(Float.init)
        var best: [(Float, Int)] = []
        best.reserveCapacity(k + 1)
        var worst = Float.greatestFiniteMagnitude
        flat.withUnsafeBufferPointer { f in
            for i in 0..<n {
                var s: Float = 0
                let o = i * dims
                for j in 0..<dims { let d = f[o + j] - q[j]; s += d * d; if best.count == k && s >= worst { break } }
                if best.count < k {
                    best.append((s, i)); if best.count == k { best.sort { $0.0 < $1.0 }; worst = best[k - 1].0 }
                } else if s < worst {
                    var p = k - 1
                    while p > 0 && best[p - 1].0 > s { best[p] = best[p - 1]; p -= 1 }
                    best[p] = (s, i); worst = best[k - 1].0
                }
            }
        }
        return best.map(\.1)
    }
}

// MARK: - Fit, score, predict

struct LabPrediction: Codable, Identifiable {
    var id: String { sym }
    let sym: String
    let asOf: String
    let close: Float
    let point: [Double]          // gap, high, low, close (fractions)
    let band: [Double]           // ± half-width (80%)
    let pUp: Double
    let analogs: [String]        // "SYMBOL yyyy-MM-dd → +1.2%"
    let drivers: [String]        // "Last 30-min return ↑ +0.012"
}

struct LabScore: Codable {
    struct Row: Codable { let target: String; let mae: [Double]; let coverage: Double }   // mae: naive, HAR, ridge, kNN, ensemble
    var rows: [Row] = []
    var dirHit = 0.0, dirBase = 0.0, brier = 0.0, brierBase = 0.0
    var testDays: [String] = []
    var nTest = 0
    var nTrain = 0
    static let models = ["Naive", "HAR", "Ridge", "Analogs", "Ensemble"]
}

struct LabResult: Codable {
    var predictions: [LabPrediction] = []
    var score = LabScore()
    var asOf = ""
    var ranAt = Date()
    var weights: [[Double]] = []     // per target: weight of HAR, ridge, kNN, naive
}

enum LabEngine {
    private struct Fit {
        var scaler: LabMath.Scaler
        var ridge: [LabMath.Linear]
        var har: [LabMath.Linear]
        var logit: LabMath.Linear
        var knn: LabKNN
    }

    private static func fit(_ train: [LabSample], lambda: Double, maxKNN: Int = 25_000) -> Fit {
        let dims = LabFeatures.count
        let sc = LabMath.Scaler(train.map(\.x), dims: dims)
        let X = train.map { sc.apply($0.x) }
        let H = train.map { sc.apply($0.x, idx: LabFeatures.harIdx) }
        var ridge: [LabMath.Linear] = [], har: [LabMath.Linear] = []
        for t in 0..<4 {
            let y = train.map { Double($0.y[t]) }
            ridge.append(LabMath.ridge(X, y, lambda: lambda))
            har.append(LabMath.ridge(H, y, lambda: 0.001))
        }
        let logit = LabMath.logistic(X, train.map { $0.y[3] > 0 ? 1 : 0 })
        let recent = Array(train.suffix(maxKNN))
        let knn = LabKNN(recent.map { sc.apply($0.x) }, recent.map(\.y), keys: recent.map { ($0.sym, $0.day) })
        return Fit(scaler: sc, ridge: ridge, har: har, logit: logit, knn: knn)
    }

    /// Per-model predictions for one sample: [model][target] (naive, HAR, ridge, kNN) + P(up) parts.
    private static func predictAll(_ f: Fit, _ s: LabSample) -> (models: [[Double]], pLogit: Double, pKNN: Double, nn: [Int], x: [Double]) {
        let x = f.scaler.apply(s.x), h = f.scaler.apply(s.x, idx: LabFeatures.harIdx)
        let nn = f.knn.nearest(x)
        var knn = [Double](repeating: 0, count: 4), up = 0.0
        for i in nn { for t in 0..<4 { knn[t] += Double(f.knn.ys[i][t]) }; if f.knn.ys[i][3] > 0 { up += 1 } }
        let k = Double(max(1, nn.count))
        knn = knn.map { $0 / k }
        let naive = s.naive.map(Double.init)
        let har = (0..<4).map { t in t == 0 || t == 3 ? 0 : f.har[t].predict(h) }
        let ridge = (0..<4).map { f.ridge[$0].predict(x) }
        return ([naive, har, ridge, knn], LabMath.sigmoid(f.logit.predict(x)), up / k, nn, x)
    }

    private static func combine(_ m: [[Double]], _ w: [[Double]]) -> [Double] {
        (0..<4).map { t in
            let ws = w[t]
            let tot = ws.reduce(0, +)
            guard tot > 0 else { return m[0][t] }
            return (0..<4).reduce(0) { $0 + ws[$1] * m[$1][t] } / tot
        }
    }

    /// Walk-forward over the last `testDays` days, then a final fit on everything for tomorrow's candles.
    static func run(_ all: [LabSample], testDays: Int = 10, progress: ((String) -> Void)? = nil) -> LabResult {
        var res = LabResult()
        let known = all.filter { !$0.y.isEmpty }.sorted { $0.day < $1.day }
        let live = all.filter { $0.y.isEmpty }
        let dates = Array(Set(known.map(\.day))).sorted()
        res.asOf = live.map(\.day).max() ?? (dates.last ?? "")
        guard dates.count >= 8, known.count >= 200 else { return res }
        let lambda = 0.05
        let tests = Array(dates.suffix(min(testDays, max(2, dates.count / 4))))
        res.score.testDays = tests
        // out-of-sample errors per model and target, plus direction
        var errs = [[[Double]]](repeating: [[Double]](repeating: [], count: 4), count: 4)      // [model][target]
        var oos: [(m: [[Double]], y: [Float], pL: Double, pK: Double)] = []
        for (n, d) in tests.enumerated() {
            progress?("Walk-forward \(n + 1)/\(tests.count): fitting on days before \(d)…")
            let train = known.filter { $0.day < d }
            guard train.count >= 150 else { continue }
            let f = fit(train, lambda: lambda, maxKNN: 15_000)
            var test = known.filter { $0.day == d }
            if test.count > 400 { test = Array(test.shuffled().prefix(400)) }
            for s in test {
                let p = predictAll(f, s)
                for m in 0..<4 { for t in 0..<4 { errs[m][t].append(abs(p.models[m][t] - Double(s.y[t]))) } }
                oos.append((p.models, s.y, p.pLogit, p.pKNN))
            }
            res.score.nTrain = train.count
        }
        guard !oos.isEmpty else { return res }
        // ensemble weights: 1 / MAE², only models that beat the naive one on that target (naive always kept)
        var w: [[Double]] = []
        for t in 0..<4 {
            let mae = (0..<4).map { m in errs[m][t].reduce(0, +) / Double(max(1, errs[m][t].count)) }
            var wt = mae.map { 1 / max(1e-9, $0 * $0) }
            for m in 1..<4 where mae[m] >= mae[0] || ((t == 0 || t == 3) && m == 1) { wt[m] = 0 }
            w.append(wt)
        }
        res.weights = w
        // ensemble errors and conformal bands (first half calibrates, second half checks coverage)
        let half = oos.count / 2
        var ensErr = [[Double]](repeating: [], count: 4), q = [Double](repeating: 0, count: 4), cover = [Double](repeating: 0, count: 4)
        for (i, o) in oos.enumerated() {
            let e = combine(o.m, w)
            for t in 0..<4 { ensErr[t].append(abs(e[t] - Double(o.y[t]))); _ = i }
        }
        for t in 0..<4 {
            q[t] = LabMath.quantile(Array(ensErr[t].prefix(max(1, half))), 0.8)
            let check = ensErr[t].suffix(oos.count - half)
            cover[t] = check.isEmpty ? 0 : Double(check.filter { $0 <= q[t] }.count) / Double(check.count)
            q[t] = LabMath.quantile(ensErr[t], 0.8)                 // final bands use all out-of-sample errors
        }
        for t in 0..<4 {
            let maes = (0..<4).map { m in errs[m][t].reduce(0, +) / Double(max(1, errs[m][t].count)) } + [ensErr[t].reduce(0, +) / Double(ensErr[t].count)]
            res.score.rows.append(.init(target: LabFeatures.targets[t], mae: maes, coverage: cover[t]))
        }
        // direction
        let upRate = Double(oos.filter { $0.y[3] > 0 }.count) / Double(oos.count)
        var hit = 0.0, brier = 0.0, brierBase = 0.0
        let trainUp = Double(known.filter { $0.day < tests[0] && $0.y[3] > 0 }.count) / Double(max(1, known.filter { $0.day < tests[0] }.count))
        for o in oos {
            let p = (o.pL + o.pK) / 2, up = o.y[3] > 0 ? 1.0 : 0.0
            if (p >= 0.5) == (up == 1) { hit += 1 }
            brier += (p - up) * (p - up); brierBase += (trainUp - up) * (trainUp - up)
        }
        res.score.dirHit = hit / Double(oos.count)
        res.score.dirBase = max(upRate, 1 - upRate)
        res.score.brier = brier / Double(oos.count)
        res.score.brierBase = brierBase / Double(oos.count)
        res.score.nTest = oos.count

        // final fit on everything known → tomorrow
        progress?("Fitting on all \(known.count) stock-days and predicting \(live.count) stocks…")
        let f = fit(known, lambda: lambda)
        let latest = res.asOf
        for s in live where s.day == latest {
            let p = predictAll(f, s)
            let point = combine(p.models, w)
            let analogs = p.nn.prefix(6).map { i -> String in
                let (sym, day) = f.knn.keys[i]
                return "\(sym) \(day) → next day \(String(format: "%+.1f%%", f.knn.ys[i][3] * 100))"
            }
            // biggest pushes on tomorrow's close from the ridge model (coefficient × today's standardised value)
            let contrib = (0..<LabFeatures.count).map { k in (k, f.ridge[3].w[k] * p.x[k]) }.sorted { abs($0.1) > abs($1.1) }.prefix(5)
            let drivers = contrib.map { "\(LabFeatures.names[$0.0]) \($0.1 >= 0 ? "↑" : "↓") \(String(format: "%+.2f%%", $0.1 * 100))" }
            res.predictions.append(LabPrediction(sym: s.sym, asOf: s.day, close: s.close, point: point, band: q,
                                                 pUp: (p.pLogit + p.pKNN) / 2, analogs: analogs, drivers: drivers))
        }
        res.ranAt = Date()
        return res
    }
}
