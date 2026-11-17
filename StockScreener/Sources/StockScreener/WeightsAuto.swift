import SwiftUI

// MARK: - WEIGHTS_AUTO — weights for your colour rules, learned from what happened after
//
// Features: ONLY your enabled colour rules (Filter → Cell colors), each = "this rule colours its cell" for a stock
//           on a day — the same first-match / "only when it just became true" logic as the colours themselves.
//           Neutral rules aren't features (they still stop later rules on their column, as when painting).
// Samples:  every stock on every saved day of the sheet that has `horizon` trading days of prices after it.
// Target:   gainer = that day's top 20 % of stocks by % change over the next `horizon` trading days (and up).
// Model:    L2-regularised logistic regression (one coefficient per rule + intercept). It accounts for rules that
//           fire together, unlike looking at each rule alone. Trained on identical feature patterns (fast).
// Weights:  positive coefficients scaled so the strongest rule = 100; rules with no / negative effect get 0.
// Checked:  fitted on the older 70 % of days, scored on the newest 30 % (unseen) — WEIGHTS vs WEIGHTS_AUTO —
//           then refitted on all days for the weights you use.

@MainActor final class WeightsAuto: ObservableObject {
    static let shared = WeightsAuto()

    struct RuleStat: Codable, Identifiable {
        var id: UUID
        var title: String
        var fires = 0                 // stock-days the rule coloured
        var gainerRate = 0.0          // of those, share that were gainers
        var avgRet = 0.0              // average % change after (fraction)
        var coef = 0.0                // model coefficient (log-odds)
        var auto = 0.0                // 0…100
        var share: Double? = nil      // share of all stock-days it coloured
        var skipped: String? = nil    // why it couldn't be learned (fires on almost every / almost no stock)
    }
    struct Check: Codable {
        var testDays = 0, testSamples = 0
        var baseRate = 0.0
        var aucUser: Double?, aucAuto = 0.0
        var topUser: Double?, topAuto = 0.0     // avg % change of the top 10 % by score
        var topBase = 0.0
    }
    struct Saved: Codable { var weights: [UUID: Double]; var stats: [RuleStat]; var check: Check?; var trainedAt: Date; var horizon: Int; var days: Int; var samples: Int }

    @Published private(set) var saved: Saved?
    @Published var running = false
    @Published var progress = 0.0
    @Published var note: String?
    var weights: [UUID: Double] { saved?.weights ?? [:] }

    private init() {
        if let d = UserDefaults.standard.data(forKey: "weights.auto"), let s = try? JSONDecoder().decode(Saved.self, from: d),
           s.stats.contains(where: { $0.share != nil }) {          // older trainings (before the always-on fix) are dropped
            saved = s
        } else { UserDefaults.standard.removeObject(forKey: "weights.auto") }
    }
    func clear() { saved = nil; UserDefaults.standard.removeObject(forKey: "weights.auto") }

    // MARK: Training

    private struct Sample { let mask: [Bool]; let ret: Double; let day: Int; var gainer = false; var userScore = 0.0 }

