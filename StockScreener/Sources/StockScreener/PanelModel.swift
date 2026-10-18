import Foundation

// The "ranking model": learns from EVERY stored daily snapshot (stock × day), not one snapshot.
//
//  • Labels: the real forward gain over several horizons (e.g. 5, 10, 21 trading days) — not just ≥30% yes/no.
//  • Inputs: each chosen column ranked among all stocks that day (removes market mood), plus how it changed
//    since the previous snapshot (Δ1d) and 5 snapshots back (Δ5d).
//  • Network: small MLP + a pairwise "factorization" layer whose weights say which column pairs work together.
//  • Loss: regression on the ranked gains + a ranking loss on the main horizon (gainers above the rest).
//  • Ensemble of several nets → score = average rank; disagreement → confidence.
//  • Tested walk-forward (later days it never saw) when there are enough days, else on held-out stocks;
//    a chance check retrains on shuffled labels to show what luck alone scores.

extension PriceSeries {
    /// From the close on (or before) `day`: % change after exactly `h` trading days and the highest % gain
    /// reached within those `h` days. nil until `h` trading days have passed.
    func forward(_ h: Int, from day: String) -> (change: Double, maxGain: Double)? {
        guard let i = index(onOrBefore: day), i + h < closes.count, closes[i] > 0 else { return nil }
        let base = closes[i]
        let peak = closes[(i + 1)...(i + h)].max() ?? base
        return ((closes[i + h] / base - 1) * 100, (peak / base - 1) * 100)
    }
}

// MARK: - Dataset

struct PanelRow {
    let day: Int                 // index into PanelData.days
    let symbol: String
    var x: [Double]              // model inputs, each -1…1 (0 = blank / middle)
    let raw: [Double?]           // the chosen columns' own values (for combinations → filters)
    var fwd: [Double?]           // forward % change per horizon
    var fwdMax: [Double?]        // highest % gain within each horizon
    var target: [Double?]        // forward change ranked within the day, -1…1
}

struct PanelData {
    var days: [String] = []
    var rows: [PanelRow] = []
    var featureNames: [String] = []
    var levelNames: [String] = []
    var horizons: [Int] = []
}

enum PanelBuilder {
    typealias DayValues = [String: [Double?]]     // SYMBOL -> chosen columns' numbers

    static func dayValues(_ t: SheetTable, label: Int, cols: [Int]) -> DayValues {
        var out: DayValues = [:]
        for row in t.rows {
            let sym = row.text(label).trimmingCharacters(in: .whitespaces).uppercased()
            guard !sym.isEmpty, out[sym] == nil else { continue }
            out[sym] = cols.map { row.number($0) }
        }
        return out
    }

    /// Ranks among the day's stocks, centred to -1…1; blanks → 0. Ties share the average rank.
    static func ranks(_ v: [Double?]) -> [Double] {
        var out = [Double](repeating: 0, count: v.count)
        let present = v.enumerated().compactMap { i, x in x.map { (i, $0) } }.sorted { $0.1 < $1.1 }
        guard present.count > 1 else { return out }
        let denom = Double(present.count - 1)
        var k = 0
        while k < present.count {
            var e = k
            while e + 1 < present.count && present[e + 1].1 == present[k].1 { e += 1 }
            let r = (Double(k + e) / 2) / denom * 2 - 1
            for m in k...e { out[present[m].0] = r }
            k = e + 1
        }
        return out
    }

    static func featureNames(_ levels: [String]) -> [String] {
        levels + levels.map { "Δ1d " + $0 } + levels.map { "Δ5d " + $0 }
    }

    /// Inputs for `symbols` on one day: [level ranks…, Δ1d ranks…, Δ5d ranks…].
    static func features(today: DayValues, prev1: DayValues?, prev5: DayValues?, symbols: [String], columns: Int) -> [[Double]] {
        var x = [[Double]](repeating: [Double](repeating: 0, count: columns * 3), count: symbols.count)
        for c in 0..<columns {
            let level = symbols.map { today[$0]?[c] ?? nil }
            func delta(_ prev: DayValues?) -> [Double?] {
                symbols.map { s in
                    guard let a = today[s]?[c] ?? nil, let b = prev?[s]?[c] ?? nil else { return nil }
                    return a - b
                }
            }
            let r0 = ranks(level), r1 = ranks(delta(prev1)), r5 = ranks(delta(prev5))
            for i in symbols.indices {
                x[i][c] = r0[i]
                x[i][columns + c] = r1[i]
                x[i][2 * columns + c] = r5[i]
            }
        }
        return x
    }

