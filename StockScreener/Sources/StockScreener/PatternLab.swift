import Foundation

// MARK: - Dataset

/// One stock in the training set: its filter-column values and whether it became a monthly top gainer.
struct LabeledStock {
    let symbol: String
    let features: [Double?]     // one value per feature column (nil = blank)
    let gain: Double            // % change over the month
    let isGainer: Bool
}

// MARK: - Combination mining ("which filter values do monthly gainers share?")

/// One condition on a feature column, e.g. "MS > 95.3" or "Long_Green = 1".
struct PatternItem: Hashable {
    let feature: Int
    let op: RuleOperator           // .equals, .greaterThan, .lessOrEqual, .between
    let value: Double
    let value2: Double

    func test(_ x: Double?) -> Bool {
        guard let x else { return false }
        switch op {
        case .equals: return abs(x - value) < 1e-9
        case .greaterThan: return x > value
        case .lessOrEqual: return x <= value
        case .between: return x > value && x <= value2
        default: return false
        }
    }

    func describe(_ names: [String]) -> String {
        let n = names[feature]
        func f(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }
        switch op {
        case .equals: return "\(n) = \(f(value))"
        case .greaterThan: return "\(n) > \(f(value))"
        case .lessOrEqual: return "\(n) ≤ \(f(value))"
        case .between: return "\(n) \(f(value))–\(f(value2))"
        default: return n
        }
    }

    /// The same condition as a Filter-screen condition.
    func filterConditions(_ names: [String]) -> [FilterCondition] {
        let n = names[feature]
        func s(_ v: Double) -> String { String(v) }
        switch op {
        case .equals: return [FilterCondition(column: n, op: .equals, value: s(value))]
        case .greaterThan: return [FilterCondition(column: n, op: .greaterThan, value: s(value))]
        case .lessOrEqual: return [FilterCondition(column: n, op: .lessOrEqual, value: s(value))]
        case .between: return [FilterCondition(column: n, op: .greaterThan, value: s(value)),
                               FilterCondition(column: n, op: .lessOrEqual, value: s(value2))]
        default: return []
        }
    }
}

struct PatternCombo: Identifiable {
    let id = UUID()
    let items: [PatternItem]
    let gainersWith: Int
    let totalWith: Int
    let hitRate: Double        // share of stocks with this combination that became gainers
    let lift: Double           // hitRate / base rate
    let examples: [String]     // gainers that had it
}

enum PatternMiner {

    /// Turns each feature into simple conditions: 0/1 flags become "= 0" / "= 1"; other numbers
    /// become Low / Mid / High by thirds of the data.
    static func items(for data: [LabeledStock], featureCount: Int) -> [PatternItem] {
        var out: [PatternItem] = []
        for f in 0..<featureCount {
            let values = data.compactMap { $0.features[f] }.sorted()
            guard values.count >= 10 else { continue }
            let distinct = Set(values)
            if distinct.isSubset(of: [0, 1]) {
                out.append(PatternItem(feature: f, op: .equals, value: 1, value2: 0))
                out.append(PatternItem(feature: f, op: .equals, value: 0, value2: 0))
            } else if distinct.count <= 6 {
                for v in distinct.sorted() { out.append(PatternItem(feature: f, op: .equals, value: v, value2: 0)) }
            } else {
                let q1 = values[values.count / 3], q2 = values[(values.count * 2) / 3]
                guard q1 < q2 else { continue }
                out.append(PatternItem(feature: f, op: .lessOrEqual, value: q1, value2: 0))
                out.append(PatternItem(feature: f, op: .between, value: q1, value2: q2))
                out.append(PatternItem(feature: f, op: .greaterThan, value: q2, value2: 0))
            }
        }
        return out
    }