    func train(vm: ScreenerViewModel, horizon: Int) {
        guard !running, let label = vm.labelIndex else { return }
        let rules = vm.settings.cellRules
        let feats = rules.filter { $0.condition.isEnabled && $0.resolvedColor != nil }
        guard !feats.isEmpty else { note = "Add some colour rules first — they are the features."; return }
        let days = HistoryStore.days()
        guard days.count >= 10 else { note = "Need at least 10 saved days of the sheet."; return }
        running = true; progress = 0; note = nil
        Task { @MainActor in
            let current = vm.table
            var samples: [Sample] = []
            var prevRows: [String: SheetRow] = [:]
            var series: [String: ([String], [Double])] = [:]
            var dayIndex = 0
            for (k, d) in days.enumerated() {
                guard var t = await Task.detached(priority: .userInitiated, operation: { HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) } }).value else { continue }
                t = vm.withDeliveryValues(t, asOf: d)
                let prevMap = prevRows
                let ev = RuleEvaluator(rules: rules, features: feats.map(\.id), table: t) { r in prevMap[r.text(label).trimmingCharacters(in: .whitespaces).uppercased()] }
                var thisRows: [String: SheetRow] = [:]
                for r in t.rows {
                    let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
                    thisRows[sym] = r
                    if series[sym] == nil {
                        if let p = vm.priceBook.series(for: sym), !p.days.isEmpty { series[sym] = (p.days, p.closes) }
                        else if let x = DeliveryCenter.shared.book.series[sym], !x.days.isEmpty { series[sym] = (x.days, x.close) }
                        else { series[sym] = ([], []) }
                    }
                    guard let (ds, cs) = series[sym], !ds.isEmpty, let i = FSuccessMath.index(ds, d), i + horizon < cs.count, cs[i] > 0 else { continue }
                    let m = ev.fires(r)
                    let user = zip(feats, m).reduce(0.0) { $0 + ($1.1 ? ($1.0.weight ?? 0) : 0) }
                    samples.append(Sample(mask: m, ret: cs[i + horizon] / cs[i] - 1, day: dayIndex, userScore: user))
                }
                prevRows = thisRows
                dayIndex += 1
                progress = Double(k + 1) / Double(days.count) * 0.85
                await Task.yield()
            }
            guard samples.count >= 200 else {
                note = "Only \(samples.count) stock-days have \(horizon) trading days of prices after them — need more saved days, or a shorter horizon."
                running = false; return
            }
            // gainers: each day's top 20 % (and up)
            for (_, idx) in Dictionary(grouping: samples.indices, by: { samples[$0].day }) {
                let s = idx.sorted { samples[$0].ret > samples[$1].ret }
                for i in s.prefix(max(1, Int((Double(s.count) * 0.2).rounded(.up)))) where samples[i].ret > 0 { samples[i].gainer = true }
            }
            // a rule that colours almost every stock (or almost none) can't be told apart from the baseline —
            // with it in, the model can hand it any weight (that's what made every row 100). Leave such rules out.
            let total = Double(samples.count)
            var learnable = [Bool](repeating: true, count: feats.count)
            var shares = [Double](repeating: 0, count: feats.count)
            for j in feats.indices {
                let on = Double(samples.filter { $0.mask[j] }.count)
                shares[j] = on / total
                if shares[j] > 0.9 || on < 30 { learnable[j] = false }
            }
            let fitSamples = samples.map { x -> Sample in
                var y = x; y = Sample(mask: zip(x.mask, learnable).map { $0 && $1 }, ret: x.ret, day: x.day, gainer: x.gainer, userScore: x.userScore); return y
            }
            let nDays = (samples.map(\.day).max() ?? 0) + 1
            let cut = Int(Double(nDays) * 0.7)
            let train = fitSamples.filter { $0.day < cut }, test = fitSamples.filter { $0.day >= cut }
            let F = feats.count
            let wTrain = Self.fit(train, F: F)
            // check on unseen days
            var check = Check()
            check.testDays = nDays - cut; check.testSamples = test.count
            check.baseRate = test.isEmpty ? 0 : Double(test.filter(\.gainer).count) / Double(test.count)
            let autoScore: (Sample) -> Double = { s in zip(wTrain.dropFirst(), s.mask).reduce(0) { $0 + ($1.1 ? $1.0 : 0) } }
            check.aucAuto = Self.auc(test.map { (autoScore($0), $0.gainer) })
            if feats.contains(where: { ($0.weight ?? 0) > 0 }) {
                check.aucUser = Self.auc(test.map { ($0.userScore, $0.gainer) })
                check.topUser = Self.topAvg(test, score: { $0.userScore })
            }
            check.topAuto = Self.topAvg(test, score: autoScore)
            check.topBase = test.isEmpty ? 0 : test.map(\.ret).reduce(0, +) / Double(test.count)
            progress = 0.95
            // final weights: all days
            let w = Self.fit(fitSamples, F: F)
            let maxPos = zip(w.dropFirst(), learnable).filter { $0.1 }.map(\.0).max() ?? 0
            var stats: [RuleStat] = []
            var weights: [UUID: Double] = [:]
            for (j, r) in feats.enumerated() {
                let on = samples.filter { $0.mask[j] }
                var st = RuleStat(id: r.id, title: "\(r.condition.column) \(r.condition.op.rawValue) \(r.condition.value)\(r.onlyNew == true ? " (just became true)" : "")")
                st.fires = on.count
                st.gainerRate = on.isEmpty ? 0 : Double(on.filter(\.gainer).count) / Double(on.count)
                st.avgRet = on.isEmpty ? 0 : on.map(\.ret).reduce(0, +) / Double(on.count)
                st.coef = learnable[j] ? w[j + 1] : 0
                st.share = shares[j]
                if !learnable[j] {
                    st.skipped = shares[j] > 0.9 ? String(format: "colours %.0f%% of stocks — tells nothing apart", shares[j] * 100) : "coloured fewer than 30 times"
                }
                st.auto = learnable[j] && maxPos > 0 && w[j + 1] > 0 ? (w[j + 1] / maxPos * 100).rounded() : 0
                weights[r.id] = st.auto
                stats.append(st)
            }
            let s = Saved(weights: weights, stats: stats, check: test.isEmpty ? nil : check, trainedAt: Date(), horizon: horizon, days: nDays, samples: samples.count)
            saved = s
            UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "weights.auto")
            progress = 1
            running = false
            vm.refreshWeights()
            MemoryRelief.giveBack()                    // the saved days read for training
        }
    }

    /// Logistic regression with L2, on grouped identical patterns. Returns [intercept, w1 … wF].
    private static func fit(_ s: [Sample], F: Int, lambda: Double = 1.0, iterations: Int = 400) -> [Double] {
        var groups: [[Bool]: (n: Double, pos: Double)] = [:]
        for x in s { var g = groups[x.mask] ?? (0, 0); g.n += 1; if x.gainer { g.pos += 1 }; groups[x.mask] = g }
        let pats = Array(groups)
        let N = Double(max(1, s.count))
        var w = [Double](repeating: 0, count: F + 1)
        let base = s.isEmpty ? 0.2 : max(0.01, min(0.99, Double(s.filter(\.gainer).count) / Double(s.count)))
        w[0] = log(base / (1 - base))
        // Newton steps would be faster, but plain gradient descent with a decaying rate is robust and quick here
        var rate = 2.0
        for it in 0..<iterations {
            var g = [Double](repeating: 0, count: F + 1)
            for (m, c) in pats {
                var z = w[0]
                for j in 0..<F where m[j] { z += w[j + 1] }
                let p = 1 / (1 + exp(-z))
                let err = c.n * p - c.pos                       // Σ (p − y) over the group
                g[0] += err
                for j in 0..<F where m[j] { g[j + 1] += err }
            }
            for j in 0...F { w[j] -= rate * (g[j] / N + (j == 0 ? 0 : lambda / N * w[j])) }
            if it % 100 == 99 { rate *= 0.7 }
        }
        return w
    }

    /// Area under the ROC curve: chance a random gainer scores above a random non-gainer (ties count half).
    private static func auc(_ v: [(Double, Bool)]) -> Double {
        let sorted = v.sorted { $0.0 < $1.0 }
        var rankSum = 0.0, i = 0, pos = 0
        while i < sorted.count {
            var j = i; while j < sorted.count && sorted[j].0 == sorted[i].0 { j += 1 }
            let avgRank = Double(i + j + 1) / 2
            for k in i..<j where sorted[k].1 { rankSum += avgRank; pos += 1 }
            i = j
        }
        let neg = sorted.count - pos
        guard pos > 0, neg > 0 else { return 0.5 }
        return (rankSum - Double(pos) * Double(pos + 1) / 2) / (Double(pos) * Double(neg))
    }

    private static func topAvg(_ s: [Sample], score: (Sample) -> Double) -> Double {
        let sorted = s.sorted { score($0) > score($1) }
        let top = sorted.prefix(max(1, s.count / 10))
        return top.isEmpty ? 0 : top.map(\.ret).reduce(0, +) / Double(top.count)
    }
}

