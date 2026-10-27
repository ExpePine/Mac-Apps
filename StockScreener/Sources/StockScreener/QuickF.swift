import SwiftUI
import AppKit

// MARK: - Quick F syntax

/// Short syntax for typing a combination fast:
///   `count>5 + compact + D_TRIGGER`
/// • `+` (or `,`) = AND, `|` = OR inside one part
/// • `column > 5`, `column = 1`, `column != 0` … any comparison (also ≥ ≤ ≠)
/// • a bare column name = "has a value and isn't 0"
/// • `NOT column` / `!column` = empty or 0
/// Column names are matched to the Filter titles ignoring case; names with spaces work too (`del % > 40`).
enum QuickF {
    private static let ops = [">=", "<=", "!=", "<>", "==", "≥", "≤", "≠", ">", "<", "="]

    /// The `+` / `,` separated parts, trimmed.
    static func parts(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "+" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Normalised text used to compare combinations (order of parts kept, spaces / case ignored).
    static func key(_ s: String) -> String {
        parts(s).map { $0.lowercased().replacingOccurrences(of: " ", with: "") }.joined(separator: "+")
    }

    static func partKey(_ p: String) -> String { p.lowercased().replacingOccurrences(of: " ", with: "") }

    static func formula(_ s: String, headers: [String]) throws -> String {
        let ps = parts(s)
        guard !ps.isEmpty else { throw FormulaError(message: "Type a column, e.g. count>5 + D_TRIGGER") }
        return try ps.map { p in
            let ors = p.components(separatedBy: "|").flatMap { $0.components(separatedBy: " or ") }.flatMap { $0.components(separatedBy: " OR ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let f = try ors.map { try term($0, headers: headers) }
            return f.count == 1 ? f[0] : "(" + f.joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
    }

    static func column(_ name: String, headers: [String]) throws -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.hasPrefix("["), n.hasSuffix("]") { return n }
        if let h = headers.first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == n.lowercased() }) {
            return FormulaField.token(for: h)
        }
        throw FormulaError(message: "No Filter column “\(n)”")
    }

    private static func term(_ t: String, headers: [String]) throws -> String {
        var t = t
        var negate = false
        if t.lowercased().hasPrefix("not ") { negate = true; t = String(t.dropFirst(4)) }
        else if t.hasPrefix("!"), !t.hasPrefix("!=") { negate = true; t = String(t.dropFirst()) }
        t = t.trimmingCharacters(in: .whitespaces)
        // find the first comparison operator (longest match at each position)
        let chars = Array(t)
        for i in chars.indices {
            for o in ops {
                let oc = Array(o)
                guard i + oc.count <= chars.count, Array(chars[i..<(i + oc.count)]) == oc, i > 0 else { continue }
                let left = String(chars[..<i]), right = String(chars[(i + oc.count)...]).trimmingCharacters(in: .whitespaces)
                guard !right.isEmpty else { throw FormulaError(message: "“\(t)” needs a value after \(o)") }
                let col = try column(left, headers: headers)
                let r: String
                if Double(right.replacingOccurrences(of: ",", with: "")) != nil { r = right.replacingOccurrences(of: ",", with: "") }
                else if right.hasPrefix("'") || right.hasPrefix("\"") || right.hasPrefix("[") { r = right }
                else if let c = try? column(right, headers: headers) { r = c }
                else { r = "'\(right)'" }
                let f = "\(col) \(o) \(r)"
                return negate ? "NOT (\(f))" : f
            }
        }
        let col = try column(t, headers: headers)
        let has = "(NOT EMPTY(\(col)) AND NOT (\(col) = 0))"
        return negate ? "NOT \(has)" : has
    }
}

// MARK: - What you've checked before (for whole-combination suggestions)

struct QuickFHistory: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var caught: Int
    var judged: Int
    var matches: Int
    var at = Date()
    var hitRate: Double { matches > 0 ? Double(caught) / Double(matches) * 100 : 0 }
    var label: String { "\(caught)/\(judged) caught · \(String(format: "%.1f", hitRate))% hit" }
}

@MainActor final class QuickFStore: ObservableObject {
    static let shared = QuickFStore()
    @Published private(set) var history: [QuickFHistory] = (UserDefaults.standard.data(forKey: "mbf.quickHistory")
        .flatMap { try? JSONDecoder().decode([QuickFHistory].self, from: $0) }) ?? []

    func record(_ text: String, _ r: MBComboResult) {
        let k = QuickF.key(text)
        history.removeAll { QuickF.key($0.text) == k }
        history.insert(QuickFHistory(text: QuickF.parts(text).joined(separator: " + "), caught: r.caught, judged: r.judged, matches: r.matches), at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "mbf.quickHistory")
    }

