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
    }

    @Published var running = false
    @Published var progress = 0.0
    @Published var report: Report?
    @Published var note: String?

    func run(_ f: FFormula, horizon: Int, vm: ScreenerViewModel) {
        guard !running, let label = vm.labelIndex else { return }
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
            let dayList = Array(Set(samples.map(\.day))).sorted()
            let cut = dayList[max(0, min(dayList.count - 1, Int(Double(dayList.count) * 0.7)))]
            let train = samples.filter { $0.day < cut }, test = samples.filter { $0.day >= cut }
            var rep = Report()
            rep.days = dayList.count
            rep.trainDays = dayList.filter { $0 < cut }.count; rep.testDays = dayList.count - rep.trainDays
            rep.base = Self.stats(train); rep.baseTest = Self.stats(test)
            rep.partial = partial
            rep.topGainers = Array(samples.filter(\.gainer).sorted { $0.ret > $1.ret }.prefix(30))

            // usable columns: present for ≥ 60 % of picks and not constant
            let cols = current.headers.indices.filter { ci in
                guard ci != label else { return false }
                let v = train.compactMap { $0.values[ci] }
                return Double(v.count) >= Double(train.count) * 0.6 && Set(v.prefix(400)).count > 2
            }
            var best: [GainerAnalyzer.Rule] = []
            for (n, ci) in cols.enumerated() {
                if let r = Self.bestRule(ci, name: current.headers[ci], in: train, totalGainers: train.filter(\.gainer).count, base: rep.base.hit, minKept: 0.5) {
                    var r = r
                    r.gainerMedian = Self.median(train.filter(\.gainer).compactMap { $0.values[ci] })
                    r.otherMedian = Self.median(train.filter { !$0.gainer }.compactMap { $0.values[ci] })
                    best.append(r)
                }
                if n % 10 == 0 { progress = 0.8 + 0.15 * Double(n) / Double(max(1, cols.count)); await Task.yield() }
            }
            rep.columns = best.sorted { Self.score($0, base: rep.base.hit) > Self.score($1, base: rep.base.hit) }

            // greedy combination (up to 3 rules), on the training days
            var subset = train
            let allG = max(1, train.filter(\.gainer).count)
            for _ in 0..<3 {
                let curHit = Self.stats(subset).hit
                var pick: Rule?
                for ci in cols {
                    guard !rep.combo.contains(where: { $0.colIndex == ci }),
                          var r = Self.bestRule(ci, name: current.headers[ci], in: subset, totalGainers: allG, base: curHit, minKept: 0.35) else { continue }
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
            let base = f.quick ?? f.name
            rep.suggestion = ([base] + rep.combo.map(\.text)).joined(separator: " + ")
            report = rep
            progress = 1
            running = false
        }
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

struct GainerAnalysisView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @StateObject private var a = GainerAnalyzer()
    @ObservedObject private var c = FormulaDaysCenter.shared
    let formula: FFormula
    let horizon: Int
    @State private var suggestion = ""
    @State private var added = false

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
            if a.running { ProgressView(value: a.progress); Text("Reading \(c.days.count - 1) stored days…").font(.caption).foregroundStyle(.secondary) }
            if let n = a.note { Text(n).foregroundStyle(.orange) }
            if let r = a.report { content(r) }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 860, height: 640)
        .onAppear { a.run(formula, horizon: horizon, vm: vm) }
        .onChange(of: a.report?.suggestion) { s in suggestion = s ?? "" }
    }

    @ViewBuilder private func content(_ r: GainerAnalyzer.Report) -> some View {
        // the suggestion
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if r.combo.isEmpty {
                    Text("No column separates the gainers clearly enough — the formula's picks look alike before the move.").foregroundStyle(.secondary)
                } else {
                    Text("Suggested formula").font(.caption.bold()).foregroundStyle(.secondary)
                    TextField("", text: $suggestion, axis: .vertical).textFieldStyle(.roundedBorder).font(.body.monospaced()).lineLimit(1...3)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                        GridRow { Text(""); Text("Picks").bold(); Text("Are gainers").bold(); Text("Avg \(horizon)d").bold() }.font(.caption)
                        statRow("Your formula · fitted days (\(r.trainDays))", r.base)
                        statRow("Suggested · fitted days", r.comboTrain)
                        statRow("Your formula · newest \(r.testDays) days (unseen)", r.baseTest)
                        statRow("Suggested · newest days (unseen)", r.comboTest, highlight: true)
                    }
                    Text(verdict(r)).font(.caption).foregroundStyle(r.comboTest.hit > r.baseTest.hit ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(added ? "Added ✓" : "Add as my formula") {
                            c.mine.insert(.init(name: "", quick: suggestion), at: 0); added = true
                            c.run(vm, lastDays: max(1, UserDefaults.standard.integer(forKey: "fdays.last")))
                        }
                        .buttonStyle(.borderedProminent).disabled(added || FormulaDaysCenter.group(suggestion, vm: vm) == nil)
                        if r.partial { Text("Recent picks are measured to the latest close (\(horizon) days haven't passed).").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        // what's common
        Text("What the gainers have in common (fitted days)").font(.headline)
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Column").bold(); Text("Gainers' median").bold(); Text("Others' median").bold()
                    Text("Best rule").bold(); Text("Keeps gainers").bold(); Text("Picks that gain").bold(); Text("Avg").bold()
                }.font(.caption)
                ForEach(r.columns.prefix(15)) { x in
                    GridRow {
                        Text(x.col).font(.callout.monospaced())
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
                Text("Biggest gainers").font(.headline).padding(.top, 8)
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
        }
        Text("A pattern found in past data can be luck — trust it more when the unseen-days row also improves, and when it keeps a fair share of picks. Not investment advice.")
            .font(.caption2).foregroundStyle(.tertiary)
    }

    private func statRow(_ title: String, _ s: GainerAnalyzer.Stats, highlight: Bool = false) -> some View {
        GridRow {
            Text(title).fontWeight(highlight ? .semibold : .regular)
            Text("\(s.n)").monospacedDigit()
            Text(s.n == 0 ? "—" : String(format: "%.0f%%", s.hit * 100)).monospacedDigit()
            Text(s.n == 0 ? "—" : FSuccessMath.pct(s.avg)).monospacedDigit().foregroundStyle(FSuccessMath.color(s.n == 0 ? nil : s.avg))
        }.font(.callout)
    }

    private func verdict(_ r: GainerAnalyzer.Report) -> String {
        guard r.comboTest.n > 0 else { return "On the newest days the suggestion picked nothing — it may be too strict; try removing a rule." }
        if r.comboTest.hit > r.baseTest.hit + 0.05 && r.comboTest.avg > r.baseTest.avg {
            return String(format: "Holds up on unseen days: %.0f%% of its picks were gainers vs %.0f%%, average %@ vs %@.", r.comboTest.hit * 100, r.baseTest.hit * 100, FSuccessMath.pct(r.comboTest.avg), FSuccessMath.pct(r.baseTest.avg))
        }
        return "Didn't clearly beat your formula on unseen days — the pattern may be noise. Try a longer Look back or a different horizon."
    }
}