    /// Builds labelled rows from stored days (oldest first). Rows without any forward label are skipped.
    static func build(days: [String], values: [DayValues], book: PriceBook, levelNames: [String], horizons: [Int]) -> PanelData {
        var data = PanelData(days: days, rows: [], featureNames: featureNames(levelNames), levelNames: levelNames, horizons: horizons)
        let cols = levelNames.count
        for t in days.indices {
            let today = values[t]
            let symbols = today.keys.sorted()
            let x = features(today: today, prev1: t >= 1 ? values[t - 1] : nil, prev5: t >= 5 ? values[t - 5] : nil,
                             symbols: symbols, columns: cols)
            var dayRows: [PanelRow] = []
            for (i, sym) in symbols.enumerated() {
                guard let s = book.series(for: sym) else { continue }
                let f = horizons.map { s.forward($0, from: days[t]) }
                guard f.contains(where: { $0 != nil }) else { continue }
                dayRows.append(PanelRow(day: t, symbol: sym, x: x[i], raw: today[sym] ?? [],
                                        fwd: f.map { $0?.change }, fwdMax: f.map { $0?.maxGain },
                                        target: Array(repeating: nil, count: horizons.count)))
            }
            // Targets: forward change ranked within the day
            for h in horizons.indices {
                let r = ranks(dayRows.map { $0.fwd[h] })
                for k in dayRows.indices where dayRows[k].fwd[h] != nil { dayRows[k].target[h] = r[k] }
            }
            data.rows += dayRows
        }
        return data
    }
}

// MARK: - Network

/// inputs → 16 ReLU → 8 ReLU → one output per horizon, plus a linear part and a pairwise (factorization) part.
struct PanelNet {
    let d: Int, outs: Int
    let h1 = 16, h2 = 8, k = 4
    var p: [Double]
    let oW1: Int, oB1: Int, oW2: Int, oB2: Int, oW3: Int, oB3: Int, oL: Int, oV: Int

    init(inputs: Int, outputs: Int, seed: UInt64) {
        d = inputs; outs = outputs
        oW1 = 0; oB1 = oW1 + 16 * inputs
        oW2 = oB1 + 16; oB2 = oW2 + 8 * 16
        oW3 = oB2 + 8; oB3 = oW3 + outputs * 8
        oL = oB3 + outputs; oV = oL + outputs * inputs
        p = [Double](repeating: 0, count: oV + inputs * 4)
        var rng = SeededRandom(seed: seed)
        for i in 0..<(16 * inputs) { p[oW1 + i] = rng.normal() * sqrt(2.0 / Double(max(1, inputs))) }
        for i in 0..<(8 * 16) { p[oW2 + i] = rng.normal() * sqrt(2.0 / 16) }
        for i in 0..<(outputs * 8) { p[oW3 + i] = rng.normal() * sqrt(1.0 / 8) }
        for i in 0..<(inputs * 4) { p[oV + i] = rng.normal() * 0.05 }
    }

    struct Cache { var a1: [Double]; var a2: [Double]; var s: [Double]; var out: [Double] }

