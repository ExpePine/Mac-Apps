import Foundation

// MARK: - Stored runs

/// One saved run of a study: the settings used and every stock's result.
struct PerfRun: Codable, Identifiable {
    var id = UUID()
    var study: PerfStudy
    var runAt = Date()
    var refDay: String
    var rows: [PerfRow]
    var skipped: Int

    var title: String { study.name.isEmpty ? study.column : study.name }
}

enum PerfRunStore {
    static var folder: URL { AppFolders.folder("Performance Runs") }
    static let keep = 40

    static func save(_ run: PerfRun) {
        var r = run
        // keep files small: paths up to 150 trading days
        r.rows = r.rows.map { row in
            guard row.path.count > 151 else { return row }
            return PerfRow(symbol: row.symbol, value: row.value, eventDay: row.eventDay, tradingDaysSince: row.tradingDaysSince,
                           entry: row.entry, now: row.now, returnNow: row.returnNow, peak: row.peak, daysToPeak: row.daysToPeak,
                           worst: row.worst, hitDays: row.hitDays, horizons: row.horizons, benchmark: row.benchmark,
                           group: row.group, path: Array(row.path.prefix(151)), preMove: row.preMove, marketPre: row.marketPre)
        }
        guard let json = try? JSONEncoder().encode(r),
              let data = try? (json as NSData).compressed(using: .lzfse) as Data else { return }
        try? data.write(to: folder.appendingPathComponent("\(run.id.uuidString).json.lzfse"), options: .atomic)
        prune()
    }

    static func loadAll() -> [PerfRun] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".json.lzfse") }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let raw = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
            return try? JSONDecoder().decode(PerfRun.self, from: raw)
        }.sorted { $0.runAt > $1.runAt }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).json.lzfse"))
    }

    private static func prune() {
        let runs = loadAll()
        guard runs.count > keep else { return }
        for r in runs.dropFirst(keep) { delete(r.id) }
    }
}

// MARK: - Comparing indicators

struct IndicatorStats: Identifiable {
    var id: UUID { runID }
    let runID: UUID
    let name: String
    let n: Int                       // stocks with at least H trading days since the event
    let mean: Double
    let median: Double
    let ciLow: Double                // bootstrap 95% interval of the mean
    let ciHigh: Double
    let winRate: Double
    let expectancy: Double           // avg win × win% − avg loss × loss%
    let profitFactor: Double?        // Σ gains / Σ |losses|
    let std: Double
    let sortino: Double?             // mean / downside deviation
    let avgMaxUp: Double             // best close within H
    let avgBestDay: Double           // average trading days from the event to that best close
    let medianBestDay: Double
    let avgMaxDown: Double           // worst close within H (negative)
    let cvar5: Double                // average of the worst 5% of returns
    let hitWithinH: Double           // reached the target within H days
    let targetFirst: Double          // touched +target before −stop (within H)
    let stopFirst: Double
    let kmMedianDays: Int?           // median trading days to reach the target (survival estimate, all stocks)
    let kmCurve: [(day: Int, reached: Double)]
    let avgPath: [(day: Int, mean: Double)]
    let percentiles: (p10: Double, p25: Double, p50: Double, p75: Double, p90: Double)
    let excess: Double?              // mean vs Nifty 50 over the same H days (approx: uses full-period benchmark scaled)
}

struct HeadToHead: Identifiable {
    var id: String { a + "|" + b }
    let a: String, b: String
    let diff: Double                 // mean A − mean B (independent samples)
    let ciLow: Double, ciHigh: Double
    let probABetter: Double          // bootstrap share where mean A > mean B
    let overlap: Int                 // stocks flagged by both
    let bothMean: Double?, onlyAMean: Double?, onlyBMean: Double?
}

struct PatternLine: Identifiable {
    let id = UUID()
    let label: String
    let values: [UUID: (n: Int, mean: Double)]   // per indicator
    let pooled: (n: Int, mean: Double)
}

struct Insight: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let solid: Bool                  // backed by enough data / intervals that don't overlap
}