    func remove(_ h: QuickFHistory) {
        history.removeAll { $0.id == h.id }
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "mbf.quickHistory")
    }

    /// Everything to learn from: checked history plus saved combinations typed in quick syntax.
    private var all: [QuickFHistory] {
        var out = history
        for c in MBFilterCenter.shared.combos where !c.note.isEmpty {
            if !out.contains(where: { QuickF.key($0.text) == QuickF.key(c.note) }) {
                out.append(QuickFHistory(text: c.note, caught: c.result?.caught ?? 0, judged: c.result?.judged ?? 0, matches: c.result?.matches ?? 0))
            }
        }
        return out
    }

    /// Longer combinations that start with what's typed — best hit rate first.
    func continuations(of typed: String, limit: Int = 3) -> [QuickFHistory] {
        let k = QuickF.key(typed)
        guard !k.isEmpty else { return [] }
        return all.filter { let hk = QuickF.key($0.text); return hk.hasPrefix(k) && hk != k }
            .sorted { ($0.hitRate, $0.at) > ($1.hitRate, $1.at) }
            .prefix(limit).map { $0 }
    }

    /// Parts that often went together with the parts already typed (weighted by how well those combos did).
    func nextParts(after typed: String, limit: Int = 6) -> [String] {
        let have = Set(QuickF.parts(typed).map(QuickF.partKey))
        var score: [String: Double] = [:], shown: [String: String] = [:]
        for h in all {
            let ps = QuickF.parts(h.text)
            let ks = Set(ps.map(QuickF.partKey))
            guard have.isSubset(of: ks) else { continue }
            for p in ps where !have.contains(QuickF.partKey(p)) {
                score[QuickF.partKey(p), default: 0] += 1 + h.hitRate / 10
                shown[QuickF.partKey(p)] = shown[QuickF.partKey(p)] ?? p
            }
        }
        return score.sorted { $0.value > $1.value }.prefix(limit).compactMap { shown[$0.key] }
    }

    /// Best checked combinations so far (by hit rate, needs at least 3 caught).
    func best(limit: Int = 5) -> [QuickFHistory] {
        all.filter { $0.caught >= 3 }.sorted { $0.hitRate > $1.hitRate }.prefix(limit).map { $0 }
    }
}

// MARK: - The text box: column autocomplete per part, Tab = take the suggested continuation

struct QuickFField: NSViewRepresentable {
    let columns: [String]
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var onTab: () -> Bool = { false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = "count>5 + compact + D_TRIGGER"
        f.bezelStyle = .roundedBezel
        f.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        f.stringValue = text
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text {
            if let ed = f.currentEditor() as? NSTextView {
                ed.string = text
                ed.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            } else { f.stringValue = text }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickFField
        private var completing = false
        private var lastLength = 0
        init(_ p: QuickFField) { parent = p }

        /// The part being typed (after the last + , |), without leading spaces; nil once it has an operator.
        private func word(_ tv: NSTextView) -> (prefix: String, start: Int)? {
            let s = tv.string as NSString
            let cursor = min(tv.selectedRange().location, s.length)
            var start = cursor
            while start > 0 {
                let ch = s.character(at: start - 1)
                if ch == 43 || ch == 44 || ch == 124 { break }       // + , |
                start -= 1
            }
            while start < cursor, s.character(at: start) == 32 { start += 1 }
            var p = s.substring(with: NSRange(location: start, length: cursor - start))
            if p.lowercased().hasPrefix("not ") { p = String(p.dropFirst(4)); start += 4 }
            else if p.hasPrefix("!") { p = String(p.dropFirst()); start += 1 }
            if p.contains(where: { "<>=≥≤≠".contains($0) }) { return nil }
            return (p, start)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField, let tv = obj.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            parent.text = f.stringValue
            let grew = f.stringValue.count > lastLength
            lastLength = f.stringValue.count
            guard !completing, grew, let w = word(tv), !w.prefix.isEmpty else { return }
            completing = true
            DispatchQueue.main.async { [weak self] in
                tv.complete(nil)
                self?.completing = false
            }
        }

        func control(_ control: NSControl, textView tv: NSTextView, completions words: [String],
                     forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            index.pointee = -1
            guard let w = word(tv) else { return [] }
            let q = w.prefix.lowercased()
            var full: [String] = [], seen = Set<String>()
            for c in parent.columns where c.lowercased().hasPrefix(q) { if seen.insert(c).inserted { full.append(c) } }
            for c in parent.columns where c.lowercased().contains(q) { if seen.insert(c).inserted { full.append(c) } }
            let skip = max(0, charRange.location - w.start)
            let typed = String(w.prefix.prefix(skip)).lowercased()
            return full.prefix(14).compactMap { m in
                guard skip > 0 else { return m }
                return m.lowercased().hasPrefix(typed) ? String(m.dropFirst(skip)) : nil
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                parent.text = (control as? NSTextField)?.stringValue ?? parent.text
                parent.onSubmit()
                return true
            }
            if sel == #selector(NSResponder.insertTab(_:)) { return parent.onTab() }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let f = obj.object as? NSTextField { parent.text = f.stringValue }
        }
    }
}

// MARK: - The small floating box

struct QuickFView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var c = MBFilterCenter.shared
    @ObservedObject private var store = QuickFStore.shared
    @AppStorage("mb.fOn") private var fOn = false
    @AppStorage("mbf.quick") private var text = ""
    @State private var pending: String?
    @State private var showBest = false

