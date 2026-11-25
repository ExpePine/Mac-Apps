import SwiftUI
import AppKit

// MARK: - Quick F syntax

/// Short syntax for typing a combination fast:
///   `count>5 + compact + D_TRIGGER`
/// • `+` (or `,`) = AND, `|` = OR inside one part
/// • arithmetic goes in round brackets: `(A+B)>100`, `(DELSMA-M_DELSMA)>5`
/// • `column > 5`, `column = 1`, `column != 0` … any comparison (also ≥ ≤ ≠)
/// • a bare column name = "has a value and isn't 0"
/// • `NOT column` / `!column` = empty or 0
/// Column names are matched to the Filter titles ignoring case; names with spaces work too (`del % > 40`).
enum QuickF {
    private static let ops = [">=", "<=", "!=", "<>", "==", "≥", "≤", "≠", ">", "<", "="]

    /// The AND-separated parts, trimmed: `+`, `,`, `;`, `&`, `&&` and the word `and` (any case, with spaces around).
    static func parts(_ s: String) -> [String] {
        var t = s.replacingOccurrences(of: "&&", with: "+").replacingOccurrences(of: "&", with: "+").replacingOccurrences(of: ";", with: "+")
        t = t.replacingOccurrences(of: #"\s+(?i:and)\s+"#, with: " + ", options: .regularExpression)
        // split on + and , — but not inside brackets, so (A+B)>100 stays one part (sum of two columns)
        var out: [String] = [], cur = "", depth = 0
        for ch in t {
            if ch == "(" || ch == "[" { depth += 1 } else if (ch == ")" || ch == "]") && depth > 0 { depth -= 1 }
            if depth == 0 && (ch == "+" || ch == ",") { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
            let ors = p.replacingOccurrences(of: "||", with: "|")
                .replacingOccurrences(of: #"\s+(?i:or)\s+"#, with: "|", options: .regularExpression)
                .components(separatedBy: "|")
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
                let col = isMath(left) ? try math(left, headers: headers) : try column(left, headers: headers)
                let r: String
                if Double(right.replacingOccurrences(of: ",", with: "")) != nil { r = right.replacingOccurrences(of: ",", with: "") }
                else if isMath(right) { r = try math(right, headers: headers) }
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

    /// Arithmetic inside round brackets: `(A+B)>100`, `(DELSMA-M_DELSMA)/M_DELSMA>0.2`.
    private static func isMath(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).hasPrefix("(") }

    /// Turns `(A + B) * 2` into the Filter formula language: column names (longest match first, so C/DL2C stays one
    /// column) become column tokens; numbers, + − × ÷ and brackets pass through.
    private static func math(_ s: String, headers: [String]) throws -> String {
        let names = headers.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.first != " " && $0.last != " " }
            .sorted { $0.count > $1.count }
        let chars = Array(s)
        var i = 0, out = ""
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        while i < chars.count {
            let ch = chars[i]
            if ch == " " || "+-*/()".contains(ch) { out.append(ch); i += 1; continue }
            if ch.isNumber || ch == "." {
                var j = i; while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                if j >= chars.count || !isWordChar(chars[j]) { out += String(chars[i..<j]); i = j; continue }
            }
            if ch == "[", let close = chars[i...].firstIndex(of: "]") { out += String(chars[i...close]); i = close + 1; continue }
            let rest = String(chars[i...]).lowercased()
            guard let h = names.first(where: { n in
                guard rest.hasPrefix(n.lowercased()) else { return false }
                let end = i + n.count
                return end >= chars.count || !isWordChar(chars[end]) || !isWordChar(chars[end - 1])
            }) else {
                let word = String(chars[i...].prefix { isWordChar($0) || $0 == "%" })
                throw FormulaError(message: "No Filter column “\(word.isEmpty ? String(ch) : word)” in \(s)")
            }
            out += FormulaField.token(for: h)
            i += h.count
        }
        return out
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
            let host = NSHostingController(rootView: MBNoteView().environmentObject(vm))
            host.sizingOptions = [.preferredContentSize]
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 80),
                            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
            p.title = "F — notes"
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
        Button {
            NoteAlerts.open = { openWindow(id: $0) }
            QuickFPanel.shared.toggle(vm, openCombos: { openWindow(id: "mbnotes") })
        } label: { FBadge(on: fOn && c.ready) }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("F: a small floating note box for the stock on screen — write in your own words; it autocompletes from Filter titles, this stock's values and your past notes (⇧⌘F)")
    }
}
