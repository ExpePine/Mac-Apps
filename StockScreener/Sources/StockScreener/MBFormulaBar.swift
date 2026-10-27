import SwiftUI
import AppKit

// MARK: - Formula text field with column-name autocomplete

/// A formula box (Filter formula syntax: `STREAK >= 5 AND t3Color = 1 AND ([DEL %] > 40 OR MOR > 90)`) that
/// suggests Filter column titles as you type. Names with spaces or symbols are inserted as [name].
/// ↓ / ↑ move in the list, Return picks, Esc closes; Return with no list open runs `onSubmit`.
struct FormulaField: NSViewRepresentable {
    let columns: [String]
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.bezelStyle = .roundedBezel
        f.isBordered = true
        f.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        f.stringValue = text
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil, f.stringValue != text { f.stringValue = text }
        f.placeholderString = placeholder
    }

    static let keywords = ["AND", "OR", "NOT"]
    static let functionNames = ["ABS(", "ROUND(", "MIN(", "MAX(", "PCT(", "EMPTY(", "CONTAINS(", "STARTSWITH("]

    static func isBare(_ name: String) -> Bool {
        guard let f = name.first, f.isLetter || f == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }

    /// How a column is written in a formula.
    static func token(for column: String) -> String { isBare(column) ? column : "[\(column)]" }

    /// Suggestions for the word being typed (prefix matches first, then "contains").
    static func suggestions(_ typed: String, columns: [String], bracketed: Bool, limit: Int = 14) -> [String] {
        let q = typed.lowercased()
        guard !q.isEmpty else { return [] }
        var out: [String] = [], seen = Set<String>()
        func add(_ s: String) { if out.count < limit, seen.insert(s).inserted { out.append(s) } }
        for c in columns where c.lowercased().hasPrefix(q) { add(bracketed ? "[\(c)]" : token(for: c)) }
        for c in columns where c.lowercased().contains(q) { add(bracketed ? "[\(c)]" : token(for: c)) }
        if !bracketed {
            for k in keywords + functionNames where k.lowercased().hasPrefix(q) { add(k) }
        }
        return out
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FormulaField
        private var completing = false
        private var lastLength = 0
        init(_ p: FormulaField) { parent = p }

        /// The word being typed up to the cursor: identifier characters, or everything after an unclosed "[".
        private func word(_ tv: NSTextView) -> (prefix: String, start: Int, bracketed: Bool) {
            let s = tv.string as NSString
            let cursor = min(tv.selectedRange().location, s.length)
            let before = s.substring(to: cursor)
            if let open = before.lastIndex(of: "["), !before[open...].contains("]") {
                let start = before.distance(from: before.startIndex, to: open)
                return (String(before[before.index(after: open)...]), start, true)
            }
            var start = cursor
            while start > 0 {
                guard let u = UnicodeScalar(s.character(at: start - 1)) else { break }
                let c = Character(u)
                if c.isLetter || c.isNumber || c == "_" || c == "." { start -= 1 } else { break }
            }
            return (s.substring(with: NSRange(location: start, length: cursor - start)), start, false)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField, let tv = obj.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            parent.text = f.stringValue
            let grew = f.stringValue.count > lastLength
            lastLength = f.stringValue.count
            guard !completing, grew else { return }
            let w = word(tv)
            guard !w.prefix.isEmpty, !(w.prefix.first?.isNumber ?? false) || w.bracketed else { return }
            completing = true
            DispatchQueue.main.async { [weak self] in
                tv.complete(nil)
                self?.completing = false
            }
        }

        func control(_ control: NSControl, textView tv: NSTextView, completions words: [String],
                     forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            index.pointee = -1
            let w = word(tv)
            let full = FormulaField.suggestions(w.prefix, columns: parent.columns, bracketed: w.bracketed)
            // NSTextView replaces only `charRange` (its own idea of a word): drop what's typed before it
            let typedWhole = w.bracketed ? "[" + w.prefix : w.prefix
            let skip = max(0, charRange.location - w.start)
            let skipped = String(typedWhole.prefix(skip))
            return full.compactMap { m in
                guard skip > 0 else { return m }
                return m.lowercased().hasPrefix(skipped.lowercased()) ? String(m.dropFirst(skipped.count)) : nil
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                parent.text = (control as? NSTextField)?.stringValue ?? parent.text
                parent.onSubmit()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let f = obj.object as? NSTextField { parent.text = f.stringValue }
        }
    }
}

