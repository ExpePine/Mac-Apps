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
        Button { QuickFPanel.shared.toggle(vm, openCombos: { openWindow(id: "mbnotes") }) } label: { FBadge(on: fOn && c.ready) }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("F: a small floating note box for the stock on screen — write in your own words; it autocompletes from Filter titles, this stock's values and your past notes (⇧⌘F)")
    }
}
