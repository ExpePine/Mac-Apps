import Foundation

// MARK: - Strategy finder
//
// For every indicator (and all of them pooled), tries entry filters × exit rules on each stock's stored
// price path after the event. To avoid fooling ourselves, each strategy is chosen on the OLDER half of
// events and then checked on the NEWER half ("held up" = still profitable there).

struct ExitRule: Hashable {
    let target: Double?      // take profit at +X% (close)
    let stop: Double?        // stop loss at −X% (close)
    let trail: Double?       // exit if X% below the best close so far
    let hold: Int            // otherwise sell after this many trading days

    var text: String {
        var parts: [String] = []
        if let t = target { parts.append("take +\(Int(t))%") }
        if let s = stop { parts.append("stop −\(Int(s))%") }
        if let tr = trail { parts.append("trail \(Int(tr))%") }
        parts.append("max \(hold)d")
        return parts.joined(separator: " · ")
    }

    /// (return %, days held) for one path; nil if the path is too short to judge.
    func simulate(_ p: [Double]) -> (Double, Int)? {
        guard p.count > hold else { return nil }
        var peak = 0.0
        for k in 1...hold {
            let v = p[k]
            if let t = target, v >= t - 1e-9 { return (v, k) }
            if let s = stop, v <= -s + 1e-9 { return (v, k) }
            peak = max(peak, v)
            if let tr = trail, (1 + v / 100) / (1 + peak / 100) - 1 <= -tr / 100 + 1e-12 { return (v, k) }
        }
        return (p[hold], hold)
    }

    static let grid: [ExitRule] = {
        var out: [ExitRule] = []
        for t in [nil, 10.0, 20, 30, 50] as [Double?] {
            for s in [nil, 7.0, 10, 15] as [Double?] {
                for tr in [nil, 15.0] as [Double?] {
                    for h in [10, 21, 50, 100] { out.append(ExitRule(target: t, stop: s, trail: tr, hold: h)) }
                }
            }
        }
        return out
    }()
}

enum EntryFilter: String, CaseIterable {
    case all = "Every signal"
    case marketUp = "Only if Nifty rose in the 21 days before"
    case marketNotDown = "Skip if Nifty fell > 2% before"
    case weakBefore = "Only if the stock fell in the 21 days before"
    case strongBefore = "Only if the stock rose in the 21 days before"
    case confluence = "Only if ≥ 2 indicators flagged it"

    func keep(_ r: PerfRow, flaggedBy: Int) -> Bool {
        switch self {
        case .all: return true
        case .marketUp: return (r.marketPre ?? -1) > 0
        case .marketNotDown: return (r.marketPre ?? 0) >= -2
        case .weakBefore: return (r.preMove ?? 1) < 0
        case .strongBefore: return (r.preMove ?? -1) > 0
        case .confluence: return flaggedBy >= 2
        }
    }
}

struct StrategyResult: Identifiable {
    let id = UUID()
    let scope: String            // indicator name, or "All indicators"
    let filter: EntryFilter
    let rule: ExitRule
    let trades: Int
    let mean: Double
    let median: Double
    let winRate: Double
    let profitFactor: Double?
    let avgHold: Double
    let perDay: Double           // mean return ÷ average days held (capital efficiency)
    let worst5: Double
    let trainMean: Double
    let testMean: Double?
    let testTrades: Int
    var heldUp: Bool { (testMean ?? -1) > 0 && testTrades >= 10 && (testMean ?? 0) >= trainMean * 0.4 }
}

enum StrategyFinder {
    struct Trade { let ret: Double; let days: Int; let newer: Bool }

    static func stats(_ trades: [Trade]) -> (mean: Double, median: Double, win: Double, pf: Double?, hold: Double, worst5: Double) {
        let r = trades.map(\.ret).sorted()
        let n = Double(max(1, r.count))
        let gains = r.filter { $0 > 0 }.reduce(0, +), losses = abs(r.filter { $0 <= 0 }.reduce(0, +))
        let k = max(1, r.count / 20)
        return (r.reduce(0, +) / n, PerfCompare.percentile(r, 0.5), Double(r.filter { $0 > 0 }.count) / n,
                losses > 0 ? gains / losses : nil, Double(trades.map(\.days).reduce(0, +)) / n,
                r.prefix(k).reduce(0, +) / Double(k))
    }