// MARK: - Turning a combination into formula text

extension FilterCondition {
    /// The condition as Filter formula text, or nil when it can't be written that way (e.g. "between").
    var formulaText: String? {
        if kind == .formula { let f = formula.trimmingCharacters(in: .whitespaces); return f.isEmpty ? nil : "(\(f))" }
        guard !column.isEmpty else { return nil }
        let col = FormulaField.token(for: column)
        func lit(_ v: String) -> String {
            let t = v.trimmingCharacters(in: .whitespaces)
            return Double(t.replacingOccurrences(of: ",", with: "")) != nil ? t.replacingOccurrences(of: ",", with: "") : "'\(t)'"
        }
        let ops: [RuleOperator: String] = [.greaterThan: ">", .greaterOrEqual: ">=", .lessThan: "<", .lessOrEqual: "<=", .equals: "=", .notEquals: "!="]
        switch op {
        case .hasValue: return "NOT EMPTY(\(col))"
        case .isEmpty: return "EMPTY(\(col))"
        case .contains: return "CONTAINS(\(col), \(lit(value)))"
        case .notContains: return "NOT CONTAINS(\(col), \(lit(value)))"
        case .startsWith: return "STARTSWITH(\(col), \(lit(value)))"
        case .between: return "(\(col) >= \(lit(value)) AND \(col) <= \(lit(value2)))"
        default:
            guard let o = ops[op] else { return nil }
            if target == .column {
                let other = FormulaField.token(for: otherColumn)
                return factor == "1" || factor.isEmpty ? "\(col) \(o) \(other)" : "\(col) \(o) \(other) * \(factor)"
            }
            return "\(col) \(o) \(lit(value))"
        }
    }
}

extension FilterGroup {
    var formulaText: String? {
        guard isEnabled else { return nil }
        let live = conditions.filter(\.isEnabled)
        if mode == .all, groups.allSatisfy({ !$0.isEnabled || $0.activeCount == 0 }), live.count == 1, live[0].kind == .formula {
            return live[0].formula.trimmingCharacters(in: .whitespaces)
        }
        var parts: [String] = []
        for c in conditions where c.isEnabled { guard let t = c.formulaText else { return nil }; parts.append(t) }
        for g in groups where g.isEnabled && g.activeCount > 0 { guard let t = g.formulaText else { return nil }; parts.append("(\(t))") }
        switch mode {
        case .all: return parts.joined(separator: " AND ")
        case .any: return parts.joined(separator: " OR ")
        case .notAny: return parts.isEmpty ? nil : "NOT (\(parts.joined(separator: " OR ")))"
        }
    }

    /// A one-formula combination.
    static func formula(_ text: String) -> FilterGroup {
        FilterGroup(mode: .all, conditions: [FilterCondition(kind: .formula, formula: text)])
    }
}

// MARK: - The F formula bar (Chart Reel on multibaggers + Multibaggers window)

/// Type a formula with column autocomplete right above the charts; Return checks it on every multibagger and
/// (with "Only matches") the reel flicks through just the stocks it caught. Shows the on-screen stock's
/// pre-move values for the columns you typed.
struct MBFormulaBar: View {
    @EnvironmentObject var vm: ScreenerViewModel
    let event: MBEvent?
    @ObservedObject private var c = MBFilterCenter.shared
    @AppStorage("mb.fOn") private var fOn = false
    @AppStorage("mbf.formula") private var text = ""
    @State private var showPanel = false
    @State private var naming = false
    @State private var name = ""
    @State private var values: [String: String] = [:]
    @State private var valuesDay = ""

    private var columns: [String] { vm.filterColumnIndices.map { vm.headers[$0] } + vm.headers.filter { h in !vm.filterColumnIndices.contains { vm.headers[$0] == h } } }

