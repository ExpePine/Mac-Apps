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
            guard let p = FilterEngine.compile(FilterGroup(mode: .all, conditions: conds), table: table, issues: &issues) else { continue }
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
    private var task: Task<Void, Never>?

    /// Every formula from F: note formulas, F alerts, saved F combinations (duplicates dropped).
    func formulas(_ vm: ScreenerViewModel) -> [FFormula] {
        var out: [FFormula] = [], seen = Set<String>()
        func add(_ f: FFormula) { if f.group.activeCount > 0, seen.insert(f.key).inserted { out.append(f) } }
        for n in MBNoteStore.shared.notes.values.sorted(by: { $0.updated > $1.updated }) {
            let q = NoteAlerts.quick(n.text, headers: vm.headers)
            guard !q.isEmpty, let f = try? QuickF.formula(q, headers: vm.headers) else { continue }
            add(FFormula(name: q, source: "Note · \(n.symbol) \(n.month)",
                         group: FilterGroup(mode: .all, conditions: [FilterCondition(kind: .formula, formula: f)])))
        }
        for r in NoteAlerts.rules(vm) { add(FFormula(name: String(r.name.dropFirst(NoteAlerts.prefix.count)), source: "F alert", group: r.filter)) }
        for c in MBFilterCenter.shared.combos { add(FFormula(name: c.name, source: "F combination", group: c.group)) }
        return out
    }

    func run(_ vm: ScreenerViewModel, lastDays: Int) {
        task?.cancel()
        let fs = formulas(vm)
        guard let label = vm.labelIndex else { return }
        let liveKey = HistoryStore.dayKey(vm.dataDay(of: vm.table))
        let stored = Array(HistoryStore.days().filter { $0 < liveKey }.suffix(max(1, lastDays)))
        days = stored + [liveKey]
        running = true; progress = 0
        task = Task {
            var result: [String: [String: [String]?]] = [:]
            let current = vm.table
            for (k, d) in days.enumerated() {
                if Task.isCancelled { break }
                let isLive = d == liveKey && k == days.count - 1
                var table: SheetTable?
                func ensureTable() async -> SheetTable? {
                    if let table { return table }
                    if isLive { table = current; return table }
                    var t = await Task.detached(priority: .userInitiated) { HistoryStore.load(d).flatMap { ScreenerViewModel.align($0, to: current) } }.value
                    if let tt = t, tt.headers.contains(where: { ScreenerViewModel.isDeliveryColumn($0) }),
                       fs.contains(where: { f in tt.headers.contains { ScreenerViewModel.isDeliveryColumn($0) && f.key.contains($0) } }) {
                        t = vm.withDeliveryValues(tt, asOf: d)
                    }
                    table = t; return t
                }
                for f in fs {
                    let ck = d + "|" + f.key
                    if !isLive, let c = cache[ck] { result[f.key, default: [:]][d] = c; continue }
                    guard let t = await ensureTable() else { result[f.key, default: [:]][d] = .some(nil); continue }
                    let r = Self.evaluate(f, table: t, label: label)
                    if !isLive { cache[ck] = r }
                    result[f.key, default: [:]][d] = r
                }
                progress = Double(k + 1) / Double(days.count)
                if k % 3 == 0 { counts = result; await Task.yield() }
            }
            counts = result
            running = false
        }
    }

    /// Symbols meeting the formula in `t`; nil when a column it uses has no values that day.
    private static func evaluate(_ f: FFormula, table t: SheetTable, label: Int) -> [String]? {
        let used = t.headers.indices.filter { i in f.key.contains(t.headers[i]) && t.headers[i].count > 1 }
        for i in used where !t.rows.contains(where: { $0.number(i) != nil || !$0.text(i).isEmpty }) { return nil }
        var issues: [String] = []
        guard let p = FilterEngine.compile(f.group, table: t, issues: &issues) else { return nil }
        return t.rows.filter(p).map { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() }
    }
}

struct FormulaDaysView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = FormulaDaysCenter.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("fdays.last") private var lastDays = 20
    @State private var selected: String?
    @State private var cell: (formula: String, day: String)?
    @State private var showCell = false

    var body: some View {
        let fs = c.formulas(vm)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("F formulas — stocks meeting each one, day by day").font(.title3.bold())
                Spacer()
                Picker("Days", selection: $lastDays) { ForEach([10, 20, 40, 60, 120, 250], id: \.self) { Text("\($0) days").tag($0) } }.fixedSize()
                if c.running { ProgressView(value: c.progress).frame(width: 100) }
                Button { c.run(vm, lastDays: lastDays) } label: { Label("Recount", systemImage: "arrow.clockwise") }.disabled(c.running)
            }
            Text("Formulas come from your F notes (the recognised chips), F alerts and saved F combinations. Each cell = how many stocks met the formula on that stored day; the last column is today's live data. — = a column the formula uses wasn't stored that day. Click a number for the stocks.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if fs.isEmpty {
                Text("No formulas yet — write a note in F (count=5 + DELSMA>70 …), make an F alert, or save an F combination.").foregroundStyle(.secondary)
                Spacer()
            } else {
                if let s = selected ?? fs.first?.key { chart(s, name: fs.first { $0.key == s }?.name ?? "") }
                grid(fs)
            }
        }
        .padding(16)
        .onAppear { if c.counts.isEmpty && !c.running { c.run(vm, lastDays: lastDays) } }
        .onChange(of: lastDays) { _ in c.run(vm, lastDays: lastDays) }
        .popover(isPresented: $showCell) { cellPopover }
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
        }
    }

    private func grid(_ fs: [FFormula]) -> some View {
        let days = Array(c.days.reversed())                   // newest first
        return ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("Formula").font(.caption.bold()).frame(width: 320, alignment: .leading).padding(4)
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
                        ForEach(days, id: \.self) { d in
                            let v = row[d]
                            Group {
                                if let v, let syms = v {
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

    @ViewBuilder private var cellPopover: some View {
        if let cell, let syms = c.counts[cell.formula]?[cell.day] ?? nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(syms.count) stocks · \(cell.day == c.days.last ? "today" : cell.day)").font(.headline)
                ScrollView {
                    FlowLayout(spacing: 4, lineSpacing: 3) {
                        ForEach(syms.sorted(), id: \.self) { s in
                            Button(s) { vm.openChart(s, queue: syms.sorted(), goTo: cell.day == c.days.last ? nil : cell.day, openWindow: openWindow) }
                                .buttonStyle(.plain).font(.caption.monospaced())
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.green.opacity(0.15)))
                        }
                    }
                }.frame(maxHeight: 220)
                if !syms.isEmpty {
                    AddToWatchlistButton(groups: [("These stocks", syms.sorted())], source: "F formula")
                }
            }
            .padding(12).frame(width: 360)
        }
    }
}