    /// Finds combinations of 1–3 conditions that gainers share more often than other stocks.
    static func mine(_ data: [LabeledStock], featureCount: Int, names: [String],
                     minGainers: Int = 3, maxSize: Int = 3, limit: Int = 300) -> [PatternCombo] {
        let n = data.count
        let gainers = data.filter(\.isGainer).count
        guard n > 0, gainers > 0 else { return [] }
        let base = Double(gainers) / Double(n)
        let words = (n + 63) / 64

        // Bitsets: which stocks satisfy each item; which stocks are gainers.
        let allItems = items(for: data, featureCount: featureCount)
        var gainerBits = [UInt64](repeating: 0, count: words)
        for (i, s) in data.enumerated() where s.isGainer { gainerBits[i >> 6] |= 1 << UInt64(i & 63) }
        func popcount(_ a: [UInt64]) -> Int { a.reduce(0) { $0 + $1.nonzeroBitCount } }
        func and(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] { zip(a, b).map { $0 & $1 } }

        var itemBits: [[UInt64]] = []
        var items: [PatternItem] = []
        for item in allItems {
            var bits = [UInt64](repeating: 0, count: words)
            for (i, s) in data.enumerated() where item.test(s.features[item.feature]) {
                bits[i >> 6] |= 1 << UInt64(i & 63)
            }
            if popcount(and(bits, gainerBits)) >= minGainers {   // only items some gainers have
                items.append(item); itemBits.append(bits)
            }
        }

        var results: [PatternCombo] = []
        func consider(_ idx: [Int], _ bits: [UInt64]) {
            let total = popcount(bits)
            let g = popcount(and(bits, gainerBits))
            guard g >= minGainers, total > 0 else { return }
            let hit = Double(g) / Double(total)
            let lift = hit / base
            guard lift > 1.05 else { return }
            var examples: [String] = []
            for (i, s) in data.enumerated() where s.isGainer && (bits[i >> 6] >> UInt64(i & 63)) & 1 == 1 {
                examples.append(s.symbol)
                if examples.count == 12 { break }
            }
            results.append(PatternCombo(items: idx.map { items[$0] }, gainersWith: g, totalWith: total,
                                        hitRate: hit, lift: lift, examples: examples))
        }

        // Size 1, 2, 3 (no two conditions on the same column).
        for a in items.indices {
            consider([a], itemBits[a])
            guard maxSize >= 2 else { continue }
            for b in (a + 1)..<items.count where items[b].feature != items[a].feature {
                let ab = and(itemBits[a], itemBits[b])
                guard popcount(and(ab, gainerBits)) >= minGainers else { continue }
                consider([a, b], ab)
                guard maxSize >= 3 else { continue }
                for c in (b + 1)..<items.count
                where items[c].feature != items[a].feature && items[c].feature != items[b].feature {
                    let abc = and(ab, itemBits[c])
                    consider([a, b, c], abc)
                }
            }
        }

        // Most useful first: strong lift with enough gainers behind it.
        return Array(results.sorted {
            let sa = $0.lift * log(Double($0.gainersWith) + 1), sb = $1.lift * log(Double($1.gainersWith) + 1)
            return sa > sb
        }.prefix(limit))
    }
}

// MARK: - Small neural net (multilayer perceptron)

/// inputs → 16 ReLU → 8 ReLU → 1 sigmoid, trained with Adam on class-weighted cross-entropy.
struct TinyNet {
    var w1: [[Double]], b1: [Double]
    var w2: [[Double]], b2: [Double]
    var w3: [Double], b3: Double
    var mean: [Double], std: [Double]

    init(inputs: Int, hidden1: Int = 16, hidden2: Int = 8, seed: UInt64 = 7) {
        var rng = SeededRandom(seed: seed)
        func layer(_ n: Int, _ m: Int) -> [[Double]] {
            let scale = sqrt(2.0 / Double(m))
            return (0..<n).map { _ in (0..<m).map { _ in rng.normal() * scale } }
        }
        w1 = layer(hidden1, inputs); b1 = Array(repeating: 0, count: hidden1)
        w2 = layer(hidden2, hidden1); b2 = Array(repeating: 0, count: hidden2)
        w3 = (0..<hidden2).map { _ in rng.normal() * sqrt(1.0 / Double(hidden2)) }; b3 = 0
        mean = Array(repeating: 0, count: inputs); std = Array(repeating: 1, count: inputs)
    }

