import SwiftUI

// MARK: - Saved F combinations (multibaggers)

struct MBComboResult: Codable, Equatable {
    var caught: Int          // multibaggers matched on their pre-move day
    var judged: Int          // multibaggers that had a stored pre-move day
    var matches: Int         // all stocks matched on those days
    var ranAt: Date

    var caughtPct: Double { judged > 0 ? Double(caught) / Double(judged) * 100 : 0 }
    var hitRate: Double { matches > 0 ? Double(caught) / Double(matches) * 100 : 0 }
    var text: String {
        "\(caught)/\(judged) caught (\(String(format: "%.0f", caughtPct))%) · hit rate \(String(format: "%.1f", hitRate))% of \(matches) matches"
    }
}

struct MBCombo: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var group: FilterGroup
    var note = ""
    var created = Date()
    var result: MBComboResult?

    private static var url: URL { AppFolders.base.appendingPathComponent("mb_combos.json") }
    static func loadAll() -> [MBCombo] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([MBCombo].self, from: $0) } ?? []
    }
    static func saveAll(_ c: [MBCombo]) {
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: url, options: .atomic) }
    }
}

extension FilterCondition {
    var describe: String {
        if kind == .formula { return formula.isEmpty ? "(formula)" : formula }
        var s = "\(column.isEmpty ? "?" : column) \(op.rawValue)"
        guard op.needsValue else { return s }
        if target == .column, op.allowsColumnTarget {
            s += " \(otherColumn)" + (factor == "1" || factor.isEmpty ? "" : " × \(factor)")
        } else {
            s += " \(value)" + (op.needsSecondValue ? " and \(value2)" : "")
        }
        return s
    }
}

extension FilterGroup {
    /// e.g. "STREAK ≥ 5 AND t3Color = 1 AND (MOR > 90 OR DAY > 90)"
    var describe: String {
        let joiner = mode == .any ? " OR " : " AND "
        var parts = conditions.filter(\.isEnabled).map(\.describe)
        parts += groups.filter { $0.isEnabled && $0.activeCount > 0 }.map { "(\($0.describe))" }
        return parts.isEmpty ? "no conditions" : parts.joined(separator: joiner)
    }
}

extension MBFilterCenter {
    /// Multibaggers in the scope picked in the Multibaggers window (all months).
    static func scopedEvents(vm: ScreenerViewModel) -> [MBEvent] {
        var e = MultibaggerCenter.shared.events
        let scope = UserDefaults.standard.string(forKey: "mb.scope") ?? "Sheet stocks"
        if scope == "Sheet stocks" { let s = Set(vm.allSymbols.map { $0.uppercased() }); e = e.filter { s.contains($0.symbol) } }
        if scope == "My Filter", let l = vm.labelIndex {
            let s = Set(vm.filterRows.map { $0.text(l).trimmingCharacters(in: .whitespaces).uppercased() }); e = e.filter { s.contains($0.symbol) }
        }
        return e
    }

    var activeName: String? { activeCombo.flatMap { id in combos.first { $0.id == id }?.name } }
    var isDirty: Bool {
        guard let id = activeCombo, let c = combos.first(where: { $0.id == id }) else { return group.activeCount > 0 }
        return c.group != group
    }

    func saveAsNew(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        let c = MBCombo(name: n.isEmpty ? "Combination \(combos.count + 1)" : n, group: group, result: nil)
        combos.insert(c, at: 0)
        activeCombo = c.id
    }

    func updateActive() {
        guard let id = activeCombo, let i = combos.firstIndex(where: { $0.id == id }) else { return }
        if combos[i].group != group { combos[i].result = nil }
        combos[i].group = group
    }

    func load(_ c: MBCombo) { group = c.group; activeCombo = c.id }

    func newCombo() { group = FilterGroup(mode: .all); activeCombo = nil }

    func duplicate(_ c: MBCombo) {
        var d = c; d.id = UUID(); d.name = c.name + " copy"; d.created = Date(); d.result = nil
        combos.insert(d, at: 0)
    }

    func delete(_ c: MBCombo) {
        combos.removeAll { $0.id == c.id }
        if activeCombo == c.id { activeCombo = nil }
    }

    /// Adds "column op value" to the combination (replacing an existing condition on the same column and operator).
    func add(column: String, op: RuleOperator, value: String) {
        if let i = group.conditions.firstIndex(where: { $0.kind == .compare && $0.column == column && $0.op == op && $0.target == .value }) {
            group.conditions[i].value = value; group.conditions[i].isEnabled = true
        } else {
            group.conditions.append(FilterCondition(column: column, op: op, value: value))
        }
    }

    func contains(column: String) -> Bool { group.conditions.contains { $0.isEnabled && $0.column == column } }

