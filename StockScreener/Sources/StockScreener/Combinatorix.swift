import Foundation

// MARK: - Combinatorix
//
// Digs through every stored daily snapshot and asks: which COMBINATIONS of filter values, filter conditions,
// alert rules, 5-day changes and sector / market context came before a daily, weekly or monthly gain?
//
//  • Rows: stock × stored day (sampled if huge). Label: the real gain after that day from Yahoo prices.
//  • Signals: each filter column as Low / Mid / High (or 0 / 1), "rising / falling over 5 snapshots",
//    "just turned 1", each Filter condition, each alert rule, the whole Filter, sector quadrant, market regime.
//  • Mining: every combination of 1–3 signals on the EARLIER days (bitsets), scored by a conservative lift
//    (Wilson lower bound ÷ base rate), binomial p-value and Benjamini–Hochberg q-value over everything tried.
//  • Redundant combos (no better than one of their parts) are dropped.
//  • Check: the same combination on LATER days it never saw (walk-forward, gap = horizon) → held up or not.
//  • Families: combos grouped by their strongest signal and given a name (e.g. "Momentum Surge · TG").

enum CombiHorizon: String, CaseIterable, Identifiable, Codable {
    case daily = "Daily", weekly = "Weekly", monthly = "Monthly"
    var id: String { rawValue }
    var tradingDays: Int { switch self { case .daily: return 1; case .weekly: return 5; case .monthly: return 21 } }
    var noun: String { switch self { case .daily: return "Spark"; case .weekly: return "Surge"; case .monthly: return "Runner" } }
    var gainerWord: String { switch self { case .daily: return "daily gainer"; case .weekly: return "weekly gainer"; case .monthly: return "monthly gainer" } }
}

enum CombiKind: String, Codable {
    case level, change, turnedOn, condition, filter, rule, sector, market
    var canBeFilter: Bool { [.level, .condition, .filter, .rule].contains(self) }
}

struct CombiSignal {
    let name: String
    let kind: CombiKind
    let group: String              // two signals of the same group never combine (e.g. MS Low & MS High)
    let column: String             // short theme for names ("" if none)
    var item: PatternItem? = nil   // level signals → Filter condition
    var filter: FilterGroup? = nil // condition / rule / filter signals → Filter group
    var flavour = ""               // "high", "low", "mid", "one", "zero", "rising", "falling", quadrant / regime word
}

struct CombiCombo: Identifiable {
    let id = UUID()
    let signals: [Int]             // indices into CombiHorizonResult.signals
    let text: String
    let total: Int                 // stock-days with the combination (earlier days)
    let gainers: Int
    let hitRate: Double
    let lift: Double
    let safeLift: Double           // Wilson 95% lower bound of the hit rate ÷ base rate
    let pValue: Double
    var qValue = 1.0
    var avgGain = 0.0              // average gain after the day (same rule as the label: peak or close)
    var testTotal = 0
    var testGainers = 0
    var testLift: Double?
    var heldUp: Bool?              // nil = no later days to check on
    var todayMatches: [String] = []
    var family = 0
    var tags: [String] = []
    var canBeFilter: Bool = true
}

struct CombiFamily: Identifiable {
    let id: Int
    let anchor: Int                // signal index
    var autoName: String
    var key: String                // horizon|anchor name — for your own names
    var combos: [Int] = []         // indices into combos
    var bestLift = 0.0
    var heldUp = 0
    var todayMatches: [String] = []
    var description = ""
}

struct CombiHorizonResult {
    var horizon: CombiHorizon = .daily
    var threshold = 0.0
    var usePeak = true
    var rows = 0
    var gainers = 0
    var baseRate = 0.0
    var avgGain = 0.0
    var testRows = 0
    var testBase = 0.0
    var labeledDays = 0
    var testMethod = ""
    var tested = 0
    var signals: [CombiSignal] = []
    var combos: [CombiCombo] = []
    var families: [CombiFamily] = []
    var note = ""
}