    /// Standardizes inputs; blanks become the average (0 after standardizing).
    func prepare(_ x: [Double?]) -> [Double] {
        x.enumerated().map { i, v in v.map { ($0 - mean[i]) / std[i] } ?? 0 }
    }

    func predict(_ raw: [Double?]) -> Double { forward(prepare(raw)).out }

    private func forward(_ x: [Double]) -> (h1: [Double], h2: [Double], out: Double) {
        let h1 = zip(w1, b1).map { w, b in max(0, zip(w, x).reduce(b) { $0 + $1.0 * $1.1 }) }
        let h2 = zip(w2, b2).map { w, b in max(0, zip(w, h1).reduce(b) { $0 + $1.0 * $1.1 }) }
        let z = zip(w3, h2).reduce(b3) { $0 + $1.0 * $1.1 }
        return (h1, h2, 1 / (1 + exp(-max(-30, min(30, z)))))
    }

    /// Trains on (features, label). Positive examples are weighted up so rare gainers count.
    mutating func train(_ xs: [[Double?]], _ ys: [Bool], epochs: Int = 250, lr: Double = 0.01) {
        let n = xs.count, d = mean.count
        guard n > 0 else { return }
        // Standardization from the training data
        for j in 0..<d {
            let vals = xs.compactMap { $0[j] }
            let m = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            let v = vals.isEmpty ? 1 : vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count)
            mean[j] = m; std[j] = v > 1e-12 ? sqrt(v) : 1
        }
        let X = xs.map(prepare)
        let pos = Double(ys.filter { $0 }.count), neg = Double(n) - pos
        let posWeight = pos > 0 ? max(1, neg / pos) : 1

        var adam = Adam(net: self, lr: lr)
        var order = Array(0..<n)
        var rng = SeededRandom(seed: 11)
        let batch = 64
        for _ in 0..<epochs {
            order.shuffle(using: &rng)
            var start = 0
            while start < n {
                let idx = order[start..<min(start + batch, n)]
                start += batch
                var g = Gradients(like: self)
                for i in idx {
                    let x = X[i]
                    let (h1, h2, out) = forward(x)
                    let weight = ys[i] ? posWeight : 1
                    let dz3 = (out - (ys[i] ? 1 : 0)) * weight
                    for k in 0..<w3.count { g.w3[k] += dz3 * h2[k] }
                    g.b3 += dz3
                    var dz2 = [Double](repeating: 0, count: w2.count)
                    for k in 0..<w2.count where h2[k] > 0 { dz2[k] = dz3 * w3[k] }
                    for k in 0..<w2.count where dz2[k] != 0 {
                        for j in 0..<h1.count { g.w2[k][j] += dz2[k] * h1[j] }
                        g.b2[k] += dz2[k]
                    }
                    var dz1 = [Double](repeating: 0, count: w1.count)
                    for j in 0..<w1.count where h1[j] > 0 {
                        var s = 0.0
                        for k in 0..<w2.count { s += dz2[k] * w2[k][j] }
                        dz1[j] = s
                    }
                    for j in 0..<w1.count where dz1[j] != 0 {
                        for i2 in 0..<d { g.w1[j][i2] += dz1[j] * x[i2] }
                        g.b1[j] += dz1[j]
                    }
                }
                g.scale(1 / Double(idx.count))
                adam.step(&self, g)
            }
        }
    }
}

