import SwiftUI
import AppKit

// MARK: - Notes per multibagger move (one per stock + month)

struct MBNote: Codable, Identifiable, Equatable {
    var id: String              // MBEvent.id = "SYMBOL|yyyy-MM"
    var symbol: String
    var month: String
    var gain: Double
    var text: String
    var updated = Date()
}

/// The multibagger now on screen (Chart Reel on multibaggers, or the row picked in Multibaggers).
@MainActor final class MBNoteFocus: ObservableObject {
    static let shared = MBNoteFocus()
    @Published var event: MBEvent?
    func set(_ e: MBEvent?) { if e?.id != event?.id { event = e } }
}

@MainActor final class MBNoteStore: ObservableObject {
    static let shared = MBNoteStore()
    @Published private(set) var notes: [String: MBNote] = MBNoteStore.load()
    @Published private(set) var version = 0
    private var saveWork: DispatchWorkItem?
    private var modelCache: (key: String, model: NoteModel)?

    private static var url: URL { AppFolders.base.appendingPathComponent("mb_notes.json") }
    private static func load() -> [String: MBNote] {
        guard let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([MBNote].self, from: d) else { return [:] }
        return Dictionary(a.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var ordered: [MBNote] { notes.values.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.updated > $1.updated } }

    func text(for e: MBEvent) -> String { notes[e.id]?.text ?? "" }

    func set(_ text: String, for e: MBEvent) {
        if notes[e.id]?.text == text { return }
        notes[e.id] = MBNote(id: e.id, symbol: e.symbol, month: e.month, gain: e.gain, text: text, updated: Date())
        changed()
    }

    func set(_ text: String, id: String) {
        guard var n = notes[id], n.text != text else { return }
        n.text = text; n.updated = Date(); notes[id] = n
        changed()
    }

    func delete(_ id: String) { notes[id] = nil; changed() }

    private func changed() {
        version &+= 1
        saveWork?.cancel()
        let all = Array(notes.values)
        let w = DispatchWorkItem { if let d = try? JSONEncoder().encode(all) { try? d.write(to: Self.url, options: .atomic) } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// What your other notes teach the autocomplete (the note being typed is left out).
    func model(excluding id: String?) -> NoteModel {
        let key = "\(version)|\(id ?? "")"
        if let c = modelCache, c.key == key { return c.model }
        let m = NoteModel(notes: ordered.filter { $0.id != id }.map(\.text))
        modelCache = (key, m)
        return m
    }
}

// MARK: - Learned vocabulary (your words, in your order)

enum NoteTokens {
    /// Words; "+" and "," become their own tokens.
    static func tokens(_ s: String) -> [String] {
        var t = s
        for p in ["+", ","] { t = t.replacingOccurrences(of: p, with: " \(p) ") }
        return t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}

struct NoteModel {
    var unigram: [String: Int] = [:]                 // lowercased token → count
    var display: [String: String] = [:]              // lowercased → most-used spelling
    var bigram: [String: [String: Int]] = [:]        // previous → next
    var trigram: [String: [String: Int]] = [:]       // "a b" → next
    var notes: [String] = []                         // newest first

    init(notes: [String]) {
        self.notes = notes
        var spell: [String: [String: Int]] = [:]
        for n in notes {
            let ts = NoteTokens.tokens(n)
            let low = ts.map { $0.lowercased() }
            for (i, t) in ts.enumerated() {
                unigram[low[i], default: 0] += 1
                spell[low[i], default: [:]][t, default: 0] += 1
                if i >= 1 { bigram[low[i - 1], default: [:]][low[i], default: 0] += 1 }
                if i >= 2 { trigram[low[i - 2] + " " + low[i - 1], default: [:]][low[i], default: 0] += 1 }
            }
        }
        for (k, v) in spell { display[k] = v.max { $0.value < $1.value }?.key ?? k }
    }

    /// Likely next tokens after `prev` (lowercased), best first, with their share.
    func next(after prev: [String]) -> [(token: String, count: Int, share: Double)] {
        var table: [String: Int]?
        if prev.count >= 2, let t = trigram[prev.suffix(2).joined(separator: " ")], !t.isEmpty { table = t }
        if table == nil, let last = prev.last, let b = bigram[last], !b.isEmpty { table = b }
        guard let table else { return [] }
        let total = Double(table.values.reduce(0, +))
        return table.sorted { $0.value > $1.value }.map { (display[$0.key] ?? $0.key, $0.value, Double($0.value) / total) }
    }
}

// MARK: - Recognised pieces ("count>5", "compact", "D_TRIGGER") and whether this stock agrees

struct NotePiece: Equatable {
    let start: Int
    let end: Int
    let column: String
    let op: String?
    let value: String?
    var ok: Bool?            // nil = the stock has no value for that column

    var canonical: String { column + (op ?? "") + (value ?? "") }
}

enum NoteChecker {
    static let ops = [">=", "<=", "!=", "==", "≥", "≤", "≠", ">", "<", "="]

    private static func ident(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    static func pieces(_ text: String, columns: [String], values: [String: String]) -> [NotePiece] {
        let low = Array(text.lowercased())
        var used = [Bool](repeating: false, count: low.count)
        var out: [NotePiece] = []
        for col in columns.sorted(by: { $0.count > $1.count }) {
            let n = Array(col.lowercased().trimmingCharacters(in: .whitespaces))
            guard !n.isEmpty, n.count <= low.count else { continue }
            var i = 0
            while i + n.count <= low.count {
                guard Array(low[i..<(i + n.count)]) == n, !used[i..<(i + n.count)].contains(true),
                      i == 0 || !ident(low[i - 1]), i + n.count == low.count || !ident(low[i + n.count]) || !ident(n.last!) else { i += 1; continue }
                var j = i + n.count
                var op: String?, value: String?
                var k = j
                while k < low.count, low[k] == " " { k += 1 }
                if let o = ops.first(where: { o in let oc = Array(o); return k + oc.count <= low.count && Array(low[k..<(k + oc.count)]) == oc }) {
                    var m = k + o.count
                    while m < low.count, low[m] == " " { m += 1 }
                    var e = m
                    if e < low.count, low[e] == "-" { e += 1 }
                    while e < low.count, low[e].isNumber || low[e] == "." { e += 1 }
                    if e > m, Double(String(low[m..<e])) != nil { op = o; value = String(low[m..<e]); j = e }
                }
                // very short names only count when written with a comparison (avoid matching ordinary words)
                if n.count < 3 && op == nil { i += 1; continue }
                for x in i..<j { used[x] = true }
                out.append(NotePiece(start: i, end: j, column: col, op: op, value: value, ok: check(values[col], op, value)))
                i = j
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func check(_ raw: String?, _ op: String?, _ value: String?) -> Bool? {
        let t = (raw ?? "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return op == nil ? false : nil }
        let v = Double(t.replacingOccurrences(of: ",", with: ""))
        guard let op, let value, let target = Double(value) else { return v.map { $0 != 0 } ?? true }
        guard let v else { return nil }
        switch op {
        case ">": return v > target
        case ">=", "≥": return v >= target
        case "<": return v < target
        case "<=", "≤": return v <= target
        case "!=", "≠": return v != target
        default: return abs(v - target) < 1e-9
        }
    }
}

// MARK: - The completer

struct NoteSuggestion: Identifiable, Equatable {
    var id: String { insert }
    let insert: String       // replaces the word being typed
    let detail: String
}

struct NoteCompletion: Equatable {
    var ghost = ""                    // grey text after the cursor (Tab)
    var list: [NoteSuggestion] = []   // dropdown (↑ ↓ Return)
    var partialLength = 0             // characters before the cursor that a list item replaces
}

struct NoteContext {
    var columns: [String]                       // Filter titles first
    var values: [String: String] = [:]          // this stock, just before the move
    var rank: [String: Double] = [:]            // column → percent rank 0…1 among all stocks that day
}

enum NoteCompleter {
    static func fmt(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e12 { return String(Int(v)) }
        let a = abs(v)
        return String(format: a >= 100 ? "%.0f" : (a >= 10 ? "%.1f" : "%.2f"), v)
    }

    /// A round number on the right side of `v` for the operator (count = 6 → "count>5").
    static func suggestValue(_ v: Double, op: String) -> String {
        let isInt = v == v.rounded()
        switch op {
        case ">": return isInt ? fmt(v - 1) : fmt(nice(v, down: true))
        case ">=", "≥": return isInt ? fmt(v) : fmt(nice(v, down: true))
        case "<": return isInt ? fmt(v + 1) : fmt(nice(v, down: false))
        case "<=", "≤": return isInt ? fmt(v) : fmt(nice(v, down: false))
        default: return fmt(v)
        }
    }

    private static func nice(_ v: Double, down: Bool) -> Double {
        guard v != 0 else { return 0 }
        let step = pow(10, floor(log10(abs(v))) - 1)
        return (down ? floor(v / step) : ceil(v / step)) * step
    }

    static func rankText(_ r: Double) -> String {
        r >= 0.5 ? "top \(max(1, Int(((1 - r) * 100).rounded())))%" : "bottom \(max(1, Int((r * 100).rounded())))%"
    }

    /// Letters of `q` appear in order in `s` ("dtr" → d_trigger).
    static func subsequence(_ q: String, _ s: String) -> Bool {
        var it = s.makeIterator()
        for c in q { var found = false; while let x = it.next() { if x == c { found = true; break } }; if !found { return false } }
        return true
    }

    static func complete(_ before: String, ctx: NoteContext, model: NoteModel) -> NoteCompletion {
        var out = NoteCompletion()
        // the word being typed: after the last space / + / ,
        let chars = Array(before)
        var s = chars.count
        while s > 0, !(chars[s - 1].isWhitespace || chars[s - 1] == "+" || chars[s - 1] == ",") { s -= 1 }
        let partial = String(chars[s...])
        out.partialLength = partial.count
        let prev = NoteTokens.tokens(String(chars[..<s])).map { $0.lowercased() }

        // a whole earlier note that starts the same way
        let typed = before.trimmingCharacters(in: .whitespaces).lowercased()
        var wholeGhost = ""
        if typed.count >= 3, let n = model.notes.first(where: { $0.lowercased().hasPrefix(before.lowercased()) && $0.count > before.count }) {
            wholeGhost = String(n.dropFirst(before.count))
        }
        let colLow = Dictionary(ctx.columns.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        if partial.isEmpty {
            // next words, the way you usually continue
            let nx = model.next(after: prev)
            var chain: [String] = []
            var p = prev
            for _ in 0..<4 {
                guard let top = model.next(after: p).first, top.count >= 2, top.share >= 0.34 else { break }
                chain.append(top.token)
                p.append(top.token.lowercased())
            }
            out.ghost = chain.isEmpty ? wholeGhost : chain.joined(separator: " ").replacingOccurrences(of: " , ", with: ", ")
            var list = nx.prefix(4).map { NoteSuggestion(insert: $0.token, detail: "you wrote this next \($0.count)×") }
            // this stock's stand-out columns
            let have = Set(prev)
            let stand = ctx.rank.filter { abs($0.value - 0.5) >= 0.4 && !have.contains($0.key.lowercased()) }
                .sorted { abs($0.value - 0.5) > abs($1.value - 0.5) }.prefix(4)
            for (c, r) in stand {
                let v = ctx.values[c] ?? ""
                list.append(NoteSuggestion(insert: "\(c)=\(v)", detail: rankText(r)))
            }
            out.list = Array(list.prefix(7))
            return out
        }

        // "count>" / "count>=" → this stock's value on the right side
        if let o = NoteChecker.ops.first(where: { partial.contains($0) }), let r = partial.range(of: o) {
            let left = String(partial[..<r.lowerBound]), right = String(partial[r.upperBound...])
            if let col = colLow[left.lowercased()], let raw = ctx.values[col], let v = Double(raw.replacingOccurrences(of: ",", with: "")) {
                let cand = suggestValue(v, op: o)
                if cand.hasPrefix(right), cand != right { out.ghost = String(cand.dropFirst(right.count)) }
                out.list = [NoteSuggestion(insert: left + o + cand, detail: "\(col) was \(raw) here")]
                if o != "=" { out.list.append(NoteSuggestion(insert: left + "=" + raw, detail: "exact value")) }
            }
            return out
        }

        let q = partial.lowercased()
        let predicted = Set(model.next(after: prev).prefix(5).map { $0.token.lowercased() })
        var scored: [(String, Double, String, Bool)] = []          // (insert, score, detail, isColumn)
        for (i, c) in ctx.columns.enumerated() {
            let l = c.lowercased()
            var sc: Double
            if l.hasPrefix(q) { sc = 1000 } else if l.contains(q) { sc = 500 } else if q.count >= 2, subsequence(q, l) { sc = 200 } else { continue }
            if let r = ctx.rank[c] { sc += abs(r - 0.5) * 200 }
            if predicted.contains(l) { sc += 300 }
            sc += Double(model.unigram[l] ?? 0) * 5
            sc -= Double(i) * 0.01
            var detail = ctx.values[c].map { $0.isEmpty ? "—" : $0 } ?? ""
            if let r = ctx.rank[c], abs(r - 0.5) >= 0.3 { detail += " · " + rankText(r) }
            scored.append((c, sc, detail, true))
        }
        for (w, n) in model.unigram where colLow[w] == nil && w.count > 1 && w.hasPrefix(q) && w != q && !NoteChecker.ops.contains(where: { w.contains($0) }) {
            scored.append((model.display[w] ?? w, 600 + Double(n) * 10 + (predicted.contains(w) ? 300 : 0), "your word · \(n)×", false))
        }
        scored.sort { $0.1 > $1.1 }
        var list: [NoteSuggestion] = []
        for (ins, _, d, isCol) in scored.prefix(6) {
            list.append(NoteSuggestion(insert: ins, detail: d))
            if isCol, list.count == 1, let v = ctx.values[ins], !v.isEmpty { list.append(NoteSuggestion(insert: "\(ins)=\(v)", detail: "this stock's value")) }
        }
        out.list = list
        if let top = scored.first, top.0.lowercased().hasPrefix(q) {
            out.ghost = String(top.0.dropFirst(partial.count))
        }
        if !wholeGhost.isEmpty, out.ghost.isEmpty || wholeGhost.hasPrefix(out.ghost) { out.ghost = wholeGhost }
        return out
    }
}

// MARK: - The stock's values before the move, and how they ranked that day

enum NoteData {
    static func load(_ e: MBEvent, current: SheetTable, label: Int) async -> (day: String, today: Bool, values: [String: String], rank: [String: Double]) {
        await Task.detached(priority: .userInitiated) { () -> (String, Bool, [String: String], [String: Double]) in
            var table = current, day = "today", isToday = true
            if let d = HistoryStore.days().last(where: { $0 <= e.baseDay }), let data = HistoryStore.load(d),
               let t = ScreenerViewModel.align(data, to: current) { table = t; day = d; isToday = false }
            guard let row = table.rows.first(where: { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() == e.symbol }) else {
                return (day, isToday, [:], [:])
            }
            var values: [String: String] = [:], rank: [String: Double] = [:]
            for (i, h) in table.headers.enumerated() {
                values[h] = row.text(i)
                guard i != label, let v = row.number(i) else { continue }
                var below = 0, equal = 0, n = 0
                for r in table.rows { if let x = r.number(i) { n += 1; if x < v { below += 1 } else if x == v { equal += 1 } } }
                if n >= 20 { rank[h] = (Double(below) + Double(equal) / 2) / Double(n) }
            }
            return (day, isToday, values, rank)
        }.value
    }
}

// MARK: - Text view with grey "ghost" text

final class GhostTextView: NSTextView {
    enum Key { case tab, up, down, enter, escape }
    var ghost = "" { didSet { if ghost != oldValue { needsDisplay = true } } }
    var onKey: ((Key) -> Bool)?

    override func insertTab(_ sender: Any?) { if onKey?(.tab) == true { return }; window?.selectNextKeyView(nil) }
    override func moveUp(_ sender: Any?) { if onKey?(.up) == true { return }; super.moveUp(sender) }
    override func moveDown(_ sender: Any?) { if onKey?(.down) == true { return }; super.moveDown(sender) }
    override func insertNewline(_ sender: Any?) { if onKey?(.enter) == true { return }; super.insertNewline(sender) }
    override func cancelOperation(_ sender: Any?) { _ = onKey?(.escape) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !ghost.isEmpty, selectedRange().length == 0, let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let loc = selectedRange().location
        guard loc == ns.length || ns.character(at: loc) == 10 else { return }
        let f = font ?? .systemFont(ofSize: 13)
        var p = NSPoint(x: textContainerOrigin.x + tc.lineFragmentPadding, y: textContainerOrigin.y)
        if loc > 0 {
            if ns.character(at: loc - 1) == 10 {
                let lf = lm.extraLineFragmentRect
                p = NSPoint(x: textContainerOrigin.x + tc.lineFragmentPadding, y: textContainerOrigin.y + lf.minY)
            } else {
                let gi = lm.glyphIndexForCharacter(at: loc - 1)
                let r = lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc)
                let line = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
                p = NSPoint(x: textContainerOrigin.x + r.maxX, y: textContainerOrigin.y + line.minY)
            }
        }
        (ghost as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor])
    }
}

struct GhostTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursor: Int
    var setVersion: Int                  // bump to push `text` + `cursor` into the view
    var ghost: String
    var onKey: (GhostTextView.Key) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let tv = GhostTextView(frame: .zero)
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 14)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        tv.delegate = context.coordinator
        scroll.documentView = tv
        context.coordinator.applied = setVersion
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv); tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? GhostTextView else { return }
        if context.coordinator.applied != setVersion {
            context.coordinator.applied = setVersion
            if tv.string != text { tv.string = text }
            let c = min(cursor, (tv.string as NSString).length)
            tv.setSelectedRange(NSRange(location: c, length: 0))
            tv.scrollRangeToVisible(NSRange(location: c, length: 0))
            if tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
        }
        tv.ghost = ghost
        tv.onKey = onKey
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GhostTextEditor
        var applied = 0
        init(_ p: GhostTextEditor) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            parent.cursor = tv.selectedRange().location
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            let c = tv.selectedRange().location
            DispatchQueue.main.async { [weak self] in if self?.parent.cursor != c { self?.parent.cursor = c } }
        }
    }
}

// MARK: - The floating note box

struct MBNoteView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var focus = MBNoteFocus.shared
    @ObservedObject private var store = MBNoteStore.shared
    @State private var text = ""
    @State private var cursor = 0
    @State private var setVersion = 0
    @State private var selected: Int?
    @State private var listHidden = false
    @State private var ctx = NoteContext(columns: [])
    @State private var valuesDay = ""

    private var columns: [String] {
        let f = vm.filterColumnIndices.map { vm.headers[$0] }
        return f + vm.headers.filter { !f.contains($0) }
    }

    private var company: String? {
        guard let e = focus.event, let l = vm.labelIndex, let n = vm.companyNameIndex else { return nil }
        let name = vm.table.rows.first { $0.text(l).trimmingCharacters(in: .whitespaces).uppercased() == e.symbol }?.text(n)
        return name?.trimmingCharacters(in: .whitespaces).isEmpty == false ? name : nil
    }

    var body: some View {
        let ns = text as NSString
        let before = ns.substring(to: min(cursor, ns.length))
        let comp = focus.event == nil ? NoteCompletion() : NoteCompleter.complete(before, ctx: ctx, model: store.model(excluding: focus.event?.id))
        let list = listHidden ? [] : comp.list
        let pieces = NoteChecker.pieces(text, columns: ctx.columns, values: ctx.values)
        VStack(alignment: .leading, spacing: 6) {
            if let e = focus.event {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(e.symbol).font(.headline)
                    if let company { Text(company).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    Text("\(e.monthTitle) \(String(format: "%+.0f%%", e.gain))").font(.caption.bold()).foregroundStyle(.green)
                }
                GhostTextEditor(text: $text, cursor: $cursor, setVersion: setVersion, ghost: comp.ghost, onKey: { key(key: $0, comp: comp, list: list) })
                    .frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.offset) { i, s in
                            HStack {
                                Text(s.insert).font(.callout.monospaced()).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(s.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(selected == i ? Color.accentColor.opacity(0.25) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { accept(s, comp) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }
                if !pieces.isEmpty {
                    FlowLayout(spacing: 4, lineSpacing: 3) {
                        ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                            Text("\(p.canonical) \(p.ok == true ? "✓" : (p.ok == false ? "✗" : "?"))")
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill((p.ok == true ? Color.green : (p.ok == false ? Color.red : Color.gray)).opacity(0.15)))
                                .help(p.ok == nil ? "No value for \(p.column) here" : "\(p.column) was \(ctx.values[p.column] ?? "—") \(valuesDay)")
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("Tab = grey text · ↑↓ Return = list · saved").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(valuesDay).font(.caption2).foregroundStyle(.secondary)
                    Button("All notes (\(store.ordered.count))") { QuickFPanel.shared.openCombos?() }.buttonStyle(.link).font(.caption2)
                }
            } else {
                Text("Open a multibagger in the Chart Reel (or select one in Multibaggers) — its note appears here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: 430)
        .task(id: focus.event?.id) { await loadEvent() }
        .onChange(of: text) { t in
            listHidden = false
            selected = nil
            if let e = focus.event { store.set(t, for: e) }
        }
        .onChange(of: cursor) { _ in selected = nil }
    }

    private func loadEvent() async {
        guard let e = focus.event else { return }
        let t = store.text(for: e)
        text = t; cursor = (t as NSString).length; setVersion &+= 1
        ctx = NoteContext(columns: columns)
        guard let label = vm.labelIndex else { return }
        let r = await NoteData.load(e, current: vm.table, label: label)
        guard focus.event?.id == e.id else { return }
        ctx = NoteContext(columns: columns, values: r.values, rank: r.rank)
        valuesDay = r.today ? "today's values (no stored day before the move)" : "values on \(r.day)"
    }

    private func key(key: GhostTextView.Key, comp: NoteCompletion, list: [NoteSuggestion]) -> Bool {
        switch key {
        case .tab:
            if !comp.ghost.isEmpty { insertAtCursor(comp.ghost); return true }
            if let s = list.first { accept(s, comp); return true }
            return false
        case .down:
            guard !list.isEmpty else { return false }
            selected = min((selected ?? -1) + 1, list.count - 1); return true
        case .up:
            guard !list.isEmpty, let s = selected else { return false }
            selected = s == 0 ? nil : s - 1; return true
        case .enter:
            if let s = selected, list.indices.contains(s) { accept(list[s], comp); return true }
            return false
        case .escape:
            listHidden = true; selected = nil; return true
        }
    }

    private func insertAtCursor(_ s: String) {
        let ns = text as NSString
        let c = min(cursor, ns.length)
        text = ns.replacingCharacters(in: NSRange(location: c, length: 0), with: s)
        cursor = c + (s as NSString).length
        setVersion &+= 1
    }

    private func accept(_ s: NoteSuggestion, _ comp: NoteCompletion) {
        let ns = text as NSString
        let c = min(cursor, ns.length)
        let before = ns.substring(to: c)
        let start = max(0, c - (String(before.suffix(comp.partialLength)) as NSString).length)
        let nextIsSpace = c < ns.length && (ns.character(at: c) == 32)
        let ins = s.insert + (nextIsSpace ? "" : " ")
        text = ns.replacingCharacters(in: NSRange(location: start, length: c - start), with: ins)
        cursor = start + (ins as NSString).length
        selected = nil
        setVersion &+= 1
    }
}

// MARK: - Testing patterns from many notes at once

enum MBBatch {
    /// Each formula checked on every multibagger's stored day just before its move (and all stocks that day).
    static func evaluate(_ formulas: [String], events: [MBEvent], current: SheetTable, label: Int) -> [MBComboResult?] {
        let days = HistoryStore.days()
        var byDay: [String: [MBEvent]] = [:]
        for e in events { if let d = days.last(where: { $0 <= e.baseDay }) { byDay[d, default: []].append(e) } }
        var caught = [Int](repeating: 0, count: formulas.count), matches = caught, judged = 0, ok = [Bool](repeating: false, count: formulas.count)
        for (d, evs) in byDay {
            guard let data = HistoryStore.load(d), let t = ScreenerViewModel.align(data, to: current) else { continue }
            var bySym: [String: SheetRow] = [:]
            for r in t.rows { bySym[r.text(label).trimmingCharacters(in: .whitespaces).uppercased()] = r }
            judged += evs.count
            for (i, f) in formulas.enumerated() {
                guard let p = try? Formula.compile(f, table: t).predicate else { continue }
                ok[i] = true
                matches[i] += t.rows.filter(p).count
                caught[i] += evs.filter { bySym[$0.symbol].map(p) ?? false }.count
            }
        }
        return formulas.indices.map { ok[$0] ? MBComboResult(caught: caught[$0], judged: judged, matches: matches[$0], ranAt: Date()) : nil }
    }
}

enum NotePatterns {
    struct Pattern: Identifiable { var id: String { text }; let pieces: [String]; let notes: Int; var text: String { pieces.joined(separator: " + ") } }

    /// Recognised pieces that keep appearing together in your notes (singles, pairs, triples), most frequent first.
    static func find(_ notes: [String], columns: [String], limit: Int = 20) -> [Pattern] {
        var count: [[String]: Int] = [:]
        for n in notes {
            let ps = Array(Set(NoteChecker.pieces(n, columns: columns, values: [:]).map(\.canonical))).sorted().prefix(8)
            let a = Array(ps)
            for i in a.indices {
                count[[a[i]], default: 0] += 1
                for j in (i + 1)..<a.count {
                    count[[a[i], a[j]], default: 0] += 1
                    for k in (j + 1)..<a.count { count[[a[i], a[j], a[k]], default: 0] += 1 }
                }
            }
        }
        return count.filter { $0.value >= 2 }
            .sorted { ($0.value, $0.key.count) > ($1.value, $1.key.count) }
            .prefix(limit).map { Pattern(pieces: $0.key, notes: $0.value) }
    }
}

// MARK: - Window: all notes + patterns

struct MBNotesWindow: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var store = MBNoteStore.shared
    @ObservedObject private var c = MBFilterCenter.shared
    @AppStorage("mb.fOn") private var fOn = false
    @State private var search = ""
    struct Tested: Identifiable { let pattern: NotePatterns.Pattern; let result: MBComboResult?; var id: String { pattern.id } }
    @State private var patterns: [Tested] = []
    @State private var finding = false
    static let enough = 20

    private var columns: [String] { vm.headers }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Notes (\(store.ordered.count))").font(.headline)
                    Spacer()
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                }
                .padding(10)
                List {
                    ForEach(store.ordered.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.symbol.localizedCaseInsensitiveContains(search) }) { n in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(n.symbol).font(.callout.bold())
                                Text("\(MBEngine.monthTitle(n.month)) \(String(format: "%+.0f%%", n.gain))").font(.caption).foregroundStyle(.green)
                                Spacer()
                                Button("Chart") { openInReel(n.id) }.controlSize(.small)
                                Menu {
                                    Button("Delete note", role: .destructive) { store.delete(n.id) }
                                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                            }
                            TextField("", text: Binding(get: { store.notes[n.id]?.text ?? "" }, set: { store.set($0, id: n.id) }), axis: .vertical)
                                .textFieldStyle(.plain).font(.callout).lineLimit(1...6)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 420, idealWidth: 480)

            VStack(alignment: .leading, spacing: 10) {
                Text("Patterns in your notes").font(.headline)
                let n = store.ordered.count
                if n < Self.enough {
                    ProgressView(value: Double(n), total: Double(Self.enough))
                    Text("\(n) of \(Self.enough) notes — patterns get meaningful once you've written about \(Self.enough) moves. Pieces like count>5, compact, D_TRIGGER are recognised from your Filter titles.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button { find() } label: { Label(n < Self.enough ? "Find now anyway" : "Find & test patterns", systemImage: "sparkle.magnifyingglass") }
                        .disabled(finding || n < 2)
                    if finding { ProgressView().controlSize(.small) }
                }
                if !patterns.isEmpty {
                    List {
                        ForEach(patterns) { t in
                            let p = t.pattern, r = t.result
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(p.text).font(.callout.monospaced())
                                    Spacer()
                                    Text("in \(p.notes) notes").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    if let r { Text(r.text).font(.caption).foregroundStyle(.green) } else { Text("couldn't test (no stored days or column missing)").font(.caption).foregroundStyle(.orange) }
                                    Spacer()
                                    Button("Show in reel") { show(p) }.controlSize(.small).disabled(r == nil)
                                    Button("Save") { save(p) }.controlSize(.small).disabled(r == nil)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.inset)
                    Text("Tested on each multibagger's stored day just before its move. Hit rate = share of all stocks matching that day that went on to be a multibagger.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Spacer()
                }
            }
            .padding(12)
            .frame(minWidth: 460)
        }
        .navigationTitle("F Notes")
        .onAppear { MultibaggerCenter.shared.loadIfNeeded() }
    }

    private func find() {
        guard let label = vm.labelIndex else { return }
        let found = NotePatterns.find(store.ordered.map(\.text), columns: columns)
        let formulas = found.map { (try? QuickF.formula($0.text, headers: vm.headers)) ?? "" }
        let events = MBFilterCenter.scopedEvents(vm: vm), current = vm.table
        finding = true
        Task {
            let res = await Task.detached(priority: .userInitiated) { MBBatch.evaluate(formulas, events: events, current: current, label: label) }.value
            patterns = zip(found, res).map { Tested(pattern: $0, result: $1) }.sorted { ($0.result?.hitRate ?? -1) > ($1.result?.hitRate ?? -1) }
            finding = false
        }
    }

    private func show(_ p: NotePatterns.Pattern) {
        guard let f = try? QuickF.formula(p.text, headers: vm.headers) else { return }
        c.group = .formula(f); c.activeCombo = nil
        c.run(events: MBFilterCenter.scopedEvents(vm: vm), vm: vm)
        fOn = true
        let d = UserDefaults.standard
        d.set(ReelSource.multibaggers.rawValue, forKey: "reel.source")
        d.set("", forKey: "reel.mbMonth")
        d.set(UUID().uuidString + "|", forKey: "reel.jump")
        openWindow(id: "reel")
    }

    private func save(_ p: NotePatterns.Pattern) {
        guard let f = try? QuickF.formula(p.text, headers: vm.headers) else { return }
        c.group = .formula(f)
        c.saveAsNew(p.text)
        if let id = c.activeCombo, let i = c.combos.firstIndex(where: { $0.id == id }) {
            c.combos[i].note = p.text
            c.combos[i].result = patterns.first { $0.id == p.id }?.result
        }
    }

    private func openInReel(_ id: String) {
        fOn = false
        let d = UserDefaults.standard
        d.set(ReelSource.multibaggers.rawValue, forKey: "reel.source")
        d.set("", forKey: "reel.mbMonth")
        d.set(id, forKey: "reel.mbStart")
        d.set(UUID().uuidString + "|" + id, forKey: "reel.jump")
        openWindow(id: "reel")
    }
}