struct CombiAllRounder: Identifiable {
    var id: String { signal }
    let signal: String
    let lifts: [CombiHorizon: Double]
    let heldUp: [CombiHorizon: Bool]
}

struct CombiReport {
    var ranAt = Date()
    var daysStored = 0
    var stocks = 0
    var columns: [String] = []
    var conditionCount = 0
    var hasContext = false
    var results: [CombiHorizon: CombiHorizonResult] = [:]
    var allRounders: [CombiAllRounder] = []
    var notes: [String] = []
}

/// One stored day: symbols, their filter-column numbers (Float, NaN = blank) and condition flags.
struct CombiDay {
    let day: String
    let symbols: [String]
    let index: [String: Int]
    let values: [Float]            // symbols.count × columns
    let flags: [UInt64]            // per symbol: bit k = condition signal k passed (≤ 64)

    init(day: String, symbols: [String], values: [Float], flags: [UInt64]) {
        self.day = day; self.symbols = symbols; self.values = values; self.flags = flags
        var ix: [String: Int] = [:]
        for (i, s) in symbols.enumerated() where ix[s] == nil { ix[s] = i }
        index = ix
    }
}

struct CombiInput {
    var days: [CombiDay] = []                      // past stored days, oldest first
    var live: CombiDay?                            // today's data (scored, never learned from)
    var columns: [String] = []
    var conditions: [(name: String, kind: CombiKind, filter: FilterGroup)] = []
    var sectorOf: [String: String] = [:]
    var quadrants: [String: [String: Quadrant]] = [:]   // day → sector → quadrant
    var regimes: [String: MarketRegime] = [:]           // day → market regime
    var book = PriceBook()
    var thresholds: [CombiHorizon: Double] = [:]
    var usePeak = true
    var maxSize = 3
    var useChanges = true
    var useContext = true
    var rowCap = 80_000
}

enum CombiEngine {

    static func run(_ input: CombiInput, progress: ((String) -> Void)? = nil) -> CombiReport {
        var report = CombiReport()
        report.daysStored = input.days.count
        report.columns = input.columns
        report.conditionCount = input.conditions.count
        report.hasContext = input.useContext && (!input.quadrants.isEmpty || !input.regimes.isEmpty)
        report.stocks = Set(input.days.flatMap(\.symbols)).count
        for h in CombiHorizon.allCases {
            progress?("\(h.rawValue): mining combinations…")
            report.results[h] = mine(input, horizon: h)
        }
        report.allRounders = allRounders(report)
        return report
    }

    // MARK: Rows

    private struct Row { let day: Int; let sym: Int; let gain: Double; let gainer: Bool }   // day = index in input.days, -1 = live

    // MARK: One horizon

