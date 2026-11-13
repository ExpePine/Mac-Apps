import SwiftUI

// MARK: - What do a formula's biggest gainers have in common? → a sharper formula
//
// For every stored day in the F counts window (not today — no "after" yet):
//   picks   = stocks that met the formula (with "Also require") that day
//   return  = % change after the success horizon (or to the latest close when the horizon hasn't passed)
//   gainers = that day's top 20 % of picks by return (at least 1, and up)
// Every numeric Filter column on the pick day is compared between gainers and the rest. For each column the
// rule "col > x" or "col < x" (x = a 10…90 % quantile) that keeps most gainers while dropping most others is found.
// The suggestion adds up to 3 such rules greedily. It is fitted on the older 70 % of days and checked on the
// newest 30 % (days it never saw), so you can see whether it holds up or was just luck.

@MainActor final class GainerAnalyzer: ObservableObject {
    struct Sample { let sym: String; let day: String; let ret: Double; let values: [Int: Double]; var gainer = false }
    struct Rule: Identifiable {
        var id: String { col + op + String(value) }
        let col: String, colIndex: Int, op: String, value: Double
        var kept = 0.0, hit = 0.0, avg = 0.0, n = 0
        var gainerMedian: Double?, otherMedian: Double?
        var text: String { "\(col)\(op)\(Self.fmt(value))" }
        static func fmt(_ v: Double) -> String {
            let a = abs(v)
            return a >= 100 ? String(format: "%.0f", v) : (a >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v))
        }
        func passes(_ s: Sample) -> Bool { guard let x = s.values[colIndex] else { return false }; return op == ">" ? x > value : x < value }
    }
    struct Stats { var n = 0, gainers = 0; var hit = 0.0, avg = 0.0 }
    struct Report {
        var days = 0, trainDays = 0, testDays = 0
        var base = Stats(), baseTest = Stats()
        var columns: [Rule] = []
        var combo: [Rule] = []
        var comboTrain = Stats(), comboTest = Stats()
        var suggestion = ""
        var topGainers: [Sample] = []
        var partial = false
        var columnsUsed = 0
        var treeIdeas: [Idea] = []
        var aiIdeas: [Idea] = []
    }
    struct Idea: Identifiable {
        let id = UUID()
        let source: String
        let rules: [Rule]
        let why: String
        var train = Stats(), test = Stats()
        var formula = ""
    }

    @Published var running = false
    @Published var progress = 0.0
    @Published var report: Report?
    @Published var note: String?

    func run(_ f: FFormula, horizon: Int, vm: ScreenerViewModel) {
        guard !running, let label = vm.labelIndex else { return }
        horizonUsed = horizon
        let c = FormulaDaysCenter.shared
        let days = Array(c.days.dropLast())                 // stored days only
        guard days.count >= 5 else { note = "Need at least 5 stored days — raise Look back."; return }
        running = true; progress = 0; report = nil; note = nil
        let eff = c.effective(f)
        Task { @MainActor in
            var samples: [Sample] = []
            let current = vm.table
            var series: [String: ([String], [Double])] = [:]
            var partial = false
            for (k, d) in days.enumerated() {
                guard var t = await Task.detached(priority: .userInitiated, operation: { HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) } }).value else { continue }
                t = vm.withDeliveryValues(t, asOf: d)
                var issues: [String] = []
                guard let p = FilterCompiler.compile(eff.group, table: t, issues: &issues) else { continue }
                let numeric = t.headers.indices.filter { $0 != label }
                for r in t.rows where p(r) {
                    let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
                    if series[sym] == nil {
                        if let p = vm.priceBook.series(for: sym), !p.days.isEmpty { series[sym] = (p.days, p.closes) }
                        else if let dd = DeliveryCenter.shared.book.series[sym], !dd.days.isEmpty { series[sym] = (dd.days, dd.close) }
                        else { series[sym] = ([], []) }
                    }
                    guard let (ds, cs) = series[sym], !ds.isEmpty, let i = FSuccessMath.index(ds, d), i < cs.count - 1, cs[i] > 0 else { continue }
                    let j = min(i + horizon, cs.count - 1)
                    if j < i + horizon { partial = true }
                    var vals: [Int: Double] = [:]
                    for ci in numeric { if let x = r.number(ci), x.isFinite { vals[ci] = x } }
                    samples.append(Sample(sym: sym, day: d, ret: cs[j] / cs[i] - 1, values: vals))
                }
                progress = Double(k + 1) / Double(days.count) * 0.8
                await Task.yield()
            }
            guard samples.count >= 20 else {
                note = "Only \(samples.count) picks with prices after them — not enough to learn from. Raise Look back."
                running = false; return
            }
            // gainers: each day's top 20 % (at least one, and up)
            let byDay = Dictionary(grouping: samples.indices, by: { samples[$0].day })
            for (_, idx) in byDay {
                let sorted = idx.sorted { samples[$0].ret > samples[$1].ret }
                let n = max(1, Int((Double(sorted.count) * 0.2).rounded(.up)))
                for i in sorted.prefix(n) where samples[i].ret > 0 { samples[i].gainer = true }
            }
            self.samples = samples
            self.headers = current.headers
            self.label = label
            self.baseQuick = f.quick ?? f.name
            self.partial = partial
            suggest()
            progress = 1
            running = false
        }
    }

    // kept after reading the days, so suggestions can be redone instantly (other columns, AI …)
    private(set) var samples: [Sample] = []
    private(set) var headers: [String] = []
    private var label = 0
    private var baseQuick = ""
    private var partial = false

    /// Columns that have values for most picks (candidates for rules).
    var usableColumns: [String] {
        guard !samples.isEmpty else { return [] }
        return headers.indices.filter { ci in
            guard ci != label else { return false }
            let v = samples.compactMap { $0.values[ci] }
            return Double(v.count) >= Double(samples.count) * 0.6 && Set(v.prefix(400)).count > 2
        }.map { headers[$0] }
    }

    private var split: (train: [Sample], test: [Sample], trainDays: Int, testDays: Int, days: Int) {
        let dayList = Array(Set(samples.map(\.day))).sorted()
        let cut = dayList[max(0, min(dayList.count - 1, Int(Double(dayList.count) * 0.7)))]
        let tr = samples.filter { $0.day < cut }, te = samples.filter { $0.day >= cut }
        let trd = dayList.filter { $0 < cut }.count
        return (tr, te, trd, dayList.count - trd, dayList.count)
    }

    /// Rules, the greedy combination and the decision tree — only from the allowed columns.
    func suggest() {
        guard !samples.isEmpty else { return }
        let allowed = GainerPrefs.allowed
        let sp = split
        let train = sp.train, test = sp.test
        var rep = Report()
        rep.days = sp.days; rep.trainDays = sp.trainDays; rep.testDays = sp.testDays
        rep.base = Self.stats(train); rep.baseTest = Self.stats(test)
        rep.partial = partial
        rep.topGainers = Array(samples.filter(\.gainer).sorted { $0.ret > $1.ret }.prefix(30))
        let usable = Set(usableColumns)
        let cols = headers.indices.filter { usable.contains(headers[$0]) && (allowed.isEmpty || allowed.contains(headers[$0])) }
        rep.columnsUsed = cols.count
        var best: [Rule] = []
        for ci in cols {
            if var r = Self.bestRule(ci, name: headers[ci], in: train, totalGainers: train.filter(\.gainer).count, base: rep.base.hit, minKept: 0.5) {
                r.gainerMedian = Self.median(train.filter(\.gainer).compactMap { $0.values[ci] })
                r.otherMedian = Self.median(train.filter { !$0.gainer }.compactMap { $0.values[ci] })
                best.append(r)
            }
        }
        rep.columns = best.sorted { Self.score($0, base: rep.base.hit) > Self.score($1, base: rep.base.hit) }

        // greedy combination (up to GainerPrefs.maxRules rules), on the training days
        var subset = train
        let allG = max(1, train.filter(\.gainer).count)
        for _ in 0..<GainerPrefs.maxRules {
            let curHit = Self.stats(subset).hit
            var pick: Rule?
            for ci in cols {
                guard !rep.combo.contains(where: { $0.colIndex == ci }),
                      var r = Self.bestRule(ci, name: headers[ci], in: subset, totalGainers: allG, base: curHit, minKept: 0.35) else { continue }
                let s = subset.filter(r.passes)
                r.kept = Double(s.filter(\.gainer).count) / Double(allG)
                guard r.kept >= 0.35, r.hit >= curHit + 0.02, s.count >= max(8, train.count / 50) else { continue }
                if pick == nil || Self.score(r, base: curHit) > Self.score(pick!, base: curHit) { pick = r }
            }
            guard let p = pick else { break }
            rep.combo.append(p)
            subset = subset.filter(p.passes)
        }
        rep.comboTrain = Self.stats(subset)
        rep.comboTest = Self.stats(test.filter { s in rep.combo.allSatisfy { $0.passes(s) } })
        rep.suggestion = ([baseQuick] + rep.combo.map(\.text)).joined(separator: " + ")

        // ML: a small decision tree (gainer or not) → its best leaves become formulas
        let tree = GainerTree.fit(train, cols: cols, names: headers, depth: GainerPrefs.maxRules)
        rep.treeIdeas = tree.prefix(3).map { path in
            var idea = Idea(source: "Decision tree", rules: path, why: "")
            idea.train = Self.stats(train.filter { s in path.allSatisfy { $0.passes(s) } })
            idea.test = Self.stats(test.filter { s in path.allSatisfy { $0.passes(s) } })
            idea.formula = ([baseQuick] + path.map(\.text)).joined(separator: " + ")
            return idea
        }
        rep.aiIdeas = report?.aiIdeas ?? []
        report = rep
    }

    // MARK: AI — describe the evidence to a language model, then CHECK what it proposes on the data

    @Published var aiBusy = false
    @Published var aiNote: String?

    func askAI(context: String) {
        guard let rep = report, !aiBusy else { return }
        aiBusy = true; aiNote = nil
        let allowed = GainerPrefs.allowed
        let notes = GainerPrefs.notes
        let colsText = rep.columns.prefix(25).map { r -> String in
            let d = notes[r.col].map { " — \($0)" } ?? ""
            return "\(r.col)\(d): gainers median \(r.gainerMedian.map(Rule.fmt) ?? "?"), others \(r.otherMedian.map(Rule.fmt) ?? "?"); best single rule \(r.text) keeps \(Int(r.kept * 100))% of gainers, \(Int(r.hit * 100))% of its picks are gainers"
        }.joined(separator: "\n")
        let described = notes.filter { allowed.isEmpty || allowed.contains($0.key) }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let tree = rep.treeIdeas.map { "\($0.rules.map(\.text).joined(separator: " + ")) → \(Int($0.train.hit * 100))% gainers of \($0.train.n)" }.joined(separator: "\n")
        let system = "You are a careful quantitative analyst for Indian (NSE) stocks. You propose screening rules from evidence. Answer only in the requested format."
        let user = """
        Base formula (already applied to every pick): \(baseQuick)
        A "gainer" = among that day's picks, the top 20 % by % change over the next \(horizonUsed) trading days.
        Training picks: \(rep.base.n), of which \(Int(rep.base.hit * 100))% are gainers; average change \(FSuccessMath.pct(rep.base.avg)).
        \(context.isEmpty ? "" : "What the user is looking for: \(context)\n")
        Column meanings given by the user:
        \(described.isEmpty ? "(none)" : described)

        How each allowed column differs between gainers and the rest:
        \(colsText)

        Decision-tree leaves with many gainers:
        \(tree.isEmpty ? "(none)" : tree)

        Propose 3 different extra-rule sets (1 to \(GainerPrefs.maxRules) rules each) to add to the base formula so that it keeps mostly gainers, using ONLY these columns: \(rep.columns.map(\.col).joined(separator: ", ")).
        Prefer rules that make market sense given the column meanings, not just the numbers.
        Format, exactly one line per idea:
        RULES: col>value + col<value | WHY: one short sentence
        """
        Task { @MainActor in
            do {
                let answer = try await LLMPool.shared.chatAny(system: system, user: user, maxTokens: 700)
                var ideas: [Idea] = []
                let sp = split
                for line in answer.split(whereSeparator: \.isNewline) {
                    let l = String(line)
                    guard let r = l.range(of: "RULES:", options: .caseInsensitive) else { continue }
                    let rest = l[r.upperBound...]
                    let parts = rest.components(separatedBy: "| WHY:")
                    let rulesText = (parts.first ?? "").trimmingCharacters(in: .whitespaces)
                    let why = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                    let rules = rulesText.components(separatedBy: "+").compactMap { self.parseRule($0) }
                    guard !rules.isEmpty else { continue }
                    var idea = Idea(source: "AI", rules: rules, why: why)
                    idea.train = Self.stats(sp.train.filter { s in rules.allSatisfy { $0.passes(s) } })
                    idea.test = Self.stats(sp.test.filter { s in rules.allSatisfy { $0.passes(s) } })
                    idea.formula = ([self.baseQuick] + rules.map(\.text)).joined(separator: " + ")
                    ideas.append(idea)
                }
                if ideas.isEmpty { aiNote = "The AI's answer had no usable rules (columns must match exactly). Try again." }
                report?.aiIdeas = ideas
            } catch {
                aiNote = error.localizedDescription
            }
            aiBusy = false
        }
    }
    var horizonUsed = 30

    /// "Safety>2.5" → a rule on a known column (case-insensitive), else nil.
    private func parseRule(_ t: String) -> Rule? {
        let x = t.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "`*")))
        for op in [">=", "<=", ">", "<"] {
            guard let r = x.range(of: op) else { continue }
            let col = x[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let val = x[r.upperBound...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "")
            guard let v = Double(val), let ci = headers.firstIndex(where: { $0.caseInsensitiveCompare(col) == .orderedSame }) else { return nil }
            return Rule(col: headers[ci], colIndex: ci, op: op.hasPrefix(">") ? ">" : "<", value: v)
        }
        return nil
    }

    static func stats(_ s: [Sample]) -> Stats {
        var r = Stats(); r.n = s.count; r.gainers = s.filter(\.gainer).count
        guard !s.isEmpty else { return r }
        r.hit = Double(r.gainers) / Double(s.count)
        r.avg = s.map(\.ret).reduce(0, +) / Double(s.count)
        return r
    }

    static func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }

    static func score(_ r: Rule, base: Double) -> Double { (r.hit - base) * r.kept.squareRoot() }

    /// Best "col > x" / "col < x" on these samples.
    static func bestRule(_ ci: Int, name: String, in s: [Sample], totalGainers: Int, base: Double, minKept: Double) -> Rule? {
        let vals = s.compactMap { $0.values[ci] }.sorted()
        guard vals.count >= 10, totalGainers > 0 else { return nil }
        var qs: [Double] = []
        for q in stride(from: 0.1, through: 0.9, by: 0.1) { let x = vals[Int(Double(vals.count - 1) * q)]; if !qs.contains(x) { qs.append(x) } }
        var best: Rule?
        for x in qs {
            for op in [">", "<"] {
                var r = Rule(col: name, colIndex: ci, op: op, value: x)
                let sub = s.filter(r.passes)
                guard sub.count >= max(8, s.count / 50) else { continue }
                let g = sub.filter(\.gainer).count
                r.n = sub.count
                r.kept = Double(g) / Double(totalGainers)
                r.hit = Double(g) / Double(sub.count)
                r.avg = sub.map(\.ret).reduce(0, +) / Double(sub.count)
                guard r.kept >= minKept, r.hit > base else { continue }
                if best == nil || score(r, base: base) > score(best!, base: base) { best = r }
            }
        }
        return best
    }
}

