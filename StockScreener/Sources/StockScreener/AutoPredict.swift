import Foundation

// MARK: - AUTO-PREDICT
//
// Learns which combinations of Filter-column values came before a monthly gainer (peak gain ≥ 30% within the
// next 21 trading days, from Yahoo prices), using every stored daily snapshot — the Combinatorix miner on the
// monthly horizon. It then:
//   1. waits until there is enough history (labelled days + real 30% movers) before trusting anything,
//   2. only uses combinations that also worked on LATER days they were not learned from (walk-forward),
//   3. predicts today's stocks that match those combinations, and logs every prediction,
//   4. checks each prediction 21 trading days later (did it really gain ≥ 30%?),
//   5. retires combinations whose live predictions keep failing — and re-learns on each new day.

enum APPhase: String, Codable {
    case collecting = "Collecting data"
    case learning = "Learning — nothing proven yet"
    case active = "Active"
}

/// A combination the miner found.
struct APRule: Codable, Identifiable {
    var id: String { key }
    let key: String              // stable id: the signals without their numbers (survives re-learning)
    let text: String             // with today's thresholds
    let size: Int
    let trainTotal: Int
    let trainGainers: Int
    let lift: Double
    let safeLift: Double
    let testTotal: Int
    let testGainers: Int
    let testLift: Double?
    let heldUp: Bool?
    let avgGain: Double
    var todayMatches: [String]
    var liveTotal = 0            // resolved predictions made with this rule
    var liveHits = 0
    var retired = false          // live record clearly worse than chance

    var trainHit: Double { trainTotal > 0 ? Double(trainGainers) / Double(trainTotal) : 0 }
    var testHit: Double? { testTotal > 0 ? Double(testGainers) / Double(testTotal) : nil }
    var usable: Bool { heldUp == true && !retired }
    /// Conservative chance (Wilson 95% lower bound) from the days it never saw, else from training.
    var chance: Double {
        testTotal >= 10 ? CombiEngine.wilsonLower(testGainers, testTotal) : CombiEngine.wilsonLower(trainGainers, trainTotal)
    }
}

/// One stock predicted on one day, and what happened after.
struct APPrediction: Codable, Identifiable {
    var id: String { day + "|" + symbol }
    let day: String
    let symbol: String
    let close: Double?
    let chance: Double           // 0–1, best matching rule's conservative chance
    let rules: [String]          // rule texts
    let ruleKeys: [String]
    var outcome: Double? = nil   // peak % gain within 21 trading days (nil = not known yet)
    var hit: Bool? = nil
}

/// One learning run (so you can see the predictor improve).
struct APRun: Codable, Identifiable {
    var id: String { day }
    let day: String
    let labeledDays: Int
    let gainers: Int
    let baseRate: Double
    let rulesFound: Int
    let rulesUsable: Int
    let predictions: Int
    let liveHitRate: Double?     // resolved predictions so far
    let liveResolved: Int
}

struct APState: Codable {
    var phase: APPhase = .collecting
    var lastRunDay = ""
    var ranAt: Date?
    var threshold = 30.0
    var labeledDays = 0
    var gainers = 0
    var rows = 0
    var baseRate = 0.0
    var testBase = 0.0
    var testMethod = ""
    var note = ""
    var rules: [APRule] = []
    var predictions: [APPrediction] = []      // every day's predictions, newest first
    var runs: [APRun] = []                    // newest last

    var resolved: [APPrediction] { predictions.filter { $0.hit != nil } }
    var liveHitRate: Double? {
        let r = resolved
        return r.isEmpty ? nil : Double(r.filter { $0.hit == true }.count) / Double(r.count)
    }
}

enum APStore {
    private static var url: URL { HistoryStore.folder.deletingLastPathComponent().appendingPathComponent("autopredict.json") }
    static func load() -> APState {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(APState.self, from: d) else { return APState() }
        return s
    }
    static func save(_ s: APState) {
        var s = s
        if s.predictions.count > 20_000 { s.predictions = Array(s.predictions.prefix(20_000)) }
        if s.runs.count > 500 { s.runs = Array(s.runs.suffix(500)) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }
}

enum APEngine {
    static let horizon = 21
    static var minDays: Int { let v = UserDefaults.standard.integer(forKey: "ap.minDays"); return v > 0 ? v : 15 }
    static var minGainers: Int { let v = UserDefaults.standard.integer(forKey: "ap.minGainers"); return v > 0 ? v : 20 }
    /// A rule can be retired once it has this many resolved live predictions.
    static let retireAfter = 8

    /// Stable key for a combination: signal groups + flavours (no numbers, which move a little each re-learn).
    static func key(_ c: CombiCombo, _ r: CombiHorizonResult) -> String {
        c.signals.map { r.signals[$0].group + "·" + r.signals[$0].flavour }.sorted().joined(separator: " & ")
    }