    func forward(_ x: [Double]) -> Cache {
        var a1 = [Double](repeating: 0, count: h1)
        for a in 0..<h1 {
            var z = p[oB1 + a]
            let base = oW1 + a * d
            for i in 0..<d { z += p[base + i] * x[i] }
            a1[a] = max(0, z)
        }
        var a2 = [Double](repeating: 0, count: h2)
        for b in 0..<h2 {
            var z = p[oB2 + b]
            let base = oW2 + b * h1
            for a in 0..<h1 { z += p[base + a] * a1[a] }
            a2[b] = max(0, z)
        }
        var s = [Double](repeating: 0, count: k)
        var q = 0.0
        for i in 0..<d where x[i] != 0 {
            let base = oV + i * k
            for f in 0..<k {
                let v = p[base + f] * x[i]
                s[f] += v; q += v * v
            }
        }
        var fm = -q
        for f in 0..<k { fm += s[f] * s[f] }
        fm *= 0.5
        var out = [Double](repeating: fm, count: outs)
        for o in 0..<outs {
            var z = p[oB3 + o]
            for b in 0..<h2 { z += p[oW3 + o * h2 + b] * a2[b] }
            let lb = oL + o * d
            for i in 0..<d { z += p[lb + i] * x[i] }
            out[o] += z
        }
        return Cache(a1: a1, a2: a2, s: s, out: out)
    }

    func predict(_ x: [Double]) -> [Double] { forward(x).out }

    /// Adds dLoss/dParams for one example to `grad`, given dLoss/dOutput `g`.
    func backward(_ x: [Double], _ c: Cache, _ g: [Double], _ grad: inout [Double]) {
        var G = 0.0
        var dA2 = [Double](repeating: 0, count: h2)
        for o in 0..<outs where g[o] != 0 {
            G += g[o]
            grad[oB3 + o] += g[o]
            for b in 0..<h2 {
                grad[oW3 + o * h2 + b] += g[o] * c.a2[b]
                dA2[b] += g[o] * p[oW3 + o * h2 + b]
            }
            let lb = oL + o * d
            for i in 0..<d where x[i] != 0 { grad[lb + i] += g[o] * x[i] }
        }
        var dA1 = [Double](repeating: 0, count: h1)
        for b in 0..<h2 where c.a2[b] > 0 && dA2[b] != 0 {
            grad[oB2 + b] += dA2[b]
            let base = oW2 + b * h1
            for a in 0..<h1 {
                grad[base + a] += dA2[b] * c.a1[a]
                dA1[a] += dA2[b] * p[base + a]
            }
        }
        for a in 0..<h1 where c.a1[a] > 0 && dA1[a] != 0 {
            grad[oB1 + a] += dA1[a]
            let base = oW1 + a * d
            for i in 0..<d where x[i] != 0 { grad[base + i] += dA1[a] * x[i] }
        }
        if G != 0 {
            for i in 0..<d where x[i] != 0 {
                let base = oV + i * k
                for f in 0..<k { grad[base + f] += G * (x[i] * c.s[f] - p[base + f] * x[i] * x[i]) }
            }
        }
    }

    /// How strongly columns i and j act together (factorization weight).
    func pairWeight(_ i: Int, _ j: Int) -> Double {
        var w = 0.0
        for f in 0..<k { w += p[oV + i * k + f] * p[oV + j * k + f] }
        return w
    }

    func linearWeight(_ i: Int, output o: Int) -> Double { p[oL + o * d + i] }
}

// MARK: - Training and evaluation

enum PanelTrainer {
    struct Config {
        var maxEpochs = 25
        var rowsPerEpoch = 20_000
        var lr = 0.003
        var weightDecay = 1e-4
        var batch = 128
        var rankWeight = 1.0
        var regWeight = 0.5
    }

    static func isGainer(_ r: PanelRow, main: Int, threshold: Double) -> Bool { (r.fwdMax[main] ?? -1) >= threshold }