/// Which of the feature rules colour their cell for a row — the painter's logic (first match per painted column,
/// "only when it just became true" against the previous saved day).
struct RuleEvaluator {
    private var byColumn: [Int: [(test: RowPredicate, feature: Int?, onlyNew: Bool)]] = [:]
    private let count: Int
    private let previous: (SheetRow) -> SheetRow?

    init(rules: [CellRule], features: [UUID], table: SheetTable, previous: @escaping (SheetRow) -> SheetRow?) {
        self.count = features.count
        self.previous = previous
        var ignored: [String] = []
        for r in rules where r.condition.isEnabled {
            guard table.index(of: r.condition.column) != nil, let col = r.paint.flatMap({ table.index(of: $0) }) ?? table.index(of: r.condition.column) else { continue }
            let c = r.condition
            guard let p = FilterCompiler.compile(FilterCondition(column: c.column, op: c.op, value: c.value, value2: c.value2), table: table, issues: &ignored) else { continue }
            byColumn[col, default: []].append((p, features.firstIndex(of: r.id), r.onlyNew ?? false))
        }
    }

    func fires(_ row: SheetRow) -> [Bool] {
        var out = [Bool](repeating: false, count: count)
        for (_, list) in byColumn {
            for item in list where item.test(row) {
                if item.onlyNew {
                    guard let old = previous(row) else { continue }
                    if item.test(old) { continue }
                }
                if let f = item.feature { out[f] = true }
                break
            }
        }
        return out
    }
}

// MARK: - Window: reveal both sets of weights, train, check

