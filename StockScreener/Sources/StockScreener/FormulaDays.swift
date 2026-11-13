import SwiftUI
import Charts

// MARK: - Per-column condition counts (Filter header badges)

extension ScreenerViewModel {
    /// For each column with a condition in the Filter: how many of ALL stocks meet that column's condition(s) alone.
    /// Several conditions on one column are ANDed; formula conditions count under their own column (if set).
    func conditionCountsByColumn() -> [Int: Int] {
        var byColumn: [String: [FilterCondition]] = [:]
        func walk(_ g: FilterGroup) {
            guard g.isEnabled else { return }
            for c in g.conditions where c.isEnabled && !c.column.isEmpty { byColumn[c.column, default: []].append(c) }
            g.groups.forEach(walk)
        }
        walk(settings.filterGroup)
        var out: [Int: Int] = [:]
        for (col, conds) in byColumn {
            guard let i = table.index(of: col) else { continue }
            var issues: [String] = []
            guard let p = FilterCompiler.compile(FilterGroup(mode: .all, conditions: conds), table: table, issues: &issues) else { continue }
            out[i] = rows.reduce(0) { $0 + (p($1) ? 1 : 0) }
        }
        return out
    }
}

// MARK: - F formulas: how many stocks meet each one, day by day

struct FFormula: Identifiable, Hashable {
    var id: String { key }
    let name: String
    let source: String            // "Note · ABC (Aug 2026)", "Alert", "Combination"
    let group: FilterGroup
    var quick: String? = nil      // F text for editing (notes / my formulas)
    var mineID: UUID? = nil       // one of "My formulas" (edit in place)
    var alertID: UUID? = nil      // an F alert (edit updates the alert)
    var key: String { group.describe }
    static func == (a: FFormula, b: FFormula) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }
}

@MainActor final class FormulaDaysCenter: ObservableObject {
    static let shared = FormulaDaysCenter()
    /// formula key → day → matching symbols (nil = the day can't be judged: a column it uses wasn't stored)
    @Published private(set) var counts: [String: [String: [String]?]] = [:]
    @Published private(set) var days: [String] = []          // oldest → newest; the last one is today's live data
    @Published private(set) var running = false
    @Published private(set) var progress = 0.0
    private var cache: [String: [String]?] = [:]             // "day|formula" → symbols