    /// Trains one net; early-stops on the validation rows' daily rank correlation.
    static func train(_ rows: [PanelRow], train: [Int], val: [Int], main: Int, threshold: Double,
                      seed: UInt64, config: Config = Config()) -> PanelNet {
        let d = rows.first?.x.count ?? 0, outs = rows.first?.fwd.count ?? 1
        var net = PanelNet(inputs: d, outputs: outs, seed: seed)
        var rng = SeededRandom(seed: seed &+ 99)
        var m = [Double](repeating: 0, count: net.p.count), v = m
        var step = 0
        var best = net.p, bestScore = -Double.infinity, patience = 0

        var byDay: [Int: [Int]] = [:]
        for i in train { byDay[rows[i].day, default: []].append(i) }
        let dayKeys = Array(byDay.keys)

        for _ in 0..<config.maxEpochs {
            // One epoch: day-by-day batches (so the ranking loss compares stocks on the same day)
            var budget = config.rowsPerEpoch
            for day in dayKeys.shuffled(using: &rng) {
                guard budget > 0 else { break }
                var idx = byDay[day]!.shuffled(using: &rng)
                if idx.count > budget { idx = Array(idx.prefix(budget)) }
                budget -= idx.count
                var s = 0
                while s < idx.count {
                    let batch = Array(idx[s..<min(s + config.batch, idx.count)])
                    s += config.batch
                    guard batch.count >= 2 else { continue }
                    var grad = [Double](repeating: 0, count: net.p.count)
                    let caches = batch.map { net.forward(rows[$0].x) }
                    var g = [[Double]](repeating: [Double](repeating: 0, count: outs), count: batch.count)
                    let n = Double(batch.count)
                    for (r, i) in batch.enumerated() {
                        for o in 0..<outs { if let y = rows[i].target[o] { g[r][o] += config.regWeight * (caches[r].out[o] - y) / n } }
                        // ranking pair on the main horizon
                        let j = Int(rng.next() % UInt64(batch.count))
                        guard j != r, let fi = rows[i].fwd[main], let fj = rows[batch[j]].fwd[main], abs(fi - fj) > 1 else { continue }
                        let sign: Double = fi > fj ? 1 : -1
                        let z = -sign * (caches[r].out[main] - caches[j].out[main])
                        let dLds = -sign / (1 + exp(-max(-30, min(30, z))))
                        let w = 1 + 2 * ((isGainer(rows[i], main: main, threshold: threshold) || isGainer(rows[batch[j]], main: main, threshold: threshold)) ? 1.0 : 0)
                        g[r][main] += config.rankWeight * w * dLds / n
                        g[j][main] -= config.rankWeight * w * dLds / n
                    }
                    for (r, i) in batch.enumerated() { net.backward(rows[i].x, caches[r], g[r], &grad) }
                    // AdamW
                    step += 1
                    let b1 = 0.9, b2 = 0.999
                    let c1 = 1 - pow(b1, Double(step)), c2 = 1 - pow(b2, Double(step))
                    for q in 0..<net.p.count {
                        m[q] = b1 * m[q] + (1 - b1) * grad[q]
                        v[q] = b2 * v[q] + (1 - b2) * grad[q] * grad[q]
                        net.p[q] -= config.lr * ((m[q] / c1) / (sqrt(v[q] / c2) + 1e-8) + config.weightDecay * net.p[q])
                    }
                }
            }
            // Early stopping
            guard !val.isEmpty else { continue }
            let score = dailyIC(scores: val.map { net.predict(rows[$0].x)[main] }, rows: val.map { rows[$0] }, main: main).mean
            if score > bestScore + 1e-4 { bestScore = score; best = net.p; patience = 0 }
            else { patience += 1; if patience >= 4 { break } }
        }
        if bestScore > -Double.infinity { net.p = best }
        return net
    }

    /// Ensemble score per row: each member's outputs z-scored, then averaged.
    static func ensembleScores(_ nets: [PanelNet], xs: [[Double]], main: Int) -> [Double] {
        guard !nets.isEmpty, !xs.isEmpty else { return [] }
        var total = [Double](repeating: 0, count: xs.count)
        for net in nets {
            let s = xs.map { net.predict($0)[main] }
            let mean = s.reduce(0, +) / Double(s.count)
            let sd = sqrt(s.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(s.count)) + 1e-9
            for i in s.indices { total[i] += (s[i] - mean) / sd }
        }
        return total.map { $0 / Double(nets.count) }
    }

    static func spearman(_ a: [Double], _ b: [Double]) -> Double {
        let n = a.count
        guard n >= 3 else { return 0 }
        let ra = PanelBuilder.ranks(a), rb = PanelBuilder.ranks(b)
        let ma = ra.reduce(0, +) / Double(n), mb = rb.reduce(0, +) / Double(n)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<n { num += (ra[i] - ma) * (rb[i] - mb); da += (ra[i] - ma) * (ra[i] - ma); db += (rb[i] - mb) * (rb[i] - mb) }
        return da > 0 && db > 0 ? num / sqrt(da * db) : 0
    }