    /// Fills in outcomes of past predictions that are now 21+ trading days old.
    static func resolve(_ preds: inout [APPrediction], book: PriceBook, threshold: Double) {
        for i in preds.indices where preds[i].hit == nil {
            guard let s = book.series(for: preds[i].symbol), let f = s.forward(horizon, from: preds[i].day) else { continue }
            preds[i].outcome = f.maxGain
            preds[i].hit = f.maxGain >= threshold
        }
    }

    /// Live record per rule key from resolved predictions.
    static func liveRecord(_ preds: [APPrediction]) -> [String: (total: Int, hits: Int)] {
        var out: [String: (Int, Int)] = [:]
        for p in preds { guard let h = p.hit else { continue }
            for k in p.ruleKeys { var v = out[k] ?? (0, 0); v.0 += 1; if h { v.1 += 1 }; out[k] = v }
        }
        return out
    }

    /// Turns a mining result into the new state (rules, phase, today's predictions). Pure — testable.
    static func update(_ old: APState, result res: CombiHorizonResult, liveDay: String, book: PriceBook, threshold: Double) -> APState {
        var s = old
        s.threshold = threshold
        resolve(&s.predictions, book: book, threshold: threshold)
        let live = liveRecord(s.predictions)
        let resolved = s.resolved

        s.labeledDays = res.labeledDays
        s.gainers = res.gainers
        s.rows = res.rows
        s.baseRate = res.baseRate
        s.testBase = res.testBase
        s.testMethod = res.testMethod
        s.note = res.note
        s.rules = res.combos.map { c in
            let k = key(c, res)
            var r = APRule(key: k, text: c.text, size: c.signals.count, trainTotal: c.total, trainGainers: c.gainers, lift: c.lift,
                           safeLift: c.safeLift, testTotal: c.testTotal, testGainers: c.testGainers, testLift: c.testLift,
                           heldUp: c.heldUp, avgGain: c.avgGain, todayMatches: c.todayMatches)
            if let l = live[k] {
                r.liveTotal = l.total; r.liveHits = l.hits
                // retired: live hit rate below 1.2 × chance AND below half of what it promised
                let promised = r.testHit ?? r.trainHit
                r.retired = l.total >= retireAfter && Double(l.hits) / Double(l.total) < max(res.baseRate * 1.2, promised * 0.5)
            }
            return r
        }
        .sorted { ($0.usable ? 0 : 1, -$0.chance) < ($1.usable ? 0 : 1, -$1.chance) }

        let usable = s.rules.filter(\.usable)
        if res.labeledDays < minDays || res.gainers < minGainers { s.phase = .collecting }
        else if usable.isEmpty { s.phase = .learning }
        else { s.phase = .active }

        // Today's predictions (only when Active), replacing any earlier run on the same day
        s.predictions.removeAll { $0.day == liveDay }
        var today: [APPrediction] = []
        if s.phase == .active {
            var bySymbol: [String: [APRule]] = [:]
            for r in usable { for m in r.todayMatches { bySymbol[m, default: []].append(r) } }
            for (sym, rs) in bySymbol {
                let sorted = rs.sorted { $0.chance > $1.chance }
                let close = book.series(for: sym).flatMap { ser in ser.index(onOrBefore: liveDay).map { ser.closes[$0] } }
                today.append(APPrediction(day: liveDay, symbol: sym, close: close, chance: sorted[0].chance,
                                          rules: sorted.map(\.text), ruleKeys: sorted.map(\.key)))
            }
            today.sort { ($0.chance, $0.rules.count) > ($1.chance, $1.rules.count) }
        }
        s.predictions = today + s.predictions
        s.lastRunDay = liveDay
        s.ranAt = Date()
        s.runs.removeAll { $0.day == liveDay }
        s.runs.append(APRun(day: liveDay, labeledDays: res.labeledDays, gainers: res.gainers, baseRate: res.baseRate,
                            rulesFound: s.rules.count, rulesUsable: usable.count, predictions: today.count,
                            liveHitRate: s.liveHitRate, liveResolved: resolved.count))
        return s
    }
}

// MARK: - Shared state

@MainActor final class AutoPredictCenter: ObservableObject {
    static let shared = AutoPredictCenter()
    static let alertRuleID = UUID(uuidString: "A07D1C70-5A3E-4B1F-9C2D-0E1F2A3B4C5D")!
    static let alertRuleName = "AUTO-PREDICT"

    @Published private(set) var state = APStore.load()
    @Published private(set) var running = false
    @Published var status: String?

    static var threshold: Double { let v = UserDefaults.standard.double(forKey: "ap.threshold"); return v > 0 ? v : 30 }
    static var autoRun: Bool { UserDefaults.standard.object(forKey: "ap.auto") as? Bool ?? true }
    static var toAlerts: Bool { UserDefaults.standard.object(forKey: "ap.alerts") as? Bool ?? true }