struct Gradients {
    var w1: [[Double]], b1: [Double], w2: [[Double]], b2: [Double], w3: [Double], b3: Double
    init(like n: TinyNet) {
        w1 = n.w1.map { $0.map { _ in 0 } }; b1 = n.b1.map { _ in 0 }
        w2 = n.w2.map { $0.map { _ in 0 } }; b2 = n.b2.map { _ in 0 }
        w3 = n.w3.map { _ in 0 }; b3 = 0
    }
    mutating func scale(_ s: Double) {
        w1 = w1.map { $0.map { $0 * s } }; b1 = b1.map { $0 * s }
        w2 = w2.map { $0.map { $0 * s } }; b2 = b2.map { $0 * s }
        w3 = w3.map { $0 * s }; b3 *= s
    }
    var flat: [Double] { w1.flatMap { $0 } + b1 + w2.flatMap { $0 } + b2 + w3 + [b3] }
}

/// Adam optimizer over the flattened weights.
struct Adam {
    var m: [Double], v: [Double], t = 0
    let lr: Double, beta1 = 0.9, beta2 = 0.999, eps = 1e-8, l2 = 1e-4

    init(net: TinyNet, lr: Double) {
        let count = Gradients(like: net).flat.count
        m = Array(repeating: 0, count: count); v = Array(repeating: 0, count: count); self.lr = lr
    }

    mutating func step(_ net: inout TinyNet, _ g: Gradients) {
        t += 1
        var params = net.w1.flatMap { $0 } + net.b1 + net.w2.flatMap { $0 } + net.b2 + net.w3 + [net.b3]
        let grads = g.flat
        let c1 = 1 - pow(beta1, Double(t)), c2 = 1 - pow(beta2, Double(t))
        for i in params.indices {
            let gi = grads[i] + l2 * params[i]
            m[i] = beta1 * m[i] + (1 - beta1) * gi
            v[i] = beta2 * v[i] + (1 - beta2) * gi * gi
            params[i] -= lr * (m[i] / c1) / (sqrt(v[i] / c2) + eps)
        }
        // Unflatten
        var k = 0
        func take(_ n: Int) -> [Double] { defer { k += n }; return Array(params[k..<(k + n)]) }
        for r in net.w1.indices { net.w1[r] = take(net.w1[r].count) }
        net.b1 = take(net.b1.count)
        for r in net.w2.indices { net.w2[r] = take(net.w2[r].count) }
        net.b2 = take(net.b2.count)
        net.w3 = take(net.w3.count)
        net.b3 = take(1)[0]
    }
}

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func normal() -> Double {
        let u1 = max(Double(next() % 1_000_000) / 1_000_000, 1e-9), u2 = Double(next() % 1_000_000) / 1_000_000
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

// MARK: - Evaluation

enum ModelMetrics {
    /// Area under the ROC curve: 0.5 = no better than chance, 1.0 = perfect ranking.
    static func auc(_ scores: [Double], _ labels: [Bool]) -> Double {
        let pairs = zip(scores, labels).sorted { $0.0 < $1.0 }
        let pos = labels.filter { $0 }.count, neg = labels.count - pos
        guard pos > 0, neg > 0 else { return 0.5 }
        var rankSum = 0.0
        var i = 0
        while i < pairs.count {                      // average ranks for ties
            var j = i
            while j + 1 < pairs.count && pairs[j + 1].0 == pairs[i].0 { j += 1 }
            let avgRank = Double(i + j + 2) / 2
            for k in i...j where pairs[k].1 { rankSum += avgRank }
            i = j + 1
        }
        return (rankSum - Double(pos * (pos + 1)) / 2) / Double(pos * neg)
    }

    /// Share of gainers among the top-k scored stocks.
    static func precisionAtK(_ scores: [Double], _ labels: [Bool], k: Int) -> Double {
        let top = zip(scores, labels).sorted { $0.0 > $1.0 }.prefix(k)
        guard !top.isEmpty else { return 0 }
        return Double(top.filter { $0.1 }.count) / Double(top.count)
    }
}
