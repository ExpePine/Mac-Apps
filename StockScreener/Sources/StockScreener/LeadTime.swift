import SwiftUI

/// Lead-time matrix: which Filter condition turns true closest before a big move.
///   Move ("multibagger" here) = the close rises ≥ `gain` % within the next `within` trading days. Its start = the first
///   day of such a run (next start allowed only after `within` days).
///   For every move and every condition: distance = trading days from the last day the condition was true (on or
///   before the start, at most `lookback` days back) to the start. 0 = true on the start day itself.
///   Precision = of the stock-days a condition was true, how many had a move start within the next `within` days;
///   lift = precision ÷ the same share for all stock-days (base rate).
@MainActor final class LeadTimeCenter: ObservableObject {
    static let shared = LeadTimeCenter()

    struct Cond: Identifiable, Hashable { let id: String; let name: String; let kind: String }
    struct Move: Identifiable { var id: String { sym + "|" + start }; let sym: String; let start: String; let gain: Double }
    struct Stat: Identifiable {
        var id: String { cond.id }
        let cond: Cond
        var caught = 0, events = 0
        var median: Double? = nil, mean: Double? = nil
        var fires = 0, firesHit = 0
        var precision: Double? { fires > 0 ? Double(firesHit) / Double(fires) * 100 : nil }
        var hitRate: Double? { events > 0 ? Double(caught) / Double(events) * 100 : nil }
    }

    @Published private(set) var running = false
    @Published private(set) var progress = 0.0
    @Published private(set) var note: String?
    @Published private(set) var conds: [Cond] = []
    @Published private(set) var moves: [Move] = []
    @Published private(set) var dist: [String: [String: Int]] = [:]      // move id → cond id → days before
    @Published private(set) var stats: [Stat] = []
    @Published private(set) var baseRate: Double?
    @Published private(set) var daysUsed = 0

