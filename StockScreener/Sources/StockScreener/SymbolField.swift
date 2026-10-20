import SwiftUI
import AppKit

// MARK: - NSE symbol autocomplete, used by every "type a stock" box in the app
//
// Suggestions come from your sheet, your manual symbols, the NSE delivery files (~every NSE stock) and the long Yahoo
// history — matched on the symbol (prefix first) and the company name. Native macOS completion list:
// ↓ / ↑ to move, Return to pick, Esc to close; keep typing to narrow it.

@MainActor enum SymbolDirectory {
    private static var cache: (key: String, symbols: [String], names: [String: String]) = ("", [], [:])

    /// All known symbols (sorted) and company names, rebuilt only when a source changes size.
    static func entries(_ vm: ScreenerViewModel) -> (symbols: [String], names: [String: String]) {
        let dc = DeliveryCenter.shared.book.series.count, mb = MultibaggerCenter.shared.book.series.count
        let key = "\(vm.table.rows.count)|\(vm.symbolBook.manual.count)|\(dc)|\(mb)|\(vm.headers.count)"
        if cache.key == key { return (cache.symbols, cache.names) }
        var names: [String: String] = [:]
        var set = Set<String>()
        if let l = vm.labelIndex {
            let n = vm.companyNameIndex
            for r in vm.table.rows {
                let s = r.text(l).trimmingCharacters(in: .whitespaces).uppercased()
                guard !s.isEmpty else { continue }
                set.insert(s)
                if let n, names[s] == nil { let c = r.text(n).trimmingCharacters(in: .whitespaces); if !c.isEmpty { names[s] = c } }
            }
        }
        for m in vm.symbolBook.manual { set.insert(m.symbol); if !m.name.isEmpty, names[m.symbol] == nil { names[m.symbol] = m.name } }
        set.formUnion(DeliveryCenter.shared.book.series.keys)
        set.formUnion(MultibaggerCenter.shared.book.series.keys.filter { !$0.hasPrefix("^") })
        let symbols = set.sorted()
        cache = (key, symbols, names)
        return (symbols, names)
    }

    /// Best matches for what's typed: symbols starting with it, then containing it, then company names containing it.
    static func suggestions(_ typed: String, vm: ScreenerViewModel, limit: Int = 12) -> [String] {
        let q = SymbolBook.clean(typed)
        guard !q.isEmpty else { return [] }
        let (symbols, names) = entries(vm)
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) { if out.count < limit, seen.insert(s).inserted { out.append(s) } }
        // binary-search the prefix block
        var lo = 0, hi = symbols.count
        while lo < hi { let m = (lo + hi) / 2; if symbols[m] < q { lo = m + 1 } else { hi = m } }
        var i = lo
        while i < symbols.count, symbols[i].hasPrefix(q), out.count < limit { add(symbols[i]); i += 1 }
        if out.count < limit { for s in symbols where s.contains(q) { add(s); if out.count >= limit { break } } }
        if out.count < limit, q.count >= 3 {
            let lower = typed.lowercased()
            for (s, n) in names where n.lowercased().contains(lower) { add(s); if out.count >= limit { break } }
        }
        return out
    }
}

/// A text field that suggests NSE symbols as you type. `multi` = several symbols separated by commas / spaces.
struct SymbolField: NSViewRepresentable {
    let vm: ScreenerViewModel
    let placeholder: String
    @Binding var text: String
    var multi = false
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.bezelStyle = .roundedBezel
        f.isBordered = true
        f.focusRingType = .default
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

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SymbolField
        private var completing = false
        private var lastLength = 0
        init(_ p: SymbolField) { parent = p }

        /// The symbol being typed: the text after the last comma / space up to the cursor.
        private func token(_ tv: NSTextView) -> (prefix: String, start: Int) {
            let s = tv.string as NSString
            let cursor = tv.selectedRange().location
            guard parent.multi else { return (s.substring(to: min(cursor, s.length)), 0) }
            var start = cursor
            while start > 0 {
                let c = s.character(at: start - 1)
                if c == 44 || c == 32 || c == 10 { break }      // , space newline
                start -= 1
            }
            return (s.substring(with: NSRange(location: start, length: cursor - start)), start)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField, let tv = obj.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            parent.text = f.stringValue
            let grew = f.stringValue.count > lastLength
            lastLength = f.stringValue.count
            guard !completing, grew else { return }
            let tok = token(tv)
            guard tok.prefix.trimmingCharacters(in: .whitespaces).count >= 1 else { return }
            completing = true
            DispatchQueue.main.async { [weak self] in
                tv.complete(nil)
                self?.completing = false
            }
        }

        func control(_ control: NSControl, textView tv: NSTextView, completions words: [String],
                     forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            index.pointee = -1                                 // don't pre-select (typing continues normally)
            let tok = token(tv)
            let matches = SymbolDirectory.suggestions(tok.prefix, vm: parent.vm)
            // NSTextView replaces only `charRange` (its own idea of a word, which stops at & or -): trim what's before it
            let before = max(0, charRange.location - tok.start)
            let typedBefore = (tok.prefix as NSString).substring(to: min(before, (tok.prefix as NSString).length)).uppercased()
            return matches.compactMap { m in
                guard before > 0 else { return m }
                return m.hasPrefix(typedBefore) ? String(m.dropFirst(typedBefore.count)) : nil
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