struct WeightsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var w = WeightsAuto.shared
    @AppStorage("weights.horizon") private var horizon = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Weights — yours and learned").font(.title3.bold())
                Spacer()
                Text("Gainer = top 20 % after")
                TextField("", value: $horizon, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                Stepper("", value: $horizon, in: 1...250).labelsHidden()
                Text("trading days")
                Button { w.train(vm: vm, horizon: max(1, horizon)) } label: {
                    if w.running { ProgressView(value: w.progress).frame(width: 80) } else { Label(w.saved == nil ? "Learn weights" : "Re-learn", systemImage: "brain") }
                }.disabled(w.running)
                if w.saved != nil { Button("Remove WEIGHTS_AUTO") { w.clear(); vm.refreshWeights() } }
            }
            Text("Features are only your colour rules (Filter → Cell colors), each meaning “this rule colours its cell”. A logistic regression learns how much each one raises the chance of being among that day's top-20 % gainers \(horizon) trading days later, using every saved day of the sheet. Strongest rule = 100; rules that don't help get 0.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let n = w.note { Text(n).foregroundStyle(.orange) }
            if let s = w.saved {
                if let c = s.check { checkBox(c, s) }
                table(s)
            } else {
                rulesOnly
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 520)
    }

    private func checkBox(_ c: WeightsAuto.Check, _ s: WeightsAuto.Saved) -> some View {
        GroupBox("Checked on the newest \(c.testDays) days it didn't learn from (\(c.testSamples) stock-days)") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                GridRow { Text(""); Text("Finds gainers (AUC)").bold(); Text("Top 10 % by score: avg \(s.horizon)d").bold() }.font(.caption)
                GridRow {
                    Text("WEIGHTS (yours)")
                    Text(c.aucUser.map { String(format: "%.2f", $0) } ?? "— set weights").monospacedDigit()
                    Text(c.topUser.map { FSuccessMath.pct($0) } ?? "—").monospacedDigit().foregroundStyle(FSuccessMath.color(c.topUser))
                }
                GridRow {
                    Text("WEIGHTS_AUTO").bold()
                    Text(String(format: "%.2f", c.aucAuto)).monospacedDigit().bold()
                    Text(FSuccessMath.pct(c.topAuto)).monospacedDigit().foregroundStyle(FSuccessMath.color(c.topAuto))
                }
                GridRow { Text("All stocks").foregroundStyle(.secondary); Text("0.50 = coin toss").foregroundStyle(.secondary); Text(FSuccessMath.pct(c.topBase)).monospacedDigit().foregroundStyle(.secondary) }
            }
            .font(.callout)
            Text("AUC = chance a gainer scores above a non-gainer. Trained \(s.trainedAt.formatted(date: .abbreviated, time: .shortened)) on \(s.days) days · \(s.samples) stock-days. Past results don't guarantee future ones.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func table(_ s: WeightsAuto.Saved) -> some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Colour rule").bold(); Text("Your weight").bold(); Text("Auto weight").bold()
                    Text("Coloured").bold(); Text("Gainers when coloured").bold(); Text("Avg \(s.horizon)d after").bold(); Text("Effect").bold()
                }.font(.caption)
                ForEach(s.stats) { st in
                    let rule = vm.settings.cellRules.first { $0.id == st.id }
                    GridRow {
                        HStack(spacing: 6) {
                            if let c = rule?.resolvedColor { RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: c)).frame(width: 14, height: 14) }
                            Text(st.title).font(.callout.monospaced())
                        }
                        Text(String(format: "%g", rule?.weight ?? 0)).monospacedDigit()
                        Text(String(format: "%g", st.auto)).monospacedDigit().bold().foregroundStyle(st.auto > 0 ? Color.green : Color.secondary)
                        Text("\(st.fires)" + (st.share.map { String(format: " (%.0f%%)", $0 * 100) } ?? "")).monospacedDigit()
                        Text(String(format: "%.0f%% (all: %.0f%%)", st.gainerRate * 100, (s.check?.baseRate ?? 0.2) * 100)).monospacedDigit()
                        Text(FSuccessMath.pct(st.avgRet)).monospacedDigit().foregroundStyle(FSuccessMath.color(st.avgRet))
                        if let why = st.skipped {
                            Text("left out: " + why).font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(st.coef > 0.05 ? "helps" : (st.coef < -0.05 ? "hurts" : "little")).font(.caption)
                                .foregroundStyle(st.coef > 0.05 ? Color.green : (st.coef < -0.05 ? Color.red : Color.secondary))
                        }
                    }
                }
                let missing = vm.settings.cellRules.filter { r in r.condition.isEnabled && r.resolvedColor != nil && !s.stats.contains { $0.id == r.id } }
                if !missing.isEmpty {
                    GridRow { Text("\(missing.count) rule\(missing.count == 1 ? "" : "s") added after training — press Re-learn").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }

    private var rulesOnly: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your colour rules (the features):").font(.headline)
            ForEach(vm.settings.cellRules.filter { $0.condition.isEnabled && $0.resolvedColor != nil }) { r in
                HStack {
                    if let c = r.resolvedColor { RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: c)).frame(width: 14, height: 14) }
                    Text("\(r.condition.column) \(r.condition.op.rawValue) \(r.condition.value)").font(.callout.monospaced())
                    Spacer()
                    Text("your weight \(String(format: "%g", r.weight ?? 0))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