// MARK: - Your choices: which columns may be used, what they mean, how many rules

enum GainerPrefs {
    static var allowed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "gainers.allowed") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "gainers.allowed") }
    }
    static var notes: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "col.notes") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "col.notes") }
    }
    static var maxRules: Int {
        get { let v = UserDefaults.standard.integer(forKey: "gainers.maxRules"); return v == 0 ? 3 : v }
        set { UserDefaults.standard.set(newValue, forKey: "gainers.maxRules") }
    }
}

// MARK: - ML: a small decision tree (CART, Gini) — readable leaves = formulas

enum GainerTree {
    /// Paths to the leaves where gainers are most concentrated (best first).
    @MainActor static func fit(_ s: [GainerAnalyzer.Sample], cols: [Int], names: [String], depth: Int) -> [[GainerAnalyzer.Rule]] {
        let base = s.isEmpty ? 0 : Double(s.filter(\.gainer).count) / Double(s.count)
        let minLeaf = max(10, s.count / 40)
        var leaves: [(path: [GainerAnalyzer.Rule], rate: Double, n: Int)] = []
        func gini(_ g: Int, _ n: Int) -> Double { guard n > 0 else { return 0 }; let p = Double(g) / Double(n); return 2 * p * (1 - p) }
        func grow(_ set: [GainerAnalyzer.Sample], _ path: [GainerAnalyzer.Rule], _ d: Int) {
            let g = set.filter(\.gainer).count
            let rate = set.isEmpty ? 0 : Double(g) / Double(set.count)
            guard d < depth, set.count >= 2 * minLeaf, g > 0, g < set.count else { leaves.append((path, rate, set.count)); return }
            var best: (rule: GainerAnalyzer.Rule, gain: Double)?
            let parent = gini(g, set.count)
            for ci in cols where !path.contains(where: { $0.colIndex == ci }) {
                let vals = set.compactMap { $0.values[ci] }.sorted()
                guard vals.count >= 2 * minLeaf else { continue }
                var qs: [Double] = []
                for q in stride(from: 0.1, through: 0.9, by: 0.1) { let x = vals[Int(Double(vals.count - 1) * q)]; if !qs.contains(x) { qs.append(x) } }
                for t in qs {
                    let r = GainerAnalyzer.Rule(col: names[ci], colIndex: ci, op: ">", value: t)
                    var ny = 0, gy = 0
                    for x in set where r.passes(x) { ny += 1; if x.gainer { gy += 1 } }
                    let nn = set.count - ny, gn = g - gy
                    guard ny >= minLeaf, nn >= minLeaf else { continue }
                    let gain = parent - (Double(ny) * gini(gy, ny) + Double(nn) * gini(gn, nn)) / Double(set.count)
                    if best == nil || gain > best!.gain { best = (r, gain) }
                }
            }
            guard let b = best, b.gain > 0.001 else { leaves.append((path, rate, set.count)); return }
            let yes = set.filter(b.rule.passes), no = set.filter { !b.rule.passes($0) }
            var notRule = b.rule; notRule = GainerAnalyzer.Rule(col: b.rule.col, colIndex: b.rule.colIndex, op: "<", value: b.rule.value)
            grow(yes, path + [b.rule], d + 1)
            grow(no, path + [notRule], d + 1)    // "≤ t" is written as "< t" (values exactly at t are rare)
        }
        grow(s, [], 0)
        return leaves.filter { !$0.path.isEmpty && $0.rate > base * 1.2 && $0.n >= minLeaf }
            .sorted { ($0.rate - base) * Double($0.n).squareRoot() > ($1.rate - base) * Double($1.n).squareRoot() }
            .map(\.path)
    }
}