    static func mine(_ input: CombiInput, horizon h: CombiHorizon) -> CombiHorizonResult {
        var res = CombiHorizonResult()
        res.horizon = h
        res.usePeak = input.usePeak && h != .daily
        res.threshold = input.thresholds[h] ?? 10
        let nCols = input.columns.count

        // 1. Labelled rows
        var rows: [Row] = []
        var labeledDays = Set<Int>()
        for (t, d) in input.days.enumerated() {
            for (i, sym) in d.symbols.enumerated() {
                guard let s = input.book.series(for: sym), let f = s.forward(h.tradingDays, from: d.day) else { continue }
                let g = res.usePeak ? f.maxGain : f.change
                rows.append(Row(day: t, sym: i, gain: g, gainer: g >= res.threshold))
                labeledDays.insert(t)
            }
        }
        res.labeledDays = labeledDays.count
        guard labeledDays.count >= 3, rows.count >= 300 else {
            res.note = "Needs at least 3 stored days that are \(h.tradingDays)+ trading days old, with Yahoo prices after them. Now: \(labeledDays.count) labelled day\(labeledDays.count == 1 ? "" : "s"). This fills in by itself as snapshots build up — or fetch Yahoo prices in the Neural Net window."
            return res
        }

        // 2. Split: walk-forward on days when possible, else held-out stocks
        let ldays = labeledDays.sorted()
        var train: [Row] = [], test: [Row] = []
        if ldays.count >= 15 {
            let nTest = max(4, ldays.count * 3 / 10)
            let firstTest = ldays[ldays.count - nTest]
            let lastTrain = ldays.last(where: { $0 < firstTest - h.tradingDays }) ?? -1
            for r in rows {
                if r.day >= firstTest { test.append(r) } else if r.day <= lastTrain { train.append(r) }
            }
            res.testMethod = "Found on the first \(ldays.count - nTest) days, checked on the last \(nTest) days it never saw (\(h.tradingDays)-day gap)."
        } else {
            for r in rows {
                if symbolBucket(input.days[r.day].symbols[r.sym]) < 0.25 { test.append(r) } else { train.append(r) }
            }
            res.testMethod = "Only \(ldays.count) labelled days, so it checks on 25% of stocks it never saw (walk-forward on later days starts at 15 days)."
        }
        // Sample very large sets (keeps the base rate)
        var rng = SeededRandom(seed: 1234 + UInt64(h.tradingDays))
        if train.count > input.rowCap { train = Array(train.shuffled(using: &rng).prefix(input.rowCap)) }
        if test.count > input.rowCap / 2 { test = Array(test.shuffled(using: &rng).prefix(input.rowCap / 2)) }
        guard !train.isEmpty else { res.note = "Not enough earlier days to learn from yet."; return res }

        res.rows = train.count
        res.gainers = train.filter(\.gainer).count
        res.baseRate = Double(res.gainers) / Double(train.count)
        res.avgGain = train.reduce(0) { $0 + $1.gain } / Double(train.count)
        res.testRows = test.count
        res.testBase = test.isEmpty ? 0 : Double(test.filter(\.gainer).count) / Double(test.count)
        guard res.gainers >= 5 else {
            res.note = "Only \(res.gainers) \(h.gainerWord)s (≥ \(fmt(res.threshold))%) on the earlier days — lower the threshold to find patterns."
            return res
        }

        // 3. Signals
        func value(_ d: CombiDay, _ i: Int, _ c: Int) -> Double? {
            let v = d.values[i * nCols + c]
            return v.isNaN ? nil : Double(v)
        }
        func past(_ t: Int, _ back: Int, _ sym: String, _ c: Int) -> Double? {
            let pt = t - back
            guard pt >= 0, pt < input.days.count, let j = input.days[pt].index[sym] else { return nil }
            return value(input.days[pt], j, c)
        }
        func day(_ t: Int) -> CombiDay { t < 0 ? input.live! : input.days[t] }
        func pastFromLive(_ back: Int, _ sym: String, _ c: Int) -> Double? { past(input.days.count, back, sym, c) }

        // Level thresholds from the training rows (Low / Mid / High by thirds, flags as 0 / 1)
        let trainStocks = train.map { r -> LabeledStock in
            let d = input.days[r.day]
            return LabeledStock(symbol: d.symbols[r.sym], features: (0..<nCols).map { value(d, r.sym, $0) }, gain: r.gain, isGainer: r.gainer)
        }
        var signals: [CombiSignal] = []
        var tests: [(Int, Int, String) -> Bool] = []           // (day index or -1, symbol index, symbol) → passes
        for item in PatternMiner.items(for: trainStocks, featureCount: nCols) {
            let col = input.columns[item.feature]
            let vals = trainStocks.compactMap { $0.features[item.feature] }
            let isFlag = Set(vals).isSubset(of: [0, 1])
            var flavour = "mid"
            switch item.op {
            case .lessOrEqual: flavour = "low"
            case .greaterThan: flavour = "high"
            case .equals: flavour = isFlag ? (item.value == 1 ? "one" : "zero") : "is"
            default: flavour = "mid"
            }
            let name: String
            switch flavour {
            case "low": name = "\(col) Low (≤ \(fmt(item.value)))"
            case "high": name = "\(col) High (> \(fmt(item.value)))"
            case "mid": name = "\(col) Mid (\(fmt(item.value))–\(fmt(item.value2)))"
            default: name = item.describe(input.columns)
            }
            signals.append(CombiSignal(name: name, kind: .level, group: "L:" + col, column: col, item: item, flavour: flavour))
            let c = item.feature
            tests.append { t, i, _ in item.test(value(day(t), i, c)) }
        }
        if input.useChanges {
            for (c, col) in input.columns.enumerated() {
                let vals = trainStocks.compactMap { $0.features[c] }
                guard vals.count >= 20 else { continue }
                if Set(vals).isSubset(of: [0, 1]) {
                    signals.append(CombiSignal(name: "\(col) just turned 1", kind: .turnedOn, group: "C:" + col, column: col, flavour: "turned"))
                    tests.append { t, i, sym in
                        guard value(day(t), i, c) == 1 else { return false }
                        let prev = t < 0 ? pastFromLive(1, sym, c) : past(t, 1, sym, c)
                        return prev == 0
                    }
                } else {
                    var deltas: [Double] = []
                    for r in train.prefix(30_000) {
                        let d = input.days[r.day]
                        if let a = value(d, r.sym, c), let b = past(r.day, 5, d.symbols[r.sym], c), a != b { deltas.append(a - b) }
                    }
                    guard deltas.count >= 50 else { continue }
                    deltas.sort()
                    let lo = deltas[deltas.count / 3], hi = deltas[deltas.count * 2 / 3]
                    let up = max(hi, 0), down = min(lo, 0)
                    func delta(_ t: Int, _ i: Int, _ sym: String) -> Double? {
                        guard let a = value(day(t), i, c), let b = (t < 0 ? pastFromLive(5, sym, c) : past(t, 5, sym, c)) else { return nil }
                        return a - b
                    }
                    signals.append(CombiSignal(name: "\(col) rising (5 days)", kind: .change, group: "C:" + col, column: col, flavour: "rising"))
                    tests.append { t, i, sym in (delta(t, i, sym) ?? 0) > up && (delta(t, i, sym) ?? 0) > 0 }
                    signals.append(CombiSignal(name: "\(col) falling (5 days)", kind: .change, group: "C:" + col, column: col, flavour: "falling"))
                    tests.append { t, i, sym in (delta(t, i, sym) ?? 0) < down && (delta(t, i, sym) ?? 0) < 0 }
                }
            }
        }
        for (k, cnd) in input.conditions.enumerated() where k < 64 {
            signals.append(CombiSignal(name: cnd.name, kind: cnd.kind, group: "F:\(k)", column: shortColumn(cnd.name), filter: cnd.filter,
                                       flavour: cnd.kind.rawValue))
            let bit = UInt64(1) << UInt64(k)
            tests.append { t, i, _ in day(t).flags[i] & bit != 0 }
        }
        if input.useContext {
            if !input.quadrants.isEmpty {
                for q in Quadrant.allCases {
                    signals.append(CombiSignal(name: "Sector \(q.rawValue)", kind: .sector, group: "S", column: "Sector", flavour: q.rawValue))
                    tests.append { t, _, sym in
                        guard let sec = input.sectorOf[sym], let m = input.quadrants[day(t).day] else { return false }
                        return m[sec] == q
                    }
                }
            }
            if !input.regimes.isEmpty {
                for r in [MarketRegime.riskOn, .riskOff] {
                    signals.append(CombiSignal(name: "Market \(r.rawValue)", kind: .market, group: "M", column: "Market", flavour: r.rawValue))
                    tests.append { t, _, _ in input.regimes[day(t).day] == r }
                }
            }
        }
        res.signals = signals

        // 4. Bitsets per part
        let liveRows: [(Int, String)] = input.live.map { l in l.symbols.enumerated().map { ($0.offset, $0.element) } } ?? []
        func bits(_ rs: [Row], _ s: Int) -> [UInt64] {
            var b = [UInt64](repeating: 0, count: (rs.count + 63) / 64)
            for (k, r) in rs.enumerated() where tests[s](r.day, r.sym, input.days[r.day].symbols[r.sym]) { b[k >> 6] |= 1 << UInt64(k & 63) }
            return b
        }
        let trainBits = signals.indices.map { bits(train, $0) }
        let testBits = signals.indices.map { bits(test, $0) }
        let liveBits: [[UInt64]] = signals.indices.map { s in
            var b = [UInt64](repeating: 0, count: (liveRows.count + 63) / 64)
            for (k, lr) in liveRows.enumerated() where tests[s](-1, lr.0, lr.1) { b[k >> 6] |= 1 << UInt64(k & 63) }
            return b
        }
        func mask(_ rs: [Row]) -> [UInt64] {
            var b = [UInt64](repeating: 0, count: (rs.count + 63) / 64)
            for (k, r) in rs.enumerated() where r.gainer { b[k >> 6] |= 1 << UInt64(k & 63) }
            return b
        }
        let G = mask(train), testG = mask(test)

        // 5. Mine 1–3 signal combinations on the training rows
        let n = Double(train.count), base = res.baseRate
        let minG = max(5, res.gainers / 60)
        let minSupport = max(20, train.count / 2000)
        var stats: [[Int]: (safe: Double, lift: Double)] = [:]
        var found: [CombiCombo] = []
        var tested = 0
        func consider(_ idx: [Int], _ total: Int, _ g: Int) {
            guard total >= minSupport else { return }
            tested += 1
            let hit = Double(g) / Double(total)
            let safe = wilsonLower(g, total) / base
            stats[idx] = (safe, hit / base)
            guard hit / base >= 1.2 else { return }
            let p = Stats.binomialUpperTail(k: g, n: total, p: base)
            found.append(CombiCombo(signals: idx, text: idx.map { signals[$0].name }.joined(separator: " + "),
                                    total: total, gainers: g, hitRate: hit, lift: hit / base, safeLift: safe, pValue: p))
        }
        let S = signals.count
        var budget = 3_000_000
        for a in 0..<S {
            let aG = andBits(trainBits[a], G)
            let ga = count(aG)
            guard ga >= minG else { continue }
            consider([a], count(trainBits[a]), ga)
            guard input.maxSize >= 2 else { continue }
            for b in (a + 1)..<S where signals[b].group != signals[a].group {
                let abG = andBits(aG, trainBits[b])
                let gab = count(abG)
                guard gab >= minG else { continue }
                let ab = andBits(trainBits[a], trainBits[b])
                consider([a, b], count(ab), gab)
                guard input.maxSize >= 3, budget > 0 else { continue }
                for c in (b + 1)..<S where signals[c].group != signals[a].group && signals[c].group != signals[b].group {
                    budget -= 1
                    let g = andCount(abG, trainBits[c])
                    guard g >= minG else { continue }
                    consider([a, b, c], andCount(ab, trainBits[c]), g)
                }
            }
        }
        res.tested = tested
        let q = Stats.benjaminiHochberg(found.map(\.pValue), totalTests: max(tested, found.count))
        for k in found.indices { found[k].qValue = q[k] }

        // Keep: believable (q ≤ 0.10), not just a copy of one of its parts
        var kept = found.filter { $0.qValue <= 0.10 && $0.safeLift >= 1.1 }
        if kept.isEmpty { kept = Array(found.filter { $0.qValue <= 0.25 }.sorted { $0.safeLift > $1.safeLift }.prefix(15)) }
        kept = kept.filter { c in
            guard c.signals.count > 1 else { return true }
            for sub in subsets(c.signals) { if let s = stats[sub], s.safe >= c.safeLift * 0.97 { return false } }
            return true
        }
        kept.sort { $0.safeLift * log(Double($0.gainers) + 1) > $1.safeLift * log(Double($1.gainers) + 1) }
        kept = Array(kept.prefix(90))

        // 6. Later days, today's matches, average gain, tags
        func allBits(_ set: [[UInt64]], _ idx: [Int]) -> [UInt64] {
            var b = set[idx[0]]
            for s in idx.dropFirst() { b = andBits(b, set[s]) }
            return b
        }
        for k in kept.indices {
            let idx = kept[k].signals
            let tb = allBits(trainBits, idx)
            var sum = 0.0
            for (r, row) in train.enumerated() where (tb[r >> 6] >> UInt64(r & 63)) & 1 == 1 { sum += row.gain }
            kept[k].avgGain = sum / Double(max(1, kept[k].total))
            if !test.isEmpty {
                let xb = allBits(testBits, idx)
                kept[k].testTotal = count(xb)
                kept[k].testGainers = andCount(xb, testG)
                if kept[k].testTotal >= 10, res.testBase > 0 {
                    kept[k].testLift = (Double(kept[k].testGainers) / Double(kept[k].testTotal)) / res.testBase
                    kept[k].heldUp = (kept[k].testLift ?? 0) >= 1.2
                }
            }
            if !liveRows.isEmpty {
                let lb = allBits(liveBits, idx)
                kept[k].todayMatches = liveRows.indices.filter { (lb[$0 >> 6] >> UInt64($0 & 63)) & 1 == 1 }.map { liveRows[$0].1 }
            }
            kept[k].canBeFilter = idx.allSatisfy { signals[$0].kind.canBeFilter }
            var tags: [String] = []
            if kept[k].hitRate >= 3 * base && Double(kept[k].total) < 0.02 * n { tags.append("🎯 Sniper") }
            if Double(kept[k].total) >= 0.05 * n { tags.append("🌊 Broad") }
            switch kept[k].heldUp {
            case true?: tags.append("✅ Held up")
            case false?: tags.append("⚠️ Faded later")
            default: tags.append("· not checked yet")
            }
            kept[k].tags = tags
        }

        // 7. Families: grouped by the strongest single signal in the combination
        var families: [CombiFamily] = []
        var familyOf: [Int: Int] = [:]
        for k in kept.indices {
            let anchor = kept[k].signals.max { (stats[[$0]]?.lift ?? 0) < (stats[[$1]]?.lift ?? 0) } ?? kept[k].signals[0]
            let f: Int
            if let e = familyOf[anchor] { f = e } else {
                f = families.count
                familyOf[anchor] = f
                families.append(CombiFamily(id: f, anchor: anchor, autoName: familyName(signals[anchor], h),
                                            key: "\(h.rawValue)|\(signals[anchor].name)"))
            }
            kept[k].family = f
            families[f].combos.append(k)
            families[f].bestLift = max(families[f].bestLift, kept[k].lift)
            if kept[k].heldUp == true { families[f].heldUp += 1 }
            for m in kept[k].todayMatches where !families[f].todayMatches.contains(m) { families[f].todayMatches.append(m) }
        }
        // Same auto-name twice → add the anchor's column
        var seen: [String: Int] = [:]
        for f in families.indices { seen[families[f].autoName, default: 0] += 1 }
        for f in families.indices {
            let s = signals[families[f].anchor]
            let named = [.level, .change, .turnedOn, .condition, .rule].contains(s.kind)
            if (seen[families[f].autoName, default: 0] > 1 || named) && !s.column.isEmpty {
                families[f].autoName += " · \(s.column)"
            }
            families[f].description = familyDescription(s, h)
        }
        res.combos = kept
        res.families = families.sorted { a, b in a.heldUp != b.heldUp ? a.heldUp > b.heldUp : a.bestLift > b.bestLift }
        if kept.isEmpty {
            res.note = "No combination beat chance clearly on these \(ldays.count) days (\(tested) tried). That's an honest result — more stored days or a different threshold may change it."
        }
        return res
    }