    /// Columns used in the formula and whether it compiles, with today's match count.
    private var check: (ok: Bool, message: String, used: [String]) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return (false, "", []) }
        do {
            let f = try Formula.compile(t, table: vm.table)
            let today = vm.table.rows.filter(f.predicate).count
            return (true, "✓ \(today) stock\(today == 1 ? "" : "s") match today", f.columns.map { vm.headers[$0] })
        } catch {
            return (false, error.localizedDescription, [])
        }
    }

    var body: some View {
        let chk = check
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { showPanel.toggle() } label: { FBadge(on: fOn && c.ready) }
                    .buttonStyle(.plain)
                    .help("Full F panel: pick values from this stock, AND / OR editor, saved combinations")
                    .popover(isPresented: $showPanel, arrowEdge: .bottom) { MBFPanel(event: event, on: $fOn).environmentObject(vm) }
                FormulaField(columns: columns,
                             placeholder: "Type a formula — column names autocomplete, e.g.  STREAK >= 5 AND t3Color = 1 AND MOR > 90   (Return = check)",
                             text: $text, onSubmit: run)
                    .frame(minWidth: 320)
                Button(action: run) { Label(c.running ? "Checking…" : "Check", systemImage: "play.fill") }
                    .disabled(!chk.ok || c.running)
                    .help("Check on \(MBFilterCenter.scopedEvents(vm: vm).count) multibaggers (each on its stored day just before the move)")
                Toggle("Only matches", isOn: $fOn).toggleStyle(.checkbox).disabled(!c.ready)
                    .help("Show only the multibaggers this formula caught")
                Menu {
                    Button("Save as new…") { name = ""; naming = true }.disabled(!chk.ok)
                    if c.activeCombo != nil { Button("Save to “\(c.activeName ?? "")”") { applyText(); c.updateActive() }.disabled(!chk.ok) }
                    if !c.combos.isEmpty {
                        Divider()
                        Section("Saved combinations") {
                            ForEach(c.combos) { combo in
                                Button(combo.name + (combo.result.map { "  —  \($0.caught)/\($0.judged)" } ?? "")) { load(combo) }
                            }
                        }
                    }
                    Divider()
                    Button("Clear") { text = ""; c.newCombo() }
                } label: { Image(systemName: "tray.full") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Save this formula, or load a saved combination")
                    .popover(isPresented: $naming) {
                        HStack {
                            TextField("Name", text: $name).frame(width: 220).onSubmit { saveNew() }
                            Button("Save") { saveNew() }.keyboardShortcut(.defaultAction)
                        }.padding(10)
                    }
            }
            HStack(spacing: 10) {
                if !chk.message.isEmpty {
                    Text(chk.message).font(.caption).foregroundStyle(chk.ok ? Color.secondary : Color.orange).lineLimit(1)
                }
                if let e = event, !chk.used.isEmpty {
                    Text("\(e.symbol) before the move\(valuesDay.isEmpty ? "" : " (\(valuesDay))"):").font(.caption.bold())
                    Text(chk.used.map { "\($0) \(values[$0].flatMap { $0.isEmpty ? nil : $0 } ?? "—")" }.joined(separator: " · "))
                        .font(.caption.monospacedDigit()).lineLimit(1)
                }
                Spacer()
                if c.ready {
                    Text((c.activeName.map { "\($0): " } ?? "") + "\(c.matched.count) caught").font(.caption.bold()).foregroundStyle(Color.accentColor)
                        .help(c.summary)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .task(id: event?.id) { await loadValues() }
        .onAppear {
            if text.isEmpty, let f = c.group.formulaText, !f.isEmpty { text = f }
        }
        .onChange(of: c.group) { g in
            // picked in the F panel / editor → show it here as a formula
            if let f = g.formulaText, !f.isEmpty, f != text.trimmingCharacters(in: .whitespaces) { text = f }
        }
    }

    private func applyText() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if c.group.formulaText != t { c.group = .formula(t) }
    }

    private func run() {
        guard check.ok, !c.running else { return }
        applyText()
        c.run(events: MBFilterCenter.scopedEvents(vm: vm), vm: vm)
        fOn = true
    }

    private func load(_ combo: MBCombo) {
        c.load(combo)
        text = combo.group.formulaText ?? ""
        c.run(events: MBFilterCenter.scopedEvents(vm: vm), vm: vm)
        fOn = true
    }

    private func saveNew() {
        applyText()
        c.saveAsNew(name)
        naming = false
    }

    private func loadValues() async {
        guard let e = event, let label = vm.labelIndex else { values = [:]; valuesDay = ""; return }
        let r = await MBFilterCenter.preMoveValues(e, current: vm.table, label: label)
        values = r.values
        valuesDay = r.today ? "today's values" : r.day
    }
}