    private var columns: [String] {
        let f = vm.filterColumnIndices.map { vm.headers[$0] }
        return f + vm.headers.filter { !f.contains($0) }
    }

    private var parsed: (formula: String?, message: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return (nil, "+ = and · | = or · bare name = has a value · Tab = take suggestion") }
        do {
            let f = try QuickF.formula(t, headers: vm.headers)
            let n = try Formula.compile(f, table: vm.table).predicate
            let today = vm.table.rows.filter(n).count
            return (f, "✓ \(today) match today · Return = check")
        } catch { return (nil, error.localizedDescription) }
    }

    var body: some View {
        let p = parsed
        let cont = store.continuations(of: text)
        let next = store.nextParts(after: text)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                QuickFField(columns: columns, text: $text, onSubmit: run, onTab: {
                    if let first = cont.first { text = first.text; return true }
                    if let n = next.first { text = append(n); return true }
                    return false
                })
                if c.running { ProgressView().controlSize(.small) }
                Toggle("", isOn: $fOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(!c.ready)
                    .help("On: the reel / list shows only the multibaggers this combination caught")
            }
            HStack(spacing: 6) {
                Text(p.message).font(.caption2).foregroundStyle(p.formula == nil && !text.isEmpty ? Color.orange : Color.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if c.ready, let r = c.lastResult {
                    Text("\(r.caught)/\(r.judged) caught · \(String(format: "%.1f", r.hitRate))% hit").font(.caption2.bold()).foregroundStyle(Color.accentColor)
                        .help(c.summary)
                }
            }
            // whole-combination suggestions (from what you've checked / saved before)
            ForEach(cont) { h in
                Button { text = h.text } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right").font(.caption2)
                        Text(h.text).font(.caption.monospaced()).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(h.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Tab takes the first one")
            }
            if !next.isEmpty {
                HStack(spacing: 4) {
                    Text("+").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(next, id: \.self) { n in
                        Button(n) { text = append(n) }.font(.caption).controlSize(.mini)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(showBest ? "Hide best" : "Best so far (\(store.best().count))") { showBest.toggle() }
                    .buttonStyle(.link).font(.caption2).disabled(store.best().isEmpty)
                Spacer()
                Button("Save") { save() }.buttonStyle(.link).font(.caption2).disabled(p.formula == nil)
                Button("All…") { QuickFPanel.shared.openCombos?() }
                    .buttonStyle(.link).font(.caption2)
            }
            if showBest {
                ForEach(store.best()) { h in
                    Button { text = h.text; run() } label: {
                        HStack { Text(h.text).font(.caption.monospaced()).lineLimit(1); Spacer(); Text(h.label).font(.caption2).foregroundStyle(.green) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .frame(width: 440)
        .onChange(of: c.lastResult) { r in
            if let r, let t = pending { store.record(t, r); pending = nil }
        }
    }

    private func append(_ part: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return part }
        if t.hasSuffix("+") || t.hasSuffix(",") { return t + " " + part }
        return t + " + " + part
    }

    private func run() {
        guard let f = parsed.formula, !c.running else { return }
        c.group = .formula(f)
        c.activeCombo = nil
        pending = text
        c.run(events: MBFilterCenter.scopedEvents(vm: vm), vm: vm)
        fOn = true
    }

    private func save() {
        guard let f = parsed.formula else { return }
        c.group = .formula(f)
        c.saveAsNew(QuickF.parts(text).joined(separator: " + "))
        if let id = c.activeCombo, let i = c.combos.firstIndex(where: { $0.id == id }) {
            c.combos[i].note = text
            c.combos[i].result = c.lastResult
        }
    }
}

/// A small always-on-top box that floats over the charts; drag it anywhere (its place is remembered).
@MainActor final class QuickFPanel: NSObject {
    static let shared = QuickFPanel()
    private var panel: NSPanel?
    var openCombos: (() -> Void)?

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle(_ vm: ScreenerViewModel, openCombos: @escaping () -> Void) {
        self.openCombos = openCombos
        if isOpen { panel?.orderOut(nil) } else { show(vm) }
    }

    func show(_ vm: ScreenerViewModel) {
        if panel == nil {
            let host = NSHostingController(rootView: QuickFView().environmentObject(vm))
            host.sizingOptions = [.preferredContentSize]
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 80),
                            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
            p.title = "F"
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = false
            p.isMovableByWindowBackground = true
            p.contentViewController = host
            p.setFrameAutosaveName("QuickFPanel")
            if !p.setFrameUsingName("QuickFPanel") {
                if let s = NSScreen.main?.visibleFrame { p.setFrameTopLeftPoint(NSPoint(x: s.maxX - 480, y: s.maxY - 60)) }
            }
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }
}

/// Toolbar button that opens / closes the floating F box.
struct QuickFButton: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("mb.fOn") private var fOn = false
    @ObservedObject private var c = MBFilterCenter.shared

    var body: some View {
        Button { QuickFPanel.shared.toggle(vm, openCombos: { openWindow(id: "mbcombos") }) } label: { FBadge(on: fOn && c.ready) }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("F: a small floating box over the charts — type count>5 + compact + D_TRIGGER, Return checks it (⇧⌘F)")
    }
}