    /// Average per-day rank correlation between score and forward gain ("IC"), and the share of days it was positive.
    static func dailyIC(scores: [Double], rows: [PanelRow], main: Int) -> (mean: Double, positive: Double, days: Int) {
        var byDay: [Int: [(Double, Double)]] = [:]
        for (s, r) in zip(scores, rows) { if let f = r.fwd[main] { byDay[r.day, default: []].append((s, f)) } }
        let ics = byDay.values.filter { $0.count >= 10 }.map { pairs in spearman(pairs.map(\.0), pairs.map(\.1)) }
        guard !ics.isEmpty else { return (0, 0, 0) }
        return (ics.reduce(0, +) / Double(ics.count), Double(ics.filter { $0 > 0 }.count) / Double(ics.count), ics.count)
    }

    struct Metrics {
        var ic = 0.0, icPositive = 0.0, testDays = 0
        var top20Lift = 0.0            // avg forward gain of the top 20 minus the day's average (% points)
        var auc: Double?               // gainers vs the rest (daily ranks pooled)
        var precision20: Double?       // share of gainers in each day's top 20
        var baseRate = 0.0
    }

    static func metrics(scores: [Double], rows: [PanelRow], main: Int, threshold: Double) -> Metrics {
        var out = Metrics()
        let ic = dailyIC(scores: scores, rows: rows, main: main)
        out.ic = ic.mean; out.icPositive = ic.positive; out.testDays = ic.days
        var byDay: [Int: [(Double, PanelRow)]] = [:]
        for (s, r) in zip(scores, rows) where r.fwd[main] != nil { byDay[r.day, default: []].append((s, r)) }
        var lifts: [Double] = [], precs: [Double] = [], pooledS: [Double] = [], pooledY: [Bool] = []
        for (_, items) in byDay where items.count >= 20 {
            let sorted = items.sorted { $0.0 > $1.0 }
            let all = items.compactMap { $0.1.fwd[main] }
            let top = sorted.prefix(20).compactMap { $0.1.fwd[main] }
            lifts.append(top.reduce(0, +) / Double(top.count) - all.reduce(0, +) / Double(all.count))
            let ys = items.map { isGainer($0.1, main: main, threshold: threshold) }
            if ys.contains(true) {
                precs.append(Double(sorted.prefix(20).filter { isGainer($0.1, main: main, threshold: threshold) }.count) / 20)
            }
            let r = PanelBuilder.ranks(items.map(\.0))
            pooledS += r; pooledY += ys
        }
        if !lifts.isEmpty { out.top20Lift = lifts.reduce(0, +) / Double(lifts.count) }
        if !precs.isEmpty { out.precision20 = precs.reduce(0, +) / Double(precs.count) }
        if pooledY.contains(true) && pooledY.contains(false) { out.auc = ModelMetrics.auc(pooledS, pooledY) }
        out.baseRate = pooledY.isEmpty ? 0 : Double(pooledY.filter { $0 }.count) / Double(pooledY.count)
        return out
    }

    /// Same rows with forward gains shuffled among the stocks of each day (destroys any real pattern).
    static func shuffledLabels(_ rows: [PanelRow], indices: [Int], seed: UInt64) -> [PanelRow] {
        var out = rows
        var rng = SeededRandom(seed: seed)
        var byDay: [Int: [Int]] = [:]
        for i in indices { byDay[rows[i].day, default: []].append(i) }
        for (_, idx) in byDay {
            let perm = idx.shuffled(using: &rng)
            for (a, b) in zip(idx, perm) {
                out[a].fwd = rows[b].fwd; out[a].fwdMax = rows[b].fwdMax; out[a].target = rows[b].target
            }
        }
        return out
    }
}

/// Stable 0…1 hash of a symbol (for holding out whole stocks).
func symbolBucket(_ s: String) -> Double {
    var h: UInt64 = 1469598103934665603
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return Double(h % 10_000) / 10_000
}