struct GainerAnalysisView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @StateObject private var a = GainerAnalyzer()
    @ObservedObject private var c = FormulaDaysCenter.shared
    @ObservedObject private var llm = LLMPool.shared
    let formula: FFormula
    let horizon: Int
    @State private var suggestion = ""
    @State private var addedSet = Set<String>()
    @State private var showColumns = false
    @AppStorage("gainers.context") private var context = ""
    @State private var maxRules = GainerPrefs.maxRules

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Max gainers of: \(formula.name)").font(.title3.bold()).lineLimit(1)
                    Text("Gainer = each day's top 20 % of picks by % change after \(horizon) trading days").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 10) {
                Button { showColumns = true } label: {
                    Label(GainerPrefs.allowed.isEmpty ? "Columns: all" : "Columns: \(GainerPrefs.allowed.count) chosen", systemImage: "checklist")
                }
                .popover(isPresented: $showColumns) { GainerColumnChooser(columns: a.usableColumns) { a.suggest() } }
                .help("Choose which columns may appear in suggestions, and describe what each one means (the AI reads your descriptions)")
                Stepper("Up to \(maxRules) rules", value: $maxRules, in: 1...5).fixedSize()
                    .onChange(of: maxRules) { v in GainerPrefs.maxRules = v; a.suggest() }
                Spacer()
            }
            if a.running { ProgressView(value: a.progress); Text("Reading \(c.days.count - 1) stored days…").font(.caption).foregroundStyle(.secondary) }
            if let n = a.note { Text(n).foregroundStyle(.orange) }
            if let r = a.report {
                ScrollView { content(r) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 920, height: 720)
        .onAppear { a.run(formula, horizon: horizon, vm: vm) }
        .onChange(of: a.report?.suggestion) { s in suggestion = s ?? "" }
    }

    @ViewBuilder private func content(_ r: GainerAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // statistics suggestion
            GroupBox("Statistics — best rules added one by one") {
                VStack(alignment: .leading, spacing: 6) {
                    if r.combo.isEmpty {
                        Text("No allowed column separates the gainers clearly enough.").foregroundStyle(.secondary)
                    } else {
                        TextField("", text: $suggestion, axis: .vertical).textFieldStyle(.roundedBorder).font(.body.monospaced()).lineLimit(1...3)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                            GridRow { Text(""); Text("Picks").bold(); Text("Are gainers").bold(); Text("Avg \(horizon)d").bold() }.font(.caption)
                            statRow("Your formula · fitted days (\(r.trainDays))", r.base)
                            statRow("Suggested · fitted days", r.comboTrain)
                            statRow("Your formula · newest \(r.testDays) days (unseen)", r.baseTest)
                            statRow("Suggested · newest days (unseen)", r.comboTest, highlight: true)
                        }
                        Text(verdict(r.comboTest, r.baseTest)).font(.caption).foregroundStyle(r.comboTest.hit > r.baseTest.hit ? Color.green : Color.orange)
                        addButton(suggestion)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            // ML + AI ideas
            GroupBox("Machine learning & AI ideas — each checked on the unseen days") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("What are you looking for? e.g. early breakouts with rising delivery, avoid illiquid stocks", text: $context, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...3)
                        Button { a.askAI(context: context) } label: {
                            if a.aiBusy { ProgressView().controlSize(.small) } else { Label("Ask AI", systemImage: "sparkles") }
                        }
                        .disabled(a.aiBusy || llm.endpoints.isEmpty)
                        .help(llm.endpoints.isEmpty ? "Add a free AI key in Settings → Free AI keys" : "Sends the column summaries (no stock names) to your AI providers; their rules are then tested on the data here")
                    }
                    if let n = a.aiNote { Text(n).font(.caption).foregroundStyle(.orange) }
                    if r.treeIdeas.isEmpty && r.aiIdeas.isEmpty {
                        Text("The decision tree found no leaf clearly richer in gainers. Ask the AI, or allow more columns.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(r.treeIdeas + r.aiIdeas) { idea in ideaRow(idea) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            // what's common
            Text("What the gainers have in common (fitted days · \(r.columnsUsed) columns)").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Column").bold(); Text("Gainers' median").bold(); Text("Others' median").bold()
                    Text("Best rule").bold(); Text("Keeps gainers").bold(); Text("Picks that gain").bold(); Text("Avg").bold()
                }.font(.caption)
                ForEach(r.columns.prefix(15)) { x in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(x.col).font(.callout.monospaced())
                            if let d = GainerPrefs.notes[x.col], !d.isEmpty { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Text(x.gainerMedian.map(GainerAnalyzer.Rule.fmt) ?? "—").monospacedDigit()
                        Text(x.otherMedian.map(GainerAnalyzer.Rule.fmt) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                        Button(x.text) { suggestion = (formula.quick ?? formula.name) + " + " + x.text }
                            .buttonStyle(.link).font(.callout.monospaced()).help("Use the formula + this rule")
                        Text(String(format: "%.0f%%", x.kept * 100)).monospacedDigit()
                        Text(String(format: "%.0f%% (was %.0f%%)", x.hit * 100, r.base.hit * 100)).monospacedDigit()
                        Text(FSuccessMath.pct(x.avg)).monospacedDigit().foregroundStyle(FSuccessMath.color(x.avg))
                    }.font(.callout)
                }
            }
            if !r.topGainers.isEmpty {
                Text("Biggest gainers").font(.headline)
                FlowLayout(spacing: 4, lineSpacing: 3) {
                    ForEach(Array(r.topGainers.enumerated()), id: \.offset) { item in
                        let g = item.element
                        Button("\(g.sym) \(String(format: "%+.0f%%", g.ret * 100)) · \(g.day.suffix(5))") {
                            vm.openChart(g.sym, queue: r.topGainers.map(\.sym), goTo: g.day, openWindow: openWindow)
                        }
                        .buttonStyle(.plain).font(.caption.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.green.opacity(0.15)))
                    }
                }
            }
            Text("Rules are learned on the older 70 % of days and tested on the newest 30 %. A pattern can still be luck — trust ideas that win on the unseen days with a fair number of picks. Not investment advice.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func ideaRow(_ i: GainerAnalyzer.Idea) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(i.source).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(i.source == "AI" ? Color.purple.opacity(0.25) : Color.blue.opacity(0.25)))
                Text(i.rules.map(\.text).joined(separator: " + ")).font(.callout.monospaced())
                Spacer()
                Button("Use") { suggestion = i.formula }.controlSize(.small)
                addButton(i.formula).controlSize(.small)
            }
            if !i.why.isEmpty { Text(i.why).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 14) {
                Text("fitted: \(i.train.n) picks · \(Int(i.train.hit * 100))% gainers · \(FSuccessMath.pct(i.train.n == 0 ? nil : i.train.avg))")
                Text("unseen: \(i.test.n) picks · \(i.test.n == 0 ? "—" : "\(Int(i.test.hit * 100))%") gainers · \(FSuccessMath.pct(i.test.n == 0 ? nil : i.test.avg))")
                    .foregroundStyle(i.test.n > 0 && i.test.hit > (a.report?.baseTest.hit ?? 1) ? Color.green : Color.orange)
            }.font(.caption.monospacedDigit())
        }
        .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func addButton(_ text: String) -> some View {
        Button(addedSet.contains(text) ? "Added ✓" : "Add as my formula") {
            c.mine.insert(.init(name: "", quick: text), at: 0); addedSet.insert(text)
            c.run(vm, lastDays: max(1, UserDefaults.standard.integer(forKey: "fdays.last")))
        }
        .disabled(addedSet.contains(text) || FormulaDaysCenter.group(text, vm: vm) == nil)
    }

    private func statRow(_ title: String, _ s: GainerAnalyzer.Stats, highlight: Bool = false) -> some View {
        GridRow {
            Text(title).fontWeight(highlight ? .semibold : .regular)
            Text("\(s.n)").monospacedDigit()
            Text(s.n == 0 ? "—" : String(format: "%.0f%%", s.hit * 100)).monospacedDigit()
            Text(s.n == 0 ? "—" : FSuccessMath.pct(s.avg)).monospacedDigit().foregroundStyle(FSuccessMath.color(s.n == 0 ? nil : s.avg))
        }.font(.callout)
    }

    private func verdict(_ t: GainerAnalyzer.Stats, _ b: GainerAnalyzer.Stats) -> String {
        guard t.n > 0 else { return "On the newest days it picked nothing — it may be too strict; try fewer rules." }
        if t.hit > b.hit + 0.05 && t.avg > b.avg {
            return String(format: "Holds up on unseen days: %.0f%% of its picks were gainers vs %.0f%%, average %@ vs %@.", t.hit * 100, b.hit * 100, FSuccessMath.pct(t.avg), FSuccessMath.pct(b.avg))
        }
        return "Didn't clearly beat your formula on unseen days — the pattern may be noise. Try a longer Look back or a different horizon."
    }
}