    func run(vm: ScreenerViewModel, gain: Double, within: Int, lookback: Int) {
        guard !running, let label = vm.labelIndex else { return }
        let days = HistoryStore.days()
        guard days.count >= 5 else { note = "Need at least 5 saved days of the sheet."; return }
        // conditions: your coloured Filter rules + My formulas
        let rules = vm.settings.cellRules.filter { $0.condition.isEnabled }
        var cs: [Cond] = rules.map { r in
            let c = r.condition
            let v = c.value2.isEmpty ? c.value : c.value + "…" + c.value2
            return Cond(id: r.id.uuidString, name: "\(c.column) \(c.op.rawValue) \(v)" + ((r.onlyNew ?? false) ? " (new)" : ""), kind: "Colour rule")
        }
        let mine = FormulaDaysCenter.shared.mine
        for m in mine { cs.append(Cond(id: "f:" + m.id.uuidString, name: m.name.isEmpty ? m.quick : m.name, kind: "My formula")) }
        guard !cs.isEmpty else { note = "No colour rules or My formulas to test."; return }
        running = true; progress = 0; note = nil; conds = cs
        Task { @MainActor in
            let current = vm.table
            // 1) which condition is true for which stock on which saved day
            var trueOn: [String: [String: Set<String>]] = [:]      // sym → cond id → days
            var prevRows: [String: SheetRow] = [:]
            var symbols = Set<String>()
            var used = 0
            for (k, d) in days.enumerated() {
                guard var t = await Task.detached(priority: .userInitiated, operation: { HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) } }).value else { continue }
                t = vm.withDeliveryValues(t, asOf: d)
                used += 1
                let prevMap = prevRows
                let ev = RuleEvaluator(rules: rules, features: rules.map(\.id), table: t) { r in prevMap[r.text(label).trimmingCharacters(in: .whitespaces).uppercased()] }
                var preds: [(String, RowPredicate)] = []
                for m in mine {
                    var issues: [String] = []
                    if let g = FormulaDaysCenter.group(m.quick, vm: vm), let p = FilterCompiler.compile(g, table: t, issues: &issues) { preds.append(("f:" + m.id.uuidString, p)) }
                }
                var thisRows: [String: SheetRow] = [:]
                for r in t.rows {
                    let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
                    guard !sym.isEmpty else { continue }
                    thisRows[sym] = r; symbols.insert(sym)
                    let m = ev.fires(r)
                    for (j, rule) in rules.enumerated() where j < m.count && m[j] { trueOn[sym, default: [:]][rule.id.uuidString, default: []].insert(d) }
                    for (id, p) in preds where p(r) { trueOn[sym, default: [:]][id, default: []].insert(d) }
                }
                prevRows = thisRows
                progress = Double(k + 1) / Double(days.count) * 0.8
                await Task.yield()
            }
            // 2) moves and distances on each stock's price days
            let first = days.first ?? "", lastSaved = days.last ?? ""
            var mv: [Move] = [], dm: [String: [String: Int]] = [:]
            var st: [String: Stat] = Dictionary(uniqueKeysWithValues: cs.map { ($0.id, Stat(cond: $0)) })
            var allDays = 0, allHit = 0
            for sym in symbols.sorted() {
                let (ds, cl): ([String], [Double])
                if let p = vm.priceBook.series(for: sym), !p.days.isEmpty { (ds, cl) = (p.days, p.closes) }
                else if let x = DeliveryCenter.shared.book.series[sym], !x.days.isEmpty {
                    let f = Del2.splitFactors(x.close); (ds, cl) = (x.days, zip(x.close, f).map { $0 * $1 })
                } else { continue }
                // move starts
                var starts: [Int] = []
                var i = 0
                while i < cl.count - 1 {
                    if cl[i] > 0, ds[i] >= first {
                        let hi = cl[(i + 1)...min(cl.count - 1, i + within)].max() ?? 0
                        if hi / cl[i] - 1 >= gain / 100 { starts.append(i); i += within; continue }
                    }
                    i += 1
                }
                let startSet = Set(starts)
                let tOn = trueOn[sym] ?? [:]
                for s0 in starts {
                    let mvID = sym + "|" + ds[s0]
                    let g = ((cl[(s0 + 1)...min(cl.count - 1, s0 + within)].max() ?? 0) / cl[s0] - 1) * 100
                    mv.append(Move(sym: sym, start: ds[s0], gain: g))
                    for c in cs {
                        st[c.id]!.events += 1
                        guard let set = tOn[c.id] else { continue }
                        var dist: Int? = nil
                        for back in 0...lookback where s0 - back >= 0 {
                            if set.contains(ds[s0 - back]) { dist = back; break }
                        }
                        if let dist { dm[mvID, default: [:]][c.id] = dist; st[c.id]!.caught += 1 }
                    }
                }
                // precision: saved days with `within` price days after them
                for (k, day) in ds.enumerated() where day >= first && day <= lastSaved && k + within < ds.count {
                    let hit = (k...(k + within)).contains { startSet.contains($0) }
                    allDays += 1; if hit { allHit += 1 }
                    for (cid, set) in tOn where set.contains(day) {
                        st[cid]!.fires += 1; if hit { st[cid]!.firesHit += 1 }
                    }
                }
            }
            for c in cs {
                let v = mv.compactMap { dm[$0.id]?[c.id] }.map(Double.init).sorted()
                if !v.isEmpty {
                    st[c.id]!.median = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
                    st[c.id]!.mean = v.reduce(0, +) / Double(v.count)
                }
            }
            moves = mv.sorted { $0.start > $1.start }
            dist = dm
            baseRate = allDays > 0 ? Double(allHit) / Double(allDays) * 100 : nil
            stats = cs.compactMap { st[$0.id] }
            daysUsed = used
            note = mv.isEmpty ? "No ≥\(Int(gain))% moves within \(within) days found from \(first) on." : nil
            progress = 1; running = false
            MemoryRelief.giveBack()
        }
    }
}