    /// Formulas you typed or edited here (kept for good).
    struct Mine: Codable, Identifiable, Equatable { var id = UUID(); var name: String; var quick: String }
    @Published var mine: [Mine] = { (UserDefaults.standard.data(forKey: "fdays.mine")).flatMap { try? JSONDecoder().decode([Mine].self, from: $0) } ?? [] }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(mine), forKey: "fdays.mine") }
    }
    /// Rows you hid (formula keys).
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "fdays.hidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "fdays.hidden") }
    }
    static func group(_ quick: String, vm: ScreenerViewModel) -> FilterGroup? {
        guard let f = try? QuickF.formula(quick, headers: vm.headers) else { return nil }
        return FilterGroup(mode: .all, conditions: [FilterCondition(kind: .formula, formula: f)])
    }
    private var task: Task<Void, Never>?

    /// Every formula from F: note formulas, F alerts, saved F combinations (duplicates dropped).
    func formulas(_ vm: ScreenerViewModel, includeHidden: Bool = false) -> [FFormula] {
        var out: [FFormula] = [], seen = Set<String>()
        func add(_ f: FFormula) {
            guard f.group.activeCount > 0, includeHidden || !hidden.contains(f.key), seen.insert(f.key).inserted else { return }
            out.append(f)
        }
        for m in mine { if let g = Self.group(m.quick, vm: vm) { add(FFormula(name: m.name.isEmpty ? m.quick : m.name, source: "My formula · \(m.quick)", group: g, quick: m.quick, mineID: m.id)) } }
        for n in MBNoteStore.shared.notes.values.sorted(by: { $0.updated > $1.updated }) {
            let q = NoteAlerts.quick(n.text, headers: vm.headers)
            guard !q.isEmpty, let f = try? QuickF.formula(q, headers: vm.headers) else { continue }
            add(FFormula(name: q, source: "Note · \(n.symbol) \(n.month)",
                         group: FilterGroup(mode: .all, conditions: [FilterCondition(kind: .formula, formula: f)]), quick: q))
        }
        for r in NoteAlerts.rules(vm) {
            let q = String(r.name.dropFirst(NoteAlerts.prefix.count))
            add(FFormula(name: q, source: "F alert", group: r.filter, quick: q, alertID: r.id))
        }
        for c in MBFilterCenter.shared.combos { add(FFormula(name: c.name, source: "F combination", group: c.group)) }
        // the Filter's own conditions: the whole Filter, then each column's condition(s) alone
        let fg = vm.settings.filterGroup
        if fg.activeCount > 0 { add(FFormula(name: fg.describe, source: "Filter — all conditions", group: fg)) }
        var byColumn: [(String, [FilterCondition])] = []
        func walk(_ g: FilterGroup) {
            guard g.isEnabled else { return }
            for c in g.conditions where c.isEnabled {
                let k = c.column.isEmpty ? c.describe : c.column
                if let i = byColumn.firstIndex(where: { $0.0 == k }) { byColumn[i].1.append(c) } else { byColumn.append((k, [c])) }
            }
            g.groups.forEach(walk)
        }
        walk(fg)
        if byColumn.count > 1 || fg.groups.count > 0 {
            for (_, cs) in byColumn {
                let g = FilterGroup(mode: .all, conditions: cs)
                add(FFormula(name: g.describe, source: "Filter condition", group: g))
            }
        }
        return out
    }

    /// Extra conditions every formula must also meet ("Also require": e.g. Safety>2, and/or the Filter's conditions).
    var also: FilterGroup?

    /// The formula as counted: with "Also require" ANDed in.
    func effective(_ f: FFormula) -> FFormula {
        guard let a = also, a.activeCount > 0 else { return f }
        return FFormula(name: f.name, source: f.source, group: FilterGroup(mode: .all, groups: [f.group, a]), quick: f.quick)
    }

    func run(_ vm: ScreenerViewModel, lastDays: Int) {
        task?.cancel()
        let fs = formulas(vm).map { (orig: $0, eff: effective($0)) }
        guard let label = vm.labelIndex else { return }
        let liveKey = HistoryStore.dayKey(vm.dataDay(of: vm.table))
        let stored = Array(HistoryStore.days().filter { $0 < liveKey }.suffix(max(1, lastDays)))
        days = stored + [liveKey]
        running = true; progress = 0
        task = Task { @MainActor in
            var result: [String: [String: [String]?]] = [:]
            let current = vm.table
            for (k, d) in days.enumerated() {
                if Task.isCancelled { break }
                let isLive = d == liveKey && k == days.count - 1
                let todo = fs.filter { p in
                    if !isLive, let c = cache[d + "|" + p.eff.key] { result[p.orig.key, default: [:]][d] = .some(c); return false }
                    return true
                }
                if !todo.isEmpty {
                    var table: SheetTable? = isLive ? current : await Task.detached(priority: .userInitiated) {
                        HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) }
                    }.value
                    if !isLive, let tt = table {
                        let del = tt.headers.filter { ScreenerViewModel.isDeliveryColumn($0) }
                        if todo.contains(where: { p in del.contains { p.eff.key.contains($0) } }) { table = vm.withDeliveryValues(tt, asOf: d) }
                    }
                    for p in todo {
                        guard let t = table else { result[p.orig.key, default: [:]][d] = .some(nil); continue }
                        let r = Self.evaluate(p.eff, table: t, label: label)
                        if !isLive { cache[d + "|" + p.eff.key] = .some(r) }
                        result[p.orig.key, default: [:]][d] = .some(r)
                    }
                }
                progress = Double(k + 1) / Double(days.count)
                if k % 3 == 0 { counts = result; await Task.yield() }
            }
            counts = result
            running = false
        }
    }

    /// Symbols meeting the formula in `t`; nil when a column it uses has no values that day.
    static func evaluate(_ f: FFormula, table t: SheetTable, label: Int) -> [String]? {
        let used = t.headers.indices.filter { i in f.key.contains(t.headers[i]) && t.headers[i].count > 1 }
        for i in used where !t.rows.contains(where: { $0.number(i) != nil || !$0.text(i).isEmpty }) { return nil }
        var issues: [String] = []
        guard let p = FilterCompiler.compile(f.group, table: t, issues: &issues) else { return nil }
        return t.rows.filter(p).map { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() }
    }
}