    /// Best strategies per scope (ranked on the older half), each with its newer-half check.
    static func find(_ runs: [PerfRun], perScope: Int = 3) -> [StrategyResult] {
        var flagged: [String: Int] = [:]
        for run in runs { for s in Set(run.rows.map(\.symbol)) { flagged[s, default: 0] += 1 } }
        var scopes: [(String, [PerfRow])] = runs.map { ($0.title, $0.rows) }
        if runs.count > 1 { scopes.append(("All indicators", runs.flatMap(\.rows))) }

        var out: [StrategyResult] = []
        for (name, rows) in scopes {
            let days = rows.map(\.eventDay).sorted()
            guard days.count >= 20 else { continue }
            let split = days[days.count / 2]              // older half < split ≤ newer half
            var candidates: [StrategyResult] = []
            for filter in EntryFilter.allCases {
                let kept = rows.filter { filter.keep($0, flaggedBy: flagged[$0.symbol] ?? 1) }
                guard kept.count >= 20 else { continue }
                for rule in ExitRule.grid {
                    var trades: [Trade] = []
                    trades.reserveCapacity(kept.count)
                    for r in kept { if let (ret, d) = rule.simulate(r.path) { trades.append(Trade(ret: ret, days: d, newer: r.eventDay >= split)) } }
                    let train = trades.filter { !$0.newer }, test = trades.filter(\.newer)
                    guard train.count >= max(15, rows.count / 20) else { continue }
                    let all = stats(trades), tr = stats(train)
                    candidates.append(StrategyResult(
                        scope: name, filter: filter, rule: rule, trades: trades.count, mean: all.mean, median: all.median,
                        winRate: all.win, profitFactor: all.pf, avgHold: all.hold, perDay: all.mean / max(1, all.hold),
                        worst5: all.worst5, trainMean: tr.mean, testMean: test.isEmpty ? nil : stats(test).mean, testTrades: test.count))
                }
            }
            // rank on the OLDER half only, then report what happened on the newer half
            let ranked = candidates.sorted { $0.trainMean > $1.trainMean }
            var picked: [StrategyResult] = []
            for c in ranked where !picked.contains(where: { $0.filter == c.filter && $0.rule.hold == c.rule.hold }) {
                picked.append(c)
                if picked.count == perScope { break }
            }
            // the plain "buy and hold H days" baseline for reference
            if let base = candidates.first(where: { $0.filter == .all && $0.rule.target == nil && $0.rule.stop == nil && $0.rule.trail == nil && $0.rule.hold == 21 }) {
                picked.append(base)
            }
            out += picked
        }
        return out
    }
}

// MARK: - Good vs bad incidents

struct SeparatorFeature: Identifiable {
    let id = UUID()
    let name: String
    let early: Bool                  // measured AFTER entry (an early-warning sign, not an entry filter)
    let auc: Double                  // 0.5 = no separation; > 0.5 = higher values → good
    let goodMedian: String
    let badMedian: String
    let rule: String                 // best single cut, e.g. "≤ −3.2%: 41% good vs 18%"
}

struct TreeLeaf: Identifiable {
    let id = UUID()
    let conditions: [String]
    let n: Int
    let goodRate: Double
    let testN: Int
    let testGoodRate: Double?
}

struct IncidentStudy {
    var horizon = 21
    var goodCut = 0.0, badCut = 0.0
    var good = 0, bad = 0
    var features: [SeparatorFeature] = []
    var leaves: [TreeLeaf] = []
    var baseGoodRate = 0.5
}

enum IncidentAnalyzer {
    struct Item { let num: [Double?]; let cat: [String]; let good: Bool; let newer: Bool }