    /// Re-learns once per new data day (called after each new snapshot and on launch).
    func runIfDue(_ vm: ScreenerViewModel) {
        guard Self.autoRun, !running, vm.hasData else { return }
        let liveKey = HistoryStore.dayKey(vm.dataDay(of: vm.table))
        guard state.lastRunDay != liveKey else { return }
        run(vm)
    }

    func run(_ vm: ScreenerViewModel) {
        guard !running else { return }
        guard let label = vm.labelIndex, vm.hasData else { status = "Import data first."; return }
        guard !vm.priceBook.series.isEmpty else { status = "Waiting for Yahoo prices — fetch them in Daily Gainers (gains are measured from them)."; return }
        let current = vm.table
        let colNames = Array(vm.nnAutoFeatures.prefix(40))
        let cols = colNames.compactMap { current.index(of: $0) }
        let conds = vm.combiConditions()
        guard !cols.isEmpty || !conds.isEmpty else { status = "Pick columns on the Filter screen first — AUTO-PREDICT learns from them."; return }
        let preds = conds.map(\.pred)
        let liveKey = HistoryStore.dayKey(vm.dataDay(of: current))
        let stored = Array(HistoryStore.days().filter { $0 < liveKey }.suffix(400))
        let threshold = Self.threshold

        var input = CombiInput()
        input.columns = colNames
        input.conditions = conds.map { ($0.name, $0.kind, $0.filter) }
        input.book = vm.priceBook
        input.thresholds = [.monthly: threshold]
        input.usePeak = true
        input.maxSize = 3
        input.useChanges = true
        input.useContext = vm.settings.combiUseContext
        if input.useContext, let rep = vm.sectorReport, let sc = vm.sectorColumnIndex {
            for r in current.rows {
                let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
                let sec = r.text(sc).trimmingCharacters(in: .whitespaces)
                if !sym.isEmpty, !sec.isEmpty { input.sectorOf[sym] = sec }
            }
            for s in rep.sectors { for st in s.history { input.quadrants[st.day, default: [:]][s.name] = st.quadrant } }
            for m in rep.marketHistory { input.regimes[m.day] = m.regime }
        }
        let base = input
        let book = vm.priceBook
        running = true
        status = "Reading \(stored.count) stored days…"
        Task { [weak self, weak vm] in
            let days: [CombiDay] = await Task.detached(priority: .utility) {
                stored.compactMap { day in
                    HistoryStore.load(day).flatMap { ScreenerViewModel.align($0, to: current) }
                        .map { ScreenerViewModel.combiDay(day, $0, label: label, cols: cols, preds: preds) }
                }
            }.value
            var inp = base
            inp.days = days
            inp.live = ScreenerViewModel.combiDay(liveKey, current, label: label, cols: cols, preds: preds)
            let ready = inp
            self?.status = "Learning from \(days.count) days…"
            let res = await Task.detached(priority: .utility) { CombiEngine.mine(ready, horizon: .monthly) }.value
            guard let self else { return }
            let before = Set(self.state.predictions.filter { $0.day == liveKey }.map(\.symbol))
            let new = APEngine.update(self.state, result: res, liveDay: liveKey, book: book, threshold: threshold)
            self.state = new
            APStore.save(new)
            self.running = false
            self.status = nil
            let today = new.predictions.filter { $0.day == liveKey }
            if Self.toAlerts, let vm, !today.isEmpty, Set(today.map(\.symbol)) != before {
                vm.recordAutoPredictEvents(today)
            }
        }
    }

    func clearHistory() {
        state = APState()
        APStore.save(state)
    }
}

extension ScreenerViewModel {
    /// Puts today's AUTO-PREDICT stocks into the Alerts window (one event per stock per data day).
    func recordAutoPredictEvents(_ preds: [APPrediction]) {
        var added: [AlertEvent] = []
        for p in preds {
            let exists = alertEvents.contains { $0.ruleID == AutoPredictCenter.alertRuleID && $0.stock == p.symbol && $0.dataDay == p.day }
            if exists { continue }
            var values = ["Stock: \(p.symbol)", "Chance ≥ \(Int((p.chance * 100).rounded()))% (conservative estimate)",
                          "\(p.rules.count) proven combination\(p.rules.count == 1 ? "" : "s")"]
            if let c = p.close { values.append(String(format: "Close: %.2f", c)) }
            added.append(AlertEvent(kind: .alert, ruleID: AutoPredictCenter.alertRuleID, ruleName: AutoPredictCenter.alertRuleName,
                                    stock: p.symbol, dataDay: p.day, values: values,
                                    conditions: "Predicted to gain ≥ \(CombiEngine.fmt(AutoPredictCenter.threshold))% within 21 trading days. Matched: "
                                        + p.rules.prefix(5).joined(separator: " | ")))
        }
        guard !added.isEmpty else { return }
        alertEvents.insert(contentsOf: added, at: 0)
        if alertEvents.count > AlertEventStore.maxEvents { alertEvents.removeLast(alertEvents.count - AlertEventStore.maxEvents) }
        AlertEventStore.save(alertEvents)
    }
}