    /// The stock's Filter-column values on the stored day the F check uses for this move (the last stored
    /// day on or before the base day). Falls back to today's values when no such day is stored.
    nonisolated static func preMoveValues(_ e: MBEvent, current: SheetTable, label: Int) async -> (day: String, today: Bool, values: [String: String]) {
        await Task.detached(priority: .userInitiated) { () -> (String, Bool, [String: String]) in
            func values(_ t: SheetTable) -> [String: String]? {
                guard let r = t.rows.first(where: { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() == e.symbol }) else { return nil }
                var out: [String: String] = [:]
                for (i, h) in t.headers.enumerated() { out[h] = r.text(i) }
                return out
            }
            if let d = HistoryStore.days().last(where: { $0 <= e.baseDay }),
               let data = HistoryStore.load(d), let t = ScreenerViewModel.align(data, to: current), let v = values(t) {
                return (d, false, v)
            }
            return ("today", true, values(current) ?? [:])
        }.value
    }
}

/// The small "F" badge button.
struct FBadge: View {
    let on: Bool
    var body: some View {
        Text("F").font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(on ? Color.white : Color.accentColor)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color.accentColor.opacity(0.12)))
    }
}

// MARK: - Pick from the stock on screen

/// Shows the multibagger's values just before its move; one click adds "column = / ≥ / ≤ value" to the combination.
struct MBPickFromStock: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let event: MBEvent?
    @ObservedObject private var c = MBFilterCenter.shared
    @State private var values: [String: String] = [:]
    @State private var day = ""
    @State private var isToday = false
    @State private var search = ""
    @AppStorage("mbf.allColumns") private var allColumns = false

    private var columns: [String] {
        let base = allColumns ? vm.headers : vm.filterColumnIndices.map { vm.headers[$0] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return base.filter { q.isEmpty || $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = event {
                HStack {
                    Text("\(e.symbol) · \(e.monthTitle) \(String(format: "%+.0f%%", e.gain))").font(.callout.bold())
                    Text(isToday ? "no stored day before the move — today's values" : "values on \(day)")
                        .font(.caption).foregroundStyle(isToday ? .orange : .secondary)
                    Spacer()
                    TextField("Find column", text: $search).textFieldStyle(.roundedBorder).frame(width: 130)
                    Toggle("All columns", isOn: $allColumns).toggleStyle(.checkbox).font(.caption)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(columns, id: \.self) { col in
                            let v = values[col] ?? ""
                            HStack(spacing: 6) {
                                Image(systemName: c.contains(column: col) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(c.contains(column: col) ? Color.accentColor : Color.secondary.opacity(0.4))
                                Text(col).lineLimit(1).frame(width: 150, alignment: .leading)
                                Text(v.isEmpty ? "—" : v).monospacedDigit().lineLimit(1).frame(width: 90, alignment: .trailing)
                                    .foregroundStyle(v.isEmpty ? .secondary : .primary)
                                Spacer()
                                if !v.isEmpty {
                                    pick("=", col, .equals, v)
                                    if Double(v.replacingOccurrences(of: ",", with: "")) != nil {
                                        pick("≥", col, .greaterOrEqual, v)
                                        pick("≤", col, .lessOrEqual, v)
                                    }
                                }
                            }
                            .font(.callout)
                            .padding(.vertical, 2).padding(.horizontal, 4)
                            .background(c.contains(column: col) ? Color.accentColor.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            } else {
                Text("Move to a multibagger in the reel to pick its values.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: event?.id) { await reload() }
    }

    private func pick(_ t: String, _ col: String, _ op: RuleOperator, _ v: String) -> some View {
        Button(t) { c.add(column: col, op: op, value: v) }
            .controlSize(.small)
            .help("Add “\(col) \(op.rawValue) \(v)” to the combination")
    }

    private func reload() async {
        guard let e = event, let label = vm.labelIndex else { values = [:]; return }
        let r = await MBFilterCenter.preMoveValues(e, current: vm.table, label: label)
        day = r.day; isToday = r.today; values = r.values
    }
}

// MARK: - The combination being edited (shared by Multibaggers, the reel and the window)

struct MBComboEditorBar: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = MBFilterCenter.shared
    @Binding var on: Bool
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(c.activeName ?? "New combination").font(.callout.bold())
                if c.isDirty { Text("edited").font(.caption2).foregroundStyle(.orange) }
                Spacer()
                Button("New") { c.newCombo() }.help("Start an empty combination")
                Button("Use my Filter") { c.group = vm.settings.filterGroup }
                if c.activeCombo != nil {
                    Button("Save") { c.updateActive() }.disabled(!c.isDirty)
                }
                Button("Save as…") { name = c.activeCombo == nil ? "" : (c.activeName ?? "") + " v2"; naming = true }
                    .disabled(c.group.activeCount == 0)
                    .popover(isPresented: $naming) {
                        HStack {
                            TextField("Name, e.g. STREAK≥5 + T3 green", text: $name).frame(width: 240).onSubmit { save() }
                            Button("Save") { save() }.keyboardShortcut(.defaultAction)
                        }.padding(10)
                    }
            }
            Text(c.group.describe).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            HStack {
                Toggle("Show only matches", isOn: $on).toggleStyle(.switch).controlSize(.small)
                Spacer()
                if c.running { ProgressView().controlSize(.small) }
                let events = MBFilterCenter.scopedEvents(vm: vm)
                Button { c.run(events: events, vm: vm); on = true } label: { Label("Check \(events.count) multibaggers", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(c.running || c.group.activeCount == 0)
            }
            if !c.summary.isEmpty { Text(c.summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if !c.issues.isEmpty { Text(c.issues.prefix(3).joined(separator: " · ")).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func save() { c.saveAsNew(name); naming = false }
}

// MARK: - All saved combinations

struct MBCombosList: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = MBFilterCenter.shared
    var onOpen: () -> Void = {}
    @State private var renaming: UUID?
    @State private var newName = ""

    var body: some View {
        if c.combos.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray").font(.title).foregroundStyle(.secondary)
                Text("No saved combinations yet. Build one, then “Save as…”.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            List {
                ForEach(c.combos) { combo in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if c.activeCombo == combo.id { Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor) }
                            if renaming == combo.id {
                                TextField("", text: $newName).textFieldStyle(.roundedBorder).frame(width: 220)
                                    .onSubmit { rename(combo) }
                                Button("OK") { rename(combo) }
                            } else {
                                Text(combo.name).font(.callout.bold())
                            }
                            Spacer()
                            Button("Edit") { c.load(combo); onOpen() }.help("Load into the editor — change it, then Save")
                            Button { c.load(combo); c.run(events: MBFilterCenter.scopedEvents(vm: vm), vm: vm); UserDefaults.standard.set(true, forKey: "mb.fOn") } label: { Image(systemName: "play.fill") }
                                .help("Check it on the multibaggers and show only its matches")
                                .disabled(c.running)
                            Menu {
                                Button("Rename") { newName = combo.name; renaming = combo.id }
                                Button("Duplicate") { c.duplicate(combo) }
                                Button("Copy conditions") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(combo.group.describe, forType: .string) }
                                Divider()
                                Button("Delete", role: .destructive) { c.delete(combo) }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        Text(combo.group.describe).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        HStack {
                            if let r = combo.result {
                                Text(r.text).font(.caption).foregroundStyle(.green)
                                Text(r.ranAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("not checked yet").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
        }
    }

    private func rename(_ combo: MBCombo) {
        if let i = c.combos.firstIndex(where: { $0.id == combo.id }), !newName.trimmingCharacters(in: .whitespaces).isEmpty {
            c.combos[i].name = newName.trimmingCharacters(in: .whitespaces)
        }
        renaming = nil
    }
}

// MARK: - F panel (tabs: Pick · Conditions · Saved)

struct MBFPanel: View {
    @EnvironmentObject var vm: ScreenerViewModel
    var event: MBEvent? = nil
    @Binding var on: Bool
    @ObservedObject private var c = MBFilterCenter.shared
    @AppStorage("mbf.tab") private var tab = 0
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("F — combinations before a multibagger").font(.headline)
                Spacer()
                Button { openWindow(id: "mbcombos") } label: { Label("All combinations", systemImage: "list.bullet.rectangle") }
                    .controlSize(.small).help("Every saved combination in its own window (⌥⌘F)")
            }
            Picker("", selection: $tab) {
                Text(event == nil ? "Pick" : "Pick from \(event!.symbol)").tag(0)
                Text("Conditions (\(c.group.activeCount))").tag(1)
                Text("Saved (\(c.combos.count))").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()

            Group {
                switch tab {
                case 0:
                    MBPickFromStock(event: event)
                case 1:
                    ScrollView {
                        FilterGroupEditor(group: $c.group, columns: vm.headers, isRoot: true, onDelete: {})
                    }
                default:
                    MBCombosList(onOpen: { tab = 1 })
                }
            }
            .frame(minHeight: 230, maxHeight: 360)

            Divider()
            MBComboEditorBar(on: $on)
        }
        .padding(14)
        .frame(width: 600)
        .environmentObject(vm)
    }
}

// MARK: - Window: all saved combinations, editable

struct MBCombosWindow: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = MBFilterCenter.shared
    @AppStorage("mb.fOn") private var fOn = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Saved combinations").font(.headline)
                    Spacer()
                    Button { c.newCombo() } label: { Label("New", systemImage: "plus") }
                }
                .padding(10)
                MBCombosList()
            }
            .frame(minWidth: 380, idealWidth: 440)
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    FilterGroupEditor(group: $c.group, columns: vm.headers, isRoot: true, onDelete: {})
                }
                Divider()
                MBComboEditorBar(on: $fOn)
                HStack {
                    Spacer()
                    Button("Open Multibaggers") { openWindow(id: "multibaggers") }
                    Button("Chart Reel of matches") {
                        fOn = true
                        let d = UserDefaults.standard
                        d.set(ReelSource.multibaggers.rawValue, forKey: "reel.source")
                        d.set("", forKey: "reel.mbMonth")
                        d.set(UUID().uuidString + "|", forKey: "reel.jump")
                        openWindow(id: "reel")
                    }
                    .disabled(!c.ready)
                }
            }
            .padding(12)
            .frame(minWidth: 520)
        }
        .navigationTitle("F Combinations")
        .onAppear { MultibaggerCenter.shared.loadIfNeeded() }
    }
}