    /// Good = top 25% of returns after H days, bad = bottom 25% (the middle is left out to sharpen the contrast).
    static func study(_ runs: [PerfRun], horizon h: Int, sectors: [String: String]) -> IncidentStudy {
        var out = IncidentStudy()
        out.horizon = h
        var flagged: [String: Int] = [:]
        for run in runs { for s in Set(run.rows.map(\.symbol)) { flagged[s, default: 0] += 1 } }
        var rows: [(PerfRow, String)] = []
        for run in runs { for r in run.rows where r.path.count > max(h, 5) { rows.append((r, run.title)) } }
        guard rows.count >= 40 else { return out }
        let rets = rows.map { $0.0.path[h] }.sorted()
        out.goodCut = PerfCompare.percentile(rets, 0.75)
        out.badCut = PerfCompare.percentile(rets, 0.25)
        let split = rows.map(\.0.eventDay).sorted()[rows.count / 2]

        let numNames: [(String, Bool)] = [("Stock's move in the 21 days before", false), ("Nifty's move in the 21 days before", false),
                                          ("Indicators that flagged it", false), ("Move 3 days after the signal", true),
                                          ("Move 5 days after the signal", true)]
        let catNames = ["Sector", "Indicator", "Weekday of the signal", "Group (split-by column)"]
        let wd = DateFormatter(); wd.locale = Locale(identifier: "en_US_POSIX"); wd.dateFormat = "EEEE"

        var items: [Item] = []
        for (r, ind) in rows {
            let ret = r.path[h]
            guard ret >= out.goodCut || ret <= out.badCut else { continue }
            let weekday = HistoryStore.date(fromKey: r.eventDay).map { wd.string(from: $0) } ?? ""
            items.append(Item(num: [r.preMove, r.marketPre, Double(flagged[r.symbol] ?? 1), r.path[3], r.path[5]],
                              cat: [sectors[r.symbol] ?? "", ind, weekday, r.group],
                              good: ret >= out.goodCut, newer: r.eventDay >= split))
        }
        out.good = items.filter(\.good).count
        out.bad = items.count - out.good
        out.baseGoodRate = Double(out.good) / Double(max(1, items.count))
        func pct(_ x: Double) -> String { String(format: "%+.1f%%", x) }
        func fmt(_ i: Int, _ x: Double) -> String { i == 2 ? String(format: "%.0f", x) : pct(x) }

        // Numeric separators
        for (i, (name, early)) in numNames.enumerated() {
            let pairs = items.compactMap { it in it.num[i].map { ($0, it.good) } }
            guard pairs.count >= 30, Set(pairs.map(\.0)).count > 1 else { continue }
            let auc = ModelMetrics.auc(pairs.map(\.0), pairs.map(\.1))
            let g = pairs.filter(\.1).map(\.0).sorted(), b = pairs.filter { !$0.1 }.map(\.0).sorted()
            var bestRule = "", bestGap = 0.0
            let vals = pairs.map(\.0).sorted()
            for q in stride(from: 0.1, through: 0.9, by: 0.1) {
                let cut = PerfCompare.percentile(vals, q)
                let lo = pairs.filter { $0.0 <= cut }, hi = pairs.filter { $0.0 > cut }
                guard lo.count >= pairs.count / 10, hi.count >= pairs.count / 10 else { continue }
                let gl = Double(lo.filter(\.1).count) / Double(lo.count), gh = Double(hi.filter(\.1).count) / Double(hi.count)
                if abs(gl - gh) > bestGap {
                    bestGap = abs(gl - gh)
                    bestRule = gl > gh ? "≤ \(fmt(i, cut)): \(Int(gl * 100))% good vs \(Int(gh * 100))% above"
                                       : "> \(fmt(i, cut)): \(Int(gh * 100))% good vs \(Int(gl * 100))% below"
                }
            }
            out.features.append(SeparatorFeature(name: name, early: early, auc: auc,
                                                 goodMedian: g.isEmpty ? "—" : fmt(i, PerfCompare.percentile(g, 0.5)),
                                                 badMedian: b.isEmpty ? "—" : fmt(i, PerfCompare.percentile(b, 0.5)), rule: bestRule))
        }
        // Categorical separators: the category whose good-rate differs most from the rest
        for (i, name) in catNames.enumerated() {
            let groups = Dictionary(grouping: items.filter { !$0.cat[i].isEmpty }, by: { $0.cat[i] })
            guard groups.count >= 2 else { continue }
            let rated = groups.filter { $0.value.count >= 15 }.map { ($0.key, Double($0.value.filter(\.good).count) / Double($0.value.count), $0.value.count) }
            guard let best = rated.max(by: { $0.1 < $1.1 }), let worst = rated.min(by: { $0.1 < $1.1 }), best.0 != worst.0 else { continue }
            // AUC-like separation: how well "good-rate of the item's category" ranks good above bad
            let rate = Dictionary(rated.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
            let scored = items.compactMap { it in rate[it.cat[i]].map { ($0, it.good) } }
            let auc = scored.count >= 30 ? ModelMetrics.auc(scored.map(\.0), scored.map(\.1)) : 0.5
            out.features.append(SeparatorFeature(name: name, early: false, auc: auc, goodMedian: "", badMedian: "",
                                                 rule: "best: \(best.0) \(Int(best.1 * 100))% good (n=\(best.2)) · worst: \(worst.0) \(Int(worst.1 * 100))% (n=\(worst.2))"))
        }
        out.features.sort { abs($0.auc - 0.5) > abs($1.auc - 0.5) }

        // Shallow decision tree on the older half (entry-time features only), leaves checked on the newer half
        let train = items.filter { !$0.newer }, test = items.filter(\.newer)
        out.leaves = tree(train, test: test, numNames: numNames, catNames: catNames, minLeaf: max(25, train.count / 20))
        return out
    }

    private struct Split { let desc: String; let left: (Item) -> Bool; let gain: Double }

    private static func bestSplit(_ items: [Item], numNames: [(String, Bool)], catNames: [String], minLeaf: Int) -> (Split, Split)? {
        func gini(_ v: [Item]) -> Double {
            guard !v.isEmpty else { return 0 }
            let p = Double(v.filter(\.good).count) / Double(v.count)
            return 2 * p * (1 - p)
        }
        let parent = gini(items)
        var best: (Double, String, String, (Item) -> Bool)?
        for (i, (name, early)) in numNames.enumerated() where !early {
            let vals = items.compactMap { $0.num[i] }.sorted()
            guard vals.count >= 2 * minLeaf else { continue }
            for q in stride(from: 0.1, through: 0.9, by: 0.1) {
                let cut = PerfCompare.percentile(vals, q)
                let f: (Item) -> Bool = { ($0.num[i] ?? .infinity) <= cut }
                let l = items.filter(f), r = items.filter { !f($0) }
                guard l.count >= minLeaf, r.count >= minLeaf else { continue }
                let g = parent - (Double(l.count) * gini(l) + Double(r.count) * gini(r)) / Double(items.count)
                let c = i == 2 ? String(format: "%.0f", cut) : String(format: "%+.1f%%", cut)
                if g > (best?.0 ?? 0.002) { best = (g, "\(name) ≤ \(c)", "\(name) > \(c)", f) }
            }
        }
        for (i, name) in catNames.enumerated() {
            for value in Set(items.map { $0.cat[i] }) where !value.isEmpty {
                let f: (Item) -> Bool = { $0.cat[i] == value }
                let l = items.filter(f), r = items.filter { !f($0) }
                guard l.count >= minLeaf, r.count >= minLeaf else { continue }
                let g = parent - (Double(l.count) * gini(l) + Double(r.count) * gini(r)) / Double(items.count)
                if g > (best?.0 ?? 0.002) { best = (g, "\(name) = \(value)", "\(name) ≠ \(value)", f) }
            }
        }
        guard let b = best else { return nil }
        let f = b.3
        return (Split(desc: b.1, left: f, gain: b.0), Split(desc: b.2, left: { !f($0) }, gain: b.0))
    }

    private static func tree(_ train: [Item], test: [Item], numNames: [(String, Bool)], catNames: [String], minLeaf: Int) -> [TreeLeaf] {
        var leaves: [TreeLeaf] = []
        func leaf(_ conds: [String], _ tr: [Item], _ te: [Item]) -> TreeLeaf {
            TreeLeaf(conditions: conds, n: tr.count, goodRate: Double(tr.filter(\.good).count) / Double(max(1, tr.count)),
                     testN: te.count, testGoodRate: te.isEmpty ? nil : Double(te.filter(\.good).count) / Double(te.count))
        }
        guard let (a, b) = bestSplit(train, numNames: numNames, catNames: catNames, minLeaf: minLeaf) else {
            return [leaf(["All signals"], train, test)]
        }
        for top in [a, b] {
            let tr = train.filter(top.left), te = test.filter(top.left)
            if let (c, d) = bestSplit(tr, numNames: numNames, catNames: catNames, minLeaf: minLeaf) {
                for sub in [c, d] { leaves.append(leaf([top.desc, sub.desc], tr.filter(sub.left), te.filter(sub.left))) }
            } else {
                leaves.append(leaf([top.desc], tr, te))
            }
        }
        return leaves.sorted { $0.goodRate > $1.goodRate }
    }
}