    // MARK: Names

    /// e.g. "Momentum Surge", "Coiled Runner", "Sector-led Spark".
    static func familyName(_ s: CombiSignal, _ h: CombiHorizon) -> String {
        let adj: String
        switch s.kind {
        case .level:
            switch s.flavour {
            case "high": adj = "Power"
            case "low": adj = "Coiled"
            case "mid": adj = "Steady"
            case "one": adj = "Flagged"
            case "zero": adj = "Quiet"
            default: adj = "Tiered"
            }
        case .change: adj = s.flavour == "rising" ? "Momentum" : "Pullback"
        case .turnedOn: adj = "Fresh-trigger"
        case .condition: adj = "Setup"
        case .filter: adj = "Screened"
        case .rule: adj = "Rule-fired"
        case .sector:
            switch s.flavour {
            case Quadrant.leading.rawValue: adj = "Sector-led"
            case Quadrant.improving.rawValue: adj = "Rotation"
            case Quadrant.weakening.rawValue: adj = "Late-cycle"
            default: adj = "Contrarian"
            }
        case .market: adj = s.flavour == MarketRegime.riskOn.rawValue ? "Tailwind" : "Against-the-tide"
        }
        return "\(adj) \(h.noun)"
    }

    static func familyDescription(_ s: CombiSignal, _ h: CombiHorizon) -> String {
        let what: String
        switch s.kind {
        case .level: what = "built around \(s.name)"
        case .change: what = "stocks whose \(s.column) is \(s.flavour) over the last 5 snapshots"
        case .turnedOn: what = "stocks where \(s.column) has just switched on"
        case .condition: what = "stocks meeting your Filter condition \(s.name)"
        case .filter: what = "stocks passing your whole Filter"
        case .rule: what = "stocks your alert rule fired on"
        case .sector: what = "stocks in a \(s.flavour.lowercased()) sector on the rotation map"
        case .market: what = "days when the market was \(s.flavour.lowercased())"
        }
        return "Combinations \(what) that came before a \(h.gainerWord)."
    }