/// Choose the columns suggestions may use, and describe what each means.
struct GainerColumnChooser: View {
    let columns: [String]
    let changed: () -> Void
    @State private var allowed = GainerPrefs.allowed
    @State private var notes = GainerPrefs.notes
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Columns for suggestions").font(.headline)
            Text("Tick the columns rules may use (none ticked = all). Describe a column so you — and the AI — know what it means.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Button("All") { allowed = Set(columns) }
                Button("None") { allowed = [] }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(columns.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { col in
                        HStack {
                            Toggle(col, isOn: Binding(get: { allowed.contains(col) }, set: { if $0 { allowed.insert(col) } else { allowed.remove(col) } }))
                                .toggleStyle(.checkbox).font(.callout.monospaced()).frame(width: 150, alignment: .leading)
                            TextField("what it means…", text: Binding(get: { notes[col] ?? "" }, set: { notes[col] = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder).font(.caption)
                        }
                    }
                }
            }
            .frame(height: 360)
            HStack {
                Text(allowed.isEmpty ? "Using all \(columns.count) columns" : "\(allowed.count) of \(columns.count) chosen").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { GainerPrefs.allowed = allowed; GainerPrefs.notes = notes; changed() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(14).frame(width: 520)
        .onDisappear { GainerPrefs.allowed = allowed; GainerPrefs.notes = notes; changed() }
    }
}