struct LeadTimeView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = LeadTimeCenter.shared
    @AppStorage("lead.gain") private var gain = 30.0
    @AppStorage("lead.within") private var within = 22
    @AppStorage("lead.lookback") private var lookback = 60
    @AppStorage("lead.sort") private var sortBy = 0      // 0 lift, 1 closest (median), 2 caught %
    @State private var tab = 0
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Move =").font(.callout)
                TextField("30", value: $gain, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                Text("% or more within").font(.callout)
                TextField("22", value: $within, format: .number).frame(width: 40).textFieldStyle(.roundedBorder)
                Text("trading days · look back").font(.callout)
                TextField("60", value: $lookback, format: .number).frame(width: 40).textFieldStyle(.roundedBorder)
                Text("days").font(.callout)
                Button(c.running ? "Working…" : "Run") { c.run(vm: vm, gain: gain, within: max(1, within), lookback: max(0, lookback)) }
                    .buttonStyle(.borderedProminent).disabled(c.running)
                if c.running { ProgressView(value: c.progress).frame(width: 120) }
                Spacer()
                Picker("", selection: $tab) { Text("Conditions").tag(0); Text("Matrix").tag(1) }.pickerStyle(.segmented).fixedSize()
            }
            Text("For every ≥\(Int(gain))%-in-\(within)-days move that started on or after your first saved sheet day (\(c.daysUsed) days used): how many trading days before its start each condition was last true. Conditions = your colour rules + My formulas. Precision = share of the days a condition was true that a move started within \(within) days; lift = precision ÷ all days (\(c.baseRate.map { String(format: "%.1f%%", $0) } ?? "—")).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let n = c.note { Text(n).font(.caption).foregroundStyle(.orange) }
            if tab == 0 { conditionsTable } else { matrix }
        }
        .padding(12)
    }

    private func lift(_ s: LeadTimeCenter.Stat) -> Double? {
        guard let p = s.precision, let b = c.baseRate, b > 0 else { return nil }
        return p / b
    }

    private var sorted: [LeadTimeCenter.Stat] {
        c.stats.sorted { a, b in
            switch sortBy {
            case 1: return (a.median ?? .infinity) < (b.median ?? .infinity)
            case 2: return (a.hitRate ?? -1) > (b.hitRate ?? -1)
            default: return (lift(a) ?? -1) > (lift(b) ?? -1)
            }
        }
    }

    private var conditionsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Sort by").font(.caption)
                Picker("", selection: $sortBy) { Text("Lift").tag(0); Text("Closest (median days)").tag(1); Text("Moves caught %").tag(2) }
                    .pickerStyle(.segmented).fixedSize().controlSize(.small)
                Spacer()
                Text("\(c.moves.count) moves").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Condition").frame(width: 300, alignment: .leading)
                        Text("Median days before").frame(width: 120, alignment: .trailing)
                        Text("Avg").frame(width: 60, alignment: .trailing)
                        Text("Moves caught").frame(width: 110, alignment: .trailing)
                        Text("Days true").frame(width: 80, alignment: .trailing)
                        Text("Precision").frame(width: 80, alignment: .trailing)
                        Text("Lift").frame(width: 60, alignment: .trailing)
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary).padding(.vertical, 4)
                    ForEach(sorted) { s in
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.cond.name).lineLimit(1)
                                Text(s.cond.kind).font(.caption2).foregroundStyle(.secondary)
                            }.frame(width: 300, alignment: .leading)
                            Text(s.median.map { String(format: "%.0f", $0) } ?? "—").bold().frame(width: 120, alignment: .trailing)
                            Text(s.mean.map { String(format: "%.1f", $0) } ?? "—").frame(width: 60, alignment: .trailing)
                            Text("\(s.caught)/\(s.events)" + (s.hitRate.map { String(format: " · %.0f%%", $0) } ?? "")).frame(width: 110, alignment: .trailing)
                            Text("\(s.fires)").foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            Text(s.precision.map { String(format: "%.1f%%", $0) } ?? "—").frame(width: 80, alignment: .trailing)
                            Text(lift(s).map { String(format: "%.2f×", $0) } ?? "—")
                                .foregroundStyle((lift(s) ?? 0) >= 1.5 ? Color.green : ((lift(s) ?? 1) < 1 ? Color.red : Color.primary))
                                .frame(width: 60, alignment: .trailing)
                        }
                        .font(.callout.monospacedDigit()).padding(.vertical, 3)
                        .background(picked == s.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { picked = s.id; tab = 1 }
                        Divider()
                    }
                }
            }
        }
    }

    /// Moves (rows) × conditions (columns): days before the move's start; "—" = not true within the look-back.
    private var matrix: some View {
        let cs = sorted.map(\.cond)
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(c.moves) { m in
                        HStack(spacing: 0) {
                            Text(m.sym).bold().frame(width: 110, alignment: .leading)
                            Text(m.start).frame(width: 92, alignment: .leading)
                            Text(String(format: "+%.0f%%", m.gain)).foregroundStyle(.green).frame(width: 56, alignment: .trailing)
                            ForEach(cs) { cond in
                                let v = c.dist[m.id]?[cond.id]
                                Text(v.map(String.init) ?? "—")
                                    .foregroundStyle(v == nil ? Color.secondary : (v! <= 5 ? Color.green : Color.primary))
                                    .frame(width: 70, alignment: .center)
                                    .background(picked == cond.id ? Color.accentColor.opacity(0.10) : Color.clear)
                            }
                        }
                        .font(.caption.monospacedDigit()).padding(.vertical, 2)
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("Stock").frame(width: 110, alignment: .leading)
                        Text("Move start").frame(width: 92, alignment: .leading)
                        Text("Gain").frame(width: 56, alignment: .trailing)
                        ForEach(cs) { cond in
                            Text(cond.name).lineLimit(2).font(.caption2.bold()).frame(width: 70, height: 30)
                                .help(cond.name).onTapGesture { picked = cond.id }
                        }
                    }
                    .padding(.vertical, 4).background(.bar)
                }
            }
        }
    }
}