    static func allRounders(_ r: CombiReport) -> [CombiAllRounder] {
        var lifts: [String: [CombiHorizon: Double]] = [:], held: [String: [CombiHorizon: Bool]] = [:]
        for (h, res) in r.results {
            for f in res.families {
                let name = res.signals[f.anchor].name
                lifts[name, default: [:]][h] = f.bestLift
                held[name, default: [:]][h] = f.heldUp > 0
            }
        }
        return lifts.filter { $0.value.count >= 2 }
            .map { CombiAllRounder(signal: $0.key, lifts: $0.value, heldUp: held[$0.key] ?? [:]) }
            .sorted { $0.lifts.count != $1.lifts.count ? $0.lifts.count > $1.lifts.count : ($0.lifts.values.max() ?? 0) > ($1.lifts.values.max() ?? 0) }
    }

    // MARK: Helpers

    static func shortColumn(_ s: String) -> String {
        String(s.split(whereSeparator: { " <>=≥≤≠()".contains($0) }).first ?? "")
    }

    static func subsets(_ idx: [Int]) -> [[Int]] {
        if idx.count == 2 { return [[idx[0]], [idx[1]]] }
        if idx.count == 3 { return [[idx[0]], [idx[1]], [idx[2]], [idx[0], idx[1]], [idx[0], idx[2]], [idx[1], idx[2]]] }
        return []
    }

    /// Wilson score 95% lower bound for k successes out of n.
    static func wilsonLower(_ k: Int, _ n: Int) -> Double {
        guard n > 0 else { return 0 }
        let z = 1.96, p = Double(k) / Double(n), nn = Double(n)
        let centre = p + z * z / (2 * nn)
        let margin = z * ((p * (1 - p) + z * z / (4 * nn)) / nn).squareRoot()
        return max(0, (centre - margin) / (1 + z * z / nn))
    }

    @inline(__always) static func andBits(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: a.count)
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
            for i in 0..<pa.count { out[i] = pa[i] & pb[i] }
        } }
        return out
    }
    @inline(__always) static func andCount(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var n = 0
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
            for i in 0..<pa.count { n += (pa[i] & pb[i]).nonzeroBitCount }
        } }
        return n
    }
    @inline(__always) static func count(_ a: [UInt64]) -> Int { a.reduce(0) { $0 + $1.nonzeroBitCount } }

    static func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }
}