struct FormulaDaysView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = FormulaDaysCenter.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("fdays.last") private var lastDays = 60
    @AppStorage("fdays.horizon") private var horizon = 30
    @AppStorage("fdays.mode") private var mode = 0                 // 0 = stocks count, 1 = change %
    @AppStorage("fdays.sort") private var sortBy = 0               // 0 = as listed, 1 = avg %, 2 = win %
    @State private var success: [String: FSuccess] = [:]
    @State private var editing: FFormula?
    @State private var newFormula = false
    @State private var showHidden = false
    @AppStorage("fdays.alsoText") private var alsoText = ""
    @AppStorage("fdays.alsoFilter") private var alsoFilter = false
    @State private var alsoError: String?
    @State private var analysing: FFormula?
    @State private var selected: String?
    @State private var cell: (formula: String, day: String)?
    @State private var showCell = false

    var body: some View {
        let fs = c.formulas(vm, includeHidden: showHidden)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("F formulas & Filter conditions — stocks meeting each one, and how they did").font(.title3.bold())
                Spacer()
                Text("Look back")
                TextField("", value: $lastDays, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                Stepper("", value: $lastDays, in: 1...1000, step: 10).labelsHidden()
                Text("days")
                if c.running { ProgressView(value: c.progress).frame(width: 100) }
                Button { newFormula = true } label: { Label("New formula", systemImage: "plus") }
                    .popover(isPresented: $newFormula) { FormulaEditor(start: nil) { recount() }.environmentObject(vm) }
                Button { c.run(vm, lastDays: lastDays) } label: { Label("Recount", systemImage: "arrow.clockwise") }.disabled(c.running)
            }
            HStack(spacing: 10) {
                Picker("", selection: $mode) { Text("Stocks count").tag(0); Text("Change %").tag(1) }.pickerStyle(.segmented).fixedSize()
                Text("Success = % change after")
                TextField("", value: $horizon, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                Stepper("", value: $horizon, in: 1...500).labelsHidden()
                Text("trading days")
                Menu("Presets") { ForEach([5, 10, 22, 30, 60, 90, 120, 250], id: \.self) { d in Button("\(d) days") { horizon = d } } }.fixedSize()
                Spacer()
                Picker("Sort", selection: $sortBy) { Text("As listed").tag(0); Text("Avg %").tag(1); Text("Win %").tag(2); Text("Signals").tag(3) }.fixedSize()
            }
            Text("Formulas come from your F notes (the recognised chips), F alerts and saved F combinations. Each cell = how many stocks met the formula on that stored day; the last column is today's live data. — = a column the formula uses wasn't stored that day. Click a number for the stocks.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(alsoActive ? Color.orange : Color.secondary)
                Text("Also require")
                TextField("e.g. Safety>2 + DLVR>40  (any Filter columns)", text: $alsoText).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    .onSubmit { applyAlso() }
                Toggle("and the Filter's conditions", isOn: $alsoFilter).toggleStyle(.checkbox)
                Button("Apply") { applyAlso() }
                if alsoActive { Button("Clear") { alsoText = ""; alsoFilter = false; applyAlso() } }
            }
            .help("Every formula below is counted only for stocks that also meet these — counts, success and the stock lists all change")
            if let alsoError { Text(alsoError).font(.caption).foregroundStyle(.red) }
            if !c.hidden.isEmpty {
                Button(showHidden ? "Hide hidden rows" : "Show \(c.hidden.count) hidden row\(c.hidden.count == 1 ? "" : "s")") { showHidden.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            if fs.isEmpty {
                Text("No formulas yet — write a note in F (count=5 + DELSMA>70 …), make an F alert, or save an F combination.").foregroundStyle(.secondary)
                Spacer()
            } else {
                if let s = selected ?? fs.first?.key { chart(s, name: fs.first { $0.key == s }?.name ?? "") }
                grid(sorted(fs))
            }
        }
        .padding(16)
        .onAppear { if c.counts.isEmpty && !c.running { applyAlso() } }
        .onChange(of: vm.settings.filterGroup) { _ in if alsoFilter { applyAlso() } }
        .sheet(item: $analysing) { f in GainerAnalysisView(formula: f, horizon: max(1, horizon)).environmentObject(vm) }
        .sheet(item: $editing) { f in FormulaEditor(start: f) { recount() }.environmentObject(vm) }
        .onChange(of: lastDays) { _ in c.run(vm, lastDays: max(1, lastDays)) }
        .task(id: "\(c.counts.count)|\(c.running)|\(horizon)|\(c.days.count)") {
            guard !c.running else { return }
            var out: [String: FSuccess] = [:]
            for f in c.formulas(vm) {
                out[f.key] = FSuccessMath.compute(c.counts[f.key] ?? [:], horizon: max(1, horizon), vm: vm)
                await Task.yield()
            }
            success = out
        }
        .sheet(isPresented: $showCell) { cellPopover }
    }

    private func chart(_ key: String, name: String) -> some View {
        let pts: [(String, Int)] = c.days.compactMap { d in c.counts[key]?[d].flatMap { $0 }.map { (d, $0.count) } }
        return VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.callout.monospaced()).lineLimit(1)
            Chart(pts, id: \.0) { p in
                BarMark(x: .value("Day", String(p.0.suffix(5))), y: .value("Stocks", p.1))
                    .foregroundStyle(p.0 == c.days.last ? Color.orange : Color.accentColor)
                    .annotation(position: .top) { Text("\(p.1)").font(.system(size: 8)).foregroundStyle(.secondary) }
            }
            .frame(height: 130)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { loc in
                            let x = loc.x - geo[proxy.plotAreaFrame].origin.x
                            guard let label: String = proxy.value(atX: x),
                                  let day = pts.map(\.0).last(where: { $0.hasSuffix(label) }) else { return }
                            cell = (key, day); showCell = true
                        }
                        .help("Click a bar for that day's stocks and how they did")
                }
            }
        }
    }

    private func recount() { c.run(vm, lastDays: max(1, lastDays)) }

    private var alsoActive: Bool { !alsoText.trimmingCharacters(in: .whitespaces).isEmpty || alsoFilter }

    private func applyAlso() {
        var groups: [FilterGroup] = []
        alsoError = nil
        let t = alsoText.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            if let g = FormulaDaysCenter.group(t, vm: vm) { groups.append(g) }
            else { alsoError = "Also require: " + ((try? QuickF.formula(t, headers: vm.headers)).map { _ in "" } ?? "check the column names / syntax") }
        }
        if alsoFilter, vm.settings.filterGroup.activeCount > 0 { groups.append(vm.settings.filterGroup) }
        c.also = groups.isEmpty ? nil : FilterGroup(mode: .all, groups: groups)
        recount()
    }

    private func sorted(_ fs: [FFormula]) -> [FFormula] {
        switch sortBy {
        case 1: return fs.sorted { (success[$0.key]?.avg ?? -9) > (success[$1.key]?.avg ?? -9) }
        case 2: return fs.sorted { (success[$0.key]?.win ?? -9) > (success[$1.key]?.win ?? -9) }
        case 3: return fs.sorted { (success[$0.key]?.signals ?? 0) > (success[$1.key]?.signals ?? 0) }
        default: return fs
        }
    }

    private func grid(_ fs: [FFormula]) -> some View {
        let days = Array(c.days.reversed())                   // newest first
        return ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("Formula").font(.caption.bold()).frame(width: 320, alignment: .leading).padding(4)
                    Text("Signals").font(.caption2.bold()).frame(width: 52)
                    Text("Avg \(horizon)d").font(.caption2.bold()).frame(width: 58)
                    Text("Median").font(.caption2.bold()).frame(width: 54)
                    Text("Up").font(.caption2.bold()).frame(width: 40)
                    Text("Best").font(.caption2.bold()).frame(width: 54)
                    Text("Worst").font(.caption2.bold()).frame(width: 54)
                    ForEach(days, id: \.self) { d in
                        Text(d == c.days.last ? "Today" : String(d.suffix(5))).font(.caption2.bold()).frame(width: 46).padding(.vertical, 4)
                    }
                }
                Divider()
                ForEach(fs) { f in
                    let row = c.counts[f.key] ?? [:]
                    let maxV = max(1, row.values.compactMap { $0?.count }.max() ?? 1)
                    GridRow {
                        Button { selected = f.key } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.caption.monospaced()).lineLimit(1)
                                Text(f.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 320, alignment: .leading).padding(4)
                            .background(selected == f.key ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit…") { editing = f }
                            Button("Analyse max gainers → suggest a better formula…") { analysing = f }
                            Button("Duplicate as my formula") {
                                c.mine.append(.init(name: "", quick: f.quick ?? f.name)); recount()
                            }.disabled(f.quick == nil)
                            if let id = f.mineID { Button("Delete", role: .destructive) { c.mine.removeAll { $0.id == id } } }
                            Button(c.hidden.contains(f.key) ? "Show this row" : "Hide this row") {
                                if c.hidden.contains(f.key) { c.hidden.remove(f.key) } else { c.hidden.insert(f.key) }
                            }
                        }
                        .overlay(alignment: .trailing) {
                            HStack(spacing: 8) {
                                Button { analysing = f } label: { Image(systemName: "wand.and.stars") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .help("What do this formula's biggest gainers have in common? Suggests a sharper formula")
                                Button { editing = f } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .help("Edit this formula (right-click for more)")
                            }.padding(.trailing, 6)
                        }
                        let st = success[f.key]
                        Text("\(st?.signals ?? 0)").font(.caption.monospacedDigit()).frame(width: 52)
                            .help("\(st?.signals ?? 0) stock-days with prices after them · \(st?.full ?? 0) have the full \(horizon) days (the rest are measured to the latest close)")
                        Text(FSuccessMath.pct(st?.avg)).font(.caption.monospacedDigit().bold()).foregroundStyle(FSuccessMath.color(st?.avg)).frame(width: 58)
                        Text(FSuccessMath.pct(st?.median)).font(.caption.monospacedDigit()).foregroundStyle(FSuccessMath.color(st?.median)).frame(width: 54)
                        Text(st?.win.map { String(format: "%.0f%%", $0 * 100) } ?? "—").font(.caption.monospacedDigit()).frame(width: 40)
                        Text(FSuccessMath.pct(st?.best)).font(.caption.monospacedDigit()).foregroundStyle(.green).frame(width: 54)
                        Text(FSuccessMath.pct(st?.worst)).font(.caption.monospacedDigit()).foregroundStyle(.red).frame(width: 54)
                        ForEach(days, id: \.self) { d in
                            let v = row[d]
                            Group {
                                if mode == 1, let v, let syms = v, !syms.isEmpty {
                                    let a = st?.byDay[d]
                                    Button(a.map { String(format: "%+.0f", $0 * 100) } ?? "…") { cell = (f.key, d); showCell = true }
                                        .buttonStyle(.plain).font(.caption.monospacedDigit())
                                        .foregroundStyle(FSuccessMath.color(a))
                                        .frame(width: 46, height: 26)
                                        .background(FSuccessMath.color(a).opacity(a == nil ? 0 : min(0.45, 0.08 + abs(a!) * 1.5)))
                                        .help(a == nil ? "\(syms.count) stocks — no prices after this day yet" : "\(syms.count) stocks · average \(FSuccessMath.pct(a)) after \(horizon) days (or to the latest close)")
                                } else if let v, let syms = v {
                                    Button("\(syms.count)") { cell = (f.key, d); showCell = true }
                                        .buttonStyle(.plain).font(.caption.monospacedDigit())
                                        .frame(width: 46, height: 26)
                                        .background(Color.green.opacity(syms.isEmpty ? 0 : 0.08 + 0.42 * Double(syms.count) / Double(maxV)))
                                } else if v != nil {
                                    Text("—").font(.caption).foregroundStyle(.tertiary).frame(width: 46, height: 26)
                                } else {
                                    Text("").frame(width: 46, height: 26)
                                }
                            }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    /// " +12%" — that stock's change `horizon` trading days after `day` (or to the latest close).
    private func changeText(_ sym: String, from day: String) -> String {
        let v: ([String], [Double])? = vm.priceBook.series(for: sym).map { ($0.days, $0.closes) }
            ?? DeliveryCenter.shared.book.series[sym].map { ($0.days, $0.close) }
        guard let (days, closes) = v, let i = FSuccessMath.index(days, day), i < closes.count - 1, closes[i] > 0 else { return "" }
        let r = closes[min(i + max(1, horizon), closes.count - 1)] / closes[i] - 1
        return String(format: " %+.0f%%", r * 100)
    }

    @ViewBuilder private var cellPopover: some View {
        if let cell, let syms = c.counts[cell.formula]?[cell.day] ?? nil {
            DayStocksView(day: cell.day, isToday: cell.day == c.days.last, formula: FormulaDaysCenter.shared.formulas(vm).first { $0.key == cell.formula }?.name ?? "",
                          symbols: syms, close: { showCell = false })
                .environmentObject(vm)
        }
    }
}


// MARK: - Success: % change after a signal

struct FSuccess {
    var signals = 0               // stock-days that met the formula (with at least 1 day after)
    var full = 0                  // of those, with the whole horizon after them
    var avg: Double?              // average % change after `horizon` trading days (or to the latest close)
    var median: Double?
    var win: Double?              // share that were up
    var best: Double?             // average best close within the horizon
    var worst: Double?            // average worst close within the horizon
    var byDay: [String: Double] = [:]
}

enum FSuccessMath {
    /// Day index of the first trading day on/after `day` (binary search).
    static func index(_ days: [String], _ day: String) -> Int? {
        var lo = 0, hi = days.count
        while lo < hi { let m = (lo + hi) / 2; if days[m] < day { lo = m + 1 } else { hi = m } }
        return lo < days.count ? lo : nil
    }

    @MainActor static func compute(_ perDay: [String: [String]?], horizon: Int, vm: ScreenerViewModel) -> FSuccess {
        var r = FSuccess()
        var rets: [Double] = [], bests: [Double] = [], worsts: [Double] = []
        var series: [String: ([String], [Double])] = [:]
        func s(_ sym: String) -> ([String], [Double])? {
            if let x = series[sym] { return x.0.isEmpty ? nil : x }
            var v: ([String], [Double]) = ([], [])
            if let p = vm.priceBook.series(for: sym), !p.days.isEmpty { v = (p.days, p.closes) }
            else if let d = DeliveryCenter.shared.book.series[sym], !d.days.isEmpty { v = (d.days, d.close) }
            series[sym] = v
            return v.0.isEmpty ? nil : v
        }
        for (day, syms) in perDay {
            guard let syms, !syms.isEmpty else { continue }
            var dayRets: [Double] = []
            for sym in syms {
                guard let (days, closes) = s(sym), let i = index(days, day), i < closes.count - 1, closes[i] > 0 else { continue }
                let j = min(i + horizon, closes.count - 1)
                let base = closes[i]
                let ret = closes[j] / base - 1
                let win = closes[(i + 1)...j]
                rets.append(ret); dayRets.append(ret)
                bests.append((win.max() ?? base) / base - 1)
                worsts.append((win.min() ?? base) / base - 1)
                r.signals += 1
                if i + horizon <= closes.count - 1 { r.full += 1 }
            }
            if !dayRets.isEmpty { r.byDay[day] = dayRets.reduce(0, +) / Double(dayRets.count) }
        }
        guard !rets.isEmpty else { return r }
        let n = Double(rets.count)
        r.avg = rets.reduce(0, +) / n
        let sorted = rets.sorted(); r.median = sorted[sorted.count / 2]
        r.win = Double(rets.filter { $0 > 0 }.count) / n
        r.best = bests.reduce(0, +) / n
        r.worst = worsts.reduce(0, +) / n
        return r
    }

    static func pct(_ v: Double?) -> String { v.map { String(format: "%+.1f%%", $0 * 100) } ?? "—" }
    static func color(_ v: Double?) -> Color { guard let v else { return .secondary }; return v > 0 ? .green : (v < 0 ? .red : .secondary) }
}


// MARK: - One day's stocks and how they did after (5d, 15d, 30d, till date)

struct DayStocksView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    let day: String
    let isToday: Bool
    let formula: String
    let symbols: [String]
    let close: () -> Void
    @State private var sortKey = "Till date"
    @State private var rows: [Row] = []

    struct Row: Identifiable {
        var id: String { symbol }
        let symbol: String
        var price: Double?
        var r5: Double?, r15: Double?, r30: Double?, now: Double?, best: Double?, worst: Double?
        var bars = 0
    }
    private static let cols = ["5d", "15d", "30d", "Till date", "Best", "Worst"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(symbols.count) stocks · \(isToday ? "today" : day)").font(.title3.bold())
                    Text(formula).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                AddToWatchlistButton(groups: [("These stocks", symbols.sorted())], source: "F formula \(day)")
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            // averages
            HStack(spacing: 18) {
                ForEach(Self.cols, id: \.self) { k in
                    let v = avg(k)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Avg \(k)").font(.caption2).foregroundStyle(.secondary)
                        Text(FSuccessMath.pct(v.avg)).font(.callout.monospacedDigit().bold()).foregroundStyle(FSuccessMath.color(v.avg))
                        Text(v.n == 0 ? "no data yet" : "\(v.up)/\(v.n) up").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack(spacing: 0) {
                header("Symbol", 130, align: .leading)
                header("Close", 80)
                ForEach(Self.cols, id: \.self) { header($0, 72) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sorted) { r in
                        HStack(spacing: 0) {
                            Button(r.symbol) { vm.openChart(r.symbol, queue: sorted.map(\.symbol), goTo: isToday ? nil : day, openWindow: openWindow) }
                                .buttonStyle(.link).font(.callout.monospaced()).frame(width: 130, alignment: .leading)
                            Text(r.price.map { String(format: "%.2f", $0) } ?? "—").frame(width: 80, alignment: .trailing)
                            cellText(r.r5); cellText(r.r15); cellText(r.r30); cellText(r.now); cellText(r.best); cellText(r.worst)
                        }
                        .font(.callout.monospacedDigit())
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
            Text("% from the close on \(isToday ? "today" : day) (Yahoo closes, else NSE) to the close 5 / 15 / 30 trading days later and to the latest close. Best / Worst = highest / lowest close since. — = not that many trading days yet.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 760, height: 560)
        .onAppear { rows = symbols.map(compute) }
    }

    private func header(_ k: String, _ w: CGFloat, align: Alignment = .trailing) -> some View {
        Button { sortKey = k } label: {
            Text(k + (sortKey == k ? " ▼" : "")).font(.caption.bold()).frame(width: w, alignment: align)
        }.buttonStyle(.plain).foregroundStyle(sortKey == k ? Color.accentColor : Color.secondary)
    }

    private func cellText(_ v: Double?) -> some View {
        Text(FSuccessMath.pct(v)).frame(width: 72, alignment: .trailing).foregroundStyle(FSuccessMath.color(v))
    }

    private func value(_ r: Row, _ k: String) -> Double? {
        switch k { case "5d": return r.r5; case "15d": return r.r15; case "30d": return r.r30; case "Best": return r.best; case "Worst": return r.worst
                   case "Close": return r.price; default: return r.now }
    }

    private var sorted: [Row] {
        if sortKey == "Symbol" { return rows.sorted { $0.symbol < $1.symbol } }
        return rows.sorted { (value($0, sortKey) ?? -.infinity) > (value($1, sortKey) ?? -.infinity) }
    }

    private func avg(_ k: String) -> (avg: Double?, n: Int, up: Int) {
        let v = rows.compactMap { value($0, k) }
        return (v.isEmpty ? nil : v.reduce(0, +) / Double(v.count), v.count, v.filter { $0 > 0 }.count)
    }

    private func compute(_ sym: String) -> Row {
        var r = Row(symbol: sym)
        let v: ([String], [Double])? = vm.priceBook.series(for: sym).map { ($0.days, $0.closes) }
            ?? DeliveryCenter.shared.book.series[sym].map { ($0.days, $0.close) }
        guard let (days, closes) = v, !closes.isEmpty else { return r }
        let i: Int
        if isToday { i = closes.count - 1 } else { guard let x = FSuccessMath.index(days, day) else { return r }; i = x }
        guard i < closes.count, closes[i] > 0 else { return r }
        let base = closes[i]
        r.price = base
        func after(_ k: Int) -> Double? { i + k < closes.count ? closes[i + k] / base - 1 : nil }
        r.r5 = after(5); r.r15 = after(15); r.r30 = after(30)
        r.bars = closes.count - 1 - i
        if r.bars > 0 {
            r.now = closes[closes.count - 1] / base - 1
            let rest = closes[(i + 1)...]
            r.best = rest.max().map { $0 / base - 1 }
            r.worst = rest.min().map { $0 / base - 1 }
        }
        return r
    }
}


// MARK: - Editing a formula

/// Edit an F formula. My formulas change in place; F alerts update the alert; note / combination / Filter rows
/// are saved as a new "My formula" (the note itself is left as you wrote it).
struct FormulaEditor: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = FormulaDaysCenter.shared
    @Environment(\.dismiss) private var dismiss
    let start: FFormula?
    let saved: () -> Void
    @State private var name = ""
    @State private var quick = ""
    @State private var error: String?
    @State private var now: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(start == nil ? "New formula" : "Edit formula").font(.headline)
            if let s = start { Text(s.source).font(.caption).foregroundStyle(.secondary) }
            TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder)
            TextField("count=5 + DELSMA>90 + C/DL2C>1", text: $quick, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(.body.monospaced()).lineLimit(2...6)
            Text("+ = AND · | = OR · NOT col · col>5, col=1, col<0.9 … column names as in the Filter").font(.caption2).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            else if let now { Text("\(now) stocks meet it today").font(.caption).foregroundStyle(.green) }
            HStack {
                if start?.mineID == nil, start != nil { Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(start?.mineID != nil || start?.alertID != nil || start == nil ? "Save" : "Save as my formula") { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(error != nil || quick.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 520)
        .onAppear {
            quick = start?.quick ?? start?.name ?? ""
            if let id = start?.mineID { name = c.mine.first { $0.id == id }?.name ?? "" }
        }
        .task(id: quick) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            do {
                let f = try QuickF.formula(quick, headers: vm.headers)
                error = nil; now = NoteAlerts.matches(f, vm: vm).count
            } catch { self.error = (error as? FormulaError)?.message ?? error.localizedDescription; now = nil }
        }
    }

    private var note: String {
        if start?.alertID != nil { return "" }
        return "Saved as a new row under My formulas — the original note / combination stays as it is."
    }

    private func save() {
        let q = quick.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = start?.mineID, let i = c.mine.firstIndex(where: { $0.id == id }) {
            c.mine[i].quick = q; c.mine[i].name = name
        } else if let aid = start?.alertID, let i = vm.settings.buyTriggers.firstIndex(where: { $0.id == aid }),
                  let f = try? QuickF.formula(q, headers: vm.headers) {
            vm.settings.buyTriggers[i].name = NoteAlerts.prefix + q
            vm.settings.buyTriggers[i].filter = FilterGroup(mode: .all, conditions: [FilterCondition(kind: .formula, formula: f)])
        } else {
            c.mine.insert(.init(name: name, quick: q), at: 0)
            if let s = start, s.mineID == nil, s.alertID == nil, s.quick != nil { c.hidden.insert(s.key) }   // the edited copy replaces the note's row
        }
        saved()
        dismiss()
    }
}