struct ComparisonResult {
    var horizon = 21
    var stats: [IndicatorStats] = []
    var pairs: [HeadToHead] = []
    var confluence: [(count: Int, n: Int, mean: Double, hit: Double)] = []
    var regime: [PatternLine] = []
    var momentum: [PatternLine] = []
    var insights: [Insight] = []
    var best: (profit: UUID?, fast: UUID?, safe: UUID?, riskAdjusted: UUID?) = (nil, nil, nil, nil)
}

enum PerfCompare {

    /// Return at H, best and worst close within H, and which of +target / −stop came first.
    struct Sample {
        let symbol: String
        let ret: Double
        let maxUp: Double
        let maxDown: Double
        let hit: Bool
        let first: Int               // 1 = target first, -1 = stop first, 0 = neither
        let preMove: Double?
        let marketPre: Double?
        let excess: Double?
        var bestDay = 0              // trading days after the event of the best close within H
    }

    static func samples(_ run: PerfRun, horizon h: Int, target: Double, stop: Double) -> [Sample] {
        run.rows.compactMap { r in
            guard r.path.count > h else { return nil }
            let w = r.path[1...h]
            var first = 0
            for v in w {
                if v >= target - 1e-9 { first = 1; break }
                if v <= -stop + 1e-9 { first = -1; break }
            }
            // Nifty over the stock's full period, scaled to H days (approximate; exact needs prices per day)
            let ex: Double? = r.benchmark.flatMap { b in
                r.tradingDaysSince > 0 ? r.path[h] - b * Double(h) / Double(r.tradingDaysSince) : nil
            }
            return Sample(symbol: r.symbol, ret: r.path[h], maxUp: w.max() ?? 0, maxDown: min(0, w.min() ?? 0),
                          hit: (w.max() ?? 0) >= target - 1e-9, first: first,
                          preMove: r.preMove, marketPre: r.marketPre, excess: ex,
                          bestDay: (1...h).max { r.path[$0] < r.path[$1] } ?? 0)
        }
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let x = p * Double(sorted.count - 1)
        let lo = Int(x.rounded(.down)), hi = min(sorted.count - 1, lo + 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (x - Double(lo))
    }

    /// Kaplan–Meier: share of stocks that reached +target by each day; stocks with too little history count until they drop out.
    static func kaplanMeier(_ run: PerfRun, target: Double, maxDay: Int = 150) -> [(day: Int, reached: Double)] {
        var events: [Int: Int] = [:], censored: [Int: Int] = [:]
        for r in run.rows {
            let last = min(r.path.count - 1, r.tradingDaysSince, maxDay)
            guard last >= 1 else { continue }
            if let t = (1...last).first(where: { r.path[$0] >= target - 1e-9 }) { events[t, default: 0] += 1 }
            else { censored[last, default: 0] += 1 }
        }
        var atRisk = events.values.reduce(0, +) + censored.values.reduce(0, +)
        guard atRisk > 0 else { return [] }
        var survival = 1.0
        var out: [(Int, Double)] = []
        for day in 1...maxDay {
            let d = events[day] ?? 0
            if atRisk > 0 && d > 0 { survival *= 1 - Double(d) / Double(atRisk) }
            out.append((day, 1 - survival))
            atRisk -= d + (censored[day] ?? 0)
            if atRisk <= 0 { break }
        }
        return out
    }

    static func bootstrapMeans(_ v: [Double], rounds: Int, rng: inout SeededRandom) -> [Double] {
        guard !v.isEmpty else { return [] }
        return (0..<rounds).map { _ in
            var s = 0.0
            for _ in 0..<v.count { s += v[Int(rng.next() % UInt64(v.count))] }
            return s / Double(v.count)
        }
    }

    static func compare(_ runs: [PerfRun], horizon h: Int, target: Double, stop: Double, rounds: Int = 1000) -> ComparisonResult {
        var result = ComparisonResult()
        result.horizon = h
        var rng = SeededRandom(seed: 2026)
        var samplesBy: [UUID: [Sample]] = [:]
        var boots: [UUID: [Double]] = [:]

        for run in runs {
            let s = samples(run, horizon: h, target: target, stop: stop)
            samplesBy[run.id] = s
            let rets = s.map(\.ret)
            let sorted = rets.sorted()
            let n = rets.count
            let mean = n > 0 ? rets.reduce(0, +) / Double(n) : 0
            let b = bootstrapMeans(rets, rounds: rounds, rng: &rng).sorted()
            boots[run.id] = b
            let wins = rets.filter { $0 > 0 }, losses = rets.filter { $0 <= 0 }
            let winRate = n > 0 ? Double(wins.count) / Double(n) : 0
            let avgWin = wins.isEmpty ? 0 : wins.reduce(0, +) / Double(wins.count)
            let avgLoss = losses.isEmpty ? 0 : abs(losses.reduce(0, +) / Double(losses.count))
            let sumLoss = abs(losses.reduce(0, +))
            let variance = n > 1 ? rets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1) : 0
            let downside = n > 0 ? sqrt(rets.reduce(0) { $0 + min(0, $1) * min(0, $1) } / Double(n)) : 0
            let worstK = max(1, n / 20)
            let km = kaplanMeier(run, target: target)
            let paths = run.rows.filter { $0.path.count > h }
            let avgPath: [(Int, Double)] = (0...h).map { k in
                (k, paths.isEmpty ? 0 : paths.reduce(0) { $0 + $1.path[k] } / Double(paths.count))
            }
            let ex = s.compactMap(\.excess)
            result.stats.append(IndicatorStats(
                runID: run.id, name: run.title, n: n, mean: mean, median: percentile(sorted, 0.5),
                ciLow: percentile(b, 0.025), ciHigh: percentile(b, 0.975), winRate: winRate,
                expectancy: avgWin * winRate - avgLoss * (1 - winRate),
                profitFactor: sumLoss > 0 ? wins.reduce(0, +) / sumLoss : nil,
                std: sqrt(variance), sortino: downside > 0 ? mean / downside : nil,
                avgMaxUp: n > 0 ? s.map(\.maxUp).reduce(0, +) / Double(n) : 0,
                avgBestDay: n > 0 ? Double(s.map(\.bestDay).reduce(0, +)) / Double(n) : 0,
                medianBestDay: percentile(s.map { Double($0.bestDay) }.sorted(), 0.5),
                avgMaxDown: n > 0 ? s.map(\.maxDown).reduce(0, +) / Double(n) : 0,
                cvar5: n > 0 ? sorted.prefix(worstK).reduce(0, +) / Double(worstK) : 0,
                hitWithinH: n > 0 ? Double(s.filter(\.hit).count) / Double(n) : 0,
                targetFirst: n > 0 ? Double(s.filter { $0.first == 1 }.count) / Double(n) : 0,
                stopFirst: n > 0 ? Double(s.filter { $0.first == -1 }.count) / Double(n) : 0,
                kmMedianDays: km.first(where: { $0.reached >= 0.5 })?.day,
                kmCurve: km, avgPath: avgPath,
                percentiles: (percentile(sorted, 0.1), percentile(sorted, 0.25), percentile(sorted, 0.5),
                              percentile(sorted, 0.75), percentile(sorted, 0.9)),
                excess: ex.isEmpty ? nil : ex.reduce(0, +) / Double(ex.count)))
        }

        let valid = result.stats.filter { $0.n >= 5 }
        result.best.profit = valid.max { $0.median < $1.median }?.runID
        result.best.fast = valid.sorted { a, b in
            let da = a.kmMedianDays ?? Int.max, db = b.kmMedianDays ?? Int.max
            return da != db ? da < db : a.hitWithinH > b.hitWithinH
        }.first?.runID
        result.best.safe = valid.max { $0.avgMaxDown < $1.avgMaxDown }?.runID            // least negative
        result.best.riskAdjusted = valid.max { ($0.sortino ?? -.infinity) < ($1.sortino ?? -.infinity) }?.runID

        // Head to head
        for i in 0..<runs.count {
            for j in (i + 1)..<max(i + 1, runs.count) {
                let A = runs[i], B = runs[j]
                guard let ba = boots[A.id], let bb = boots[B.id], !ba.isEmpty, !bb.isEmpty,
                      let sa = samplesBy[A.id], let sb = samplesBy[B.id] else { continue }
                // re-pair bootstraps in their original order (both were drawn independently)
                var rng2 = SeededRandom(seed: UInt64(77 + i * 31 + j))
                let ra = bootstrapMeans(sa.map(\.ret), rounds: rounds, rng: &rng2)
                let rb = bootstrapMeans(sb.map(\.ret), rounds: rounds, rng: &rng2)
                let diffs = zip(ra, rb).map { $0 - $1 }.sorted()
                let ma = sa.map(\.ret).reduce(0, +) / Double(sa.count), mb = sb.map(\.ret).reduce(0, +) / Double(sb.count)
                let setA = Dictionary(sa.map { ($0.symbol, $0.ret) }, uniquingKeysWith: { a, _ in a })
                let setB = Dictionary(sb.map { ($0.symbol, $0.ret) }, uniquingKeysWith: { a, _ in a })
                let both = Set(setA.keys).intersection(setB.keys)
                func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
                result.pairs.append(HeadToHead(
                    a: A.title, b: B.title, diff: ma - mb,
                    ciLow: percentile(diffs, 0.025), ciHigh: percentile(diffs, 0.975),
                    probABetter: Double(diffs.filter { $0 > 0 }.count) / Double(max(1, diffs.count)),
                    overlap: both.count,
                    bothMean: avg(both.map { ((setA[$0] ?? 0) + (setB[$0] ?? 0)) / 2 }),
                    onlyAMean: avg(setA.filter { !both.contains($0.key) }.map(\.value)),
                    onlyBMean: avg(setB.filter { !both.contains($0.key) }.map(\.value))))
            }
        }

        // Confluence: how many of the chosen indicators flagged a stock → how it did
        var perSymbol: [String: [Sample]] = [:]
        for (_, s) in samplesBy { for x in s { perSymbol[x.symbol, default: []].append(x) } }
        var buckets: [Int: [(ret: Double, hit: Bool)]] = [:]
        for (_, xs) in perSymbol {
            let mean = xs.map(\.ret).reduce(0, +) / Double(xs.count)
            buckets[min(xs.count, 4), default: []].append((mean, xs.contains(where: \.hit)))
        }
        result.confluence = buckets.keys.sorted().map { k in
            let v = buckets[k]!
            return (k, v.count, v.map(\.ret).reduce(0, +) / Double(v.count), Double(v.filter(\.hit).count) / Double(v.count))
        }

        // Hidden patterns: market before the event, and the stock's own move before the event
        func line(_ label: String, _ keep: (Sample) -> Bool) -> PatternLine {
            var values: [UUID: (Int, Double)] = [:]
            var all: [Double] = []
            for run in runs {
                let v = (samplesBy[run.id] ?? []).filter(keep).map(\.ret)
                all += v
                values[run.id] = (v.count, v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count))
            }
            return PatternLine(label: label, values: values, pooled: (all.count, all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)))
        }
        result.regime = [
            line("Nifty rising before (> +2% in 21d)") { ($0.marketPre ?? 0) > 2 },
            line("Nifty flat before (−2% … +2%)") { $0.marketPre.map { abs($0) <= 2 } ?? false },
            line("Nifty falling before (< −2%)") { ($0.marketPre ?? 0) < -2 },
        ]
        let pre = samplesBy.values.flatMap { $0 }.compactMap(\.preMove).sorted()
        if pre.count >= 9 {
            let a = percentile(pre, 1.0 / 3), b = percentile(pre, 2.0 / 3)
            func f(_ x: Double) -> String { String(format: "%+.0f%%", x) }
            result.momentum = [
                line("Weak before (≤ \(f(a)) in 21d)") { ($0.preMove ?? .infinity) <= a },
                line("Middle (\(f(a)) … \(f(b)))") { $0.preMove.map { $0 > a && $0 <= b } ?? false },
                line("Strong before (> \(f(b)))") { ($0.preMove ?? -.infinity) > b },
            ]
        }

        result.insights = insights(result, runs: runs, target: target, stop: stop)
        return result
    }

    static func insights(_ r: ComparisonResult, runs: [PerfRun], target: Double, stop: Double) -> [Insight] {
        var out: [Insight] = []
        let byID = Dictionary(r.stats.map { ($0.runID, $0) }, uniquingKeysWith: { a, _ in a })
        func pct(_ x: Double) -> String { String(format: "%+.1f%%", x) }
        let h = r.horizon

        if let id = r.best.profit, let s = byID[id] {
            let others = r.stats.filter { $0.runID != id && $0.n >= 5 }
            let solid = others.allSatisfy { s.ciLow > $0.ciHigh }
            out.append(Insight(icon: "trophy.fill",
                               text: "\(s.name) has the best median return after \(h) days (\(pct(s.median)), mean \(pct(s.mean)), n=\(s.n))." +
                                     (solid ? " Its 95% range doesn't overlap the others — a clear lead." : " Ranges overlap with others, so the lead may be luck."),
                               solid: solid))
        }
        if let id = r.best.fast, let s = byID[id] {
            out.append(Insight(icon: "hare.fill",
                               text: s.kmMedianDays.map { "\(s.name) reaches +\(Int(target))% fastest: half its stocks get there in about \($0) trading days." }
                                   ?? "\(s.name) reaches +\(Int(target))% most often within \(h) days (\(Int(s.hitWithinH * 100))%).",
                               solid: s.n >= 20))
        }
        if let id = r.best.safe, let s = byID[id] {
            out.append(Insight(icon: "shield.lefthalf.filled",
                               text: "\(s.name) has the shallowest dips: average worst close \(pct(s.avgMaxDown)) within \(h) days; worst 5% average \(pct(s.cvar5)).",
                               solid: s.n >= 20))
        }
        for s in r.stats where s.n >= 10 && s.stopFirst > s.targetFirst {
            out.append(Insight(icon: "exclamationmark.triangle.fill",
                               text: "\(s.name): −\(Int(stop))% is hit before +\(Int(target))% more often (\(Int(s.stopFirst * 100))% vs \(Int(s.targetFirst * 100))%). A tight stop would cut many trades early.",
                               solid: s.n >= 30))
        }
        for p in r.pairs where p.overlap >= 5 {
            if let both = p.bothMean, let a = p.onlyAMean, let b = p.onlyBMean, both > max(a, b) + 2 {
                out.append(Insight(icon: "link",
                                   text: "Stocks flagged by both \(p.a) and \(p.b) (\(p.overlap)) did \(pct(both)) vs \(pct(a)) / \(pct(b)) for only one — the two together look stronger.",
                                   solid: p.overlap >= 15))
            }
        }
        if let top = r.confluence.last, let one = r.confluence.first, top.count > 1, top.n >= 5, top.mean > one.mean + 2 {
            out.append(Insight(icon: "square.stack.3d.up.fill",
                               text: "Stocks flagged by \(top.count)\(top.count >= 4 ? "+" : "") indicators averaged \(pct(top.mean)) vs \(pct(one.mean)) for one indicator (n=\(top.n)).",
                               solid: top.n >= 15))
        }
        if r.regime.count == 3 {
            let up = r.regime[0].pooled, down = r.regime[2].pooled
            if up.n >= 10 && down.n >= 10 && abs(up.mean - down.mean) > 3 {
                out.append(Insight(icon: "chart.xyaxis.line",
                                   text: up.mean > down.mean
                                       ? "Signals work better when the Nifty was rising beforehand (\(pct(up.mean)) vs \(pct(down.mean)) after falling markets)."
                                       : "Signals did better after the Nifty had been falling (\(pct(down.mean)) vs \(pct(up.mean)) after rising markets) — possibly rebounds.",
                                   solid: up.n >= 30 && down.n >= 30))
            }
        }
        if r.momentum.count == 3 {
            let weak = r.momentum[0].pooled, strong = r.momentum[2].pooled
            if weak.n >= 10 && strong.n >= 10 && abs(strong.mean - weak.mean) > 3 {
                out.append(Insight(icon: "bolt.fill",
                                   text: strong.mean > weak.mean
                                       ? "Momentum carries on: stocks already strong before the signal did \(pct(strong.mean)) vs \(pct(weak.mean)) for weak ones."
                                       : "Mean reversion: stocks weak before the signal did better (\(pct(weak.mean)) vs \(pct(strong.mean)) for strong ones).",
                                   solid: weak.n >= 30 && strong.n >= 30))
            }
        }
        if r.stats.contains(where: { $0.n < 20 }) {
            out.append(Insight(icon: "info.circle",
                               text: "Some indicators have fewer than 20 stocks with \(h)+ trading days of history; their numbers can swing a lot. Try a shorter horizon or wait for more data.",
                               solid: false))
        }
        return out
    }
}