/// Lead-time stats for per-day symbol lists (F Formula Counts): moves are found once for every stock in the sheet.
@MainActor struct LeadMath {
    struct Result { var median: Double?; var caught = 0; var events = 0; var precision: Double?; var lift: Double? }
    private struct Px { let ds: [String]; let starts: [Int]; let startSet: Set<Int> }
    private var px: [String: Px] = [:]
    private let first: String, last: String, within: Int
    private(set) var baseRate: Double?

    init(vm: ScreenerViewModel, days: [String], gain: Double, within: Int) {
        self.within = within
        first = days.first ?? ""; last = days.last ?? ""
        guard let label = vm.labelIndex else { return }
        var allDays = 0, allHit = 0
        for r in vm.table.rows {
            let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
            guard !sym.isEmpty, px[sym] == nil else { continue }
            let ds: [String], cl: [Double]
            if let p = vm.priceBook.series(for: sym), !p.days.isEmpty { (ds, cl) = (p.days, p.closes) }
            else if let x = DeliveryCenter.shared.book.series[sym], !x.days.isEmpty {
                let f = Del2.splitFactors(x.close); (ds, cl) = (x.days, zip(x.close, f).map { $0 * $1 })
            } else { continue }
            var starts: [Int] = [], i = 0
            while i < cl.count - 1 {
                if cl[i] > 0, ds[i] >= first {
                    let hi = cl[(i + 1)...min(cl.count - 1, i + within)].max() ?? 0
                    if hi / cl[i] - 1 >= gain / 100 { starts.append(i); i += within; continue }
                }
                i += 1
            }
            let set = Set(starts)
            px[sym] = Px(ds: ds, starts: starts, startSet: set)
            for (k, day) in ds.enumerated() where day >= first && day <= last && k + within < ds.count {
                allDays += 1
                if (k...(k + within)).contains(where: { set.contains($0) }) { allHit += 1 }
            }
        }
        baseRate = allDays > 0 ? Double(allHit) / Double(allDays) * 100 : nil
    }

    func stats(_ perDay: [String: [String]?], lookback: Int) -> Result {
        var trueOn: [String: Set<String>] = [:]
        for (d, syms) in perDay { for s in syms ?? [] { trueOn[s, default: []].insert(d) } }
        var r = Result(), dist: [Double] = [], fires = 0, hits = 0
        for (sym, p) in px {
            let set = trueOn[sym] ?? []
            for s0 in p.starts {
                r.events += 1
                guard !set.isEmpty else { continue }
                for back in 0...lookback where s0 - back >= 0 {
                    if set.contains(p.ds[s0 - back]) { dist.append(Double(back)); r.caught += 1; break }
                }
            }
            for day in set {
                guard let k = FSuccessMath.index(p.ds, day), p.ds[k] == day, k + within < p.ds.count else { continue }
                fires += 1
                if (k...(k + within)).contains(where: { p.startSet.contains($0) }) { hits += 1 }
            }
        }
        if !dist.isEmpty { let v = dist.sorted(); r.median = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2 }
        if fires > 0 { r.precision = Double(hits) / Double(fires) * 100 }
        if let p = r.precision, let b = baseRate, b > 0 { r.lift = p / b }
        return r
    }
}
