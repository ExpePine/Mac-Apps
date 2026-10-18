import SwiftUI
import AppKit

/// ⌘F / ⌃F routing. A key-down monitor sends the shortcut to whatever the key window wants:
/// the text editor's own find bar (Notes & Scripts), or a table's find bar (Data / Filter).
@MainActor
enum FindRouter {
    private static var handlers: [ObjectIdentifier: () -> Void] = [:]
    private static var monitor: Any?

    static func register(_ window: NSWindow, _ handler: @escaping () -> Void) {
        handlers[ObjectIdentifier(window)] = handler
    }

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.charactersIgnoringModifiers?.lowercased() == "f",
                  mods == .command || mods == .control else { return event }
            guard let window = NSApp.keyWindow else { return event }
            let responder = window.firstResponder
            // Text editors: their own find bar (⌘F). Plain text fields keep ⌃F = "forward one character".
            if let tv = responder as? NSTextView, tv.isEditable {
                if tv.identifier == EditorTextView.editorID {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    tv.performFindPanelAction(item)
                    return nil
                }
                if mods == .control { return event }
            }
            if let handler = handlers[ObjectIdentifier(window)] {
                handler()
                return nil
            }
            return event
        }
    }
}

/// Gives a SwiftUI view its NSWindow.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}

/// Find state for one table.
@MainActor
final class TableFinder: ObservableObject {
    @Published var isVisible = false
    @Published var query = "" { didSet { recompute(keepPosition: false) } }
    @Published private(set) var matches: [FindMatch] = []
    @Published var current = 0
    @Published var focusToken = 0
    private var rows: [SheetRow] = []
    private var columns: [Int] = []

    var currentMatch: FindMatch? { isVisible && !matches.isEmpty ? matches[min(current, matches.count - 1)] : nil }
    var activeQuery: String { isVisible ? query.trimmingCharacters(in: .whitespaces) : "" }

    func show() {
        isVisible = true
        focusToken += 1
    }

    func close() {
        isVisible = false
    }

    /// Call when the shown rows or columns change.
    func update(rows: [SheetRow], columns: [Int]) {
        self.rows = rows
        self.columns = columns
        recompute(keepPosition: true)
    }

    private func recompute(keepPosition: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { matches = []; current = 0; return }
        let previous = currentMatch
        var out: [FindMatch] = []
        for (r, row) in rows.enumerated() {
            for c in columns where row.text(c).range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                out.append(FindMatch(row: r, column: c))
                if out.count >= 50_000 { break }
            }
        }
        matches = out
        if keepPosition, let previous, let i = out.firstIndex(of: previous) { current = i } else { current = 0 }
    }

    func next() { guard !matches.isEmpty else { return }; current = (current + 1) % matches.count }
    func previous() { guard !matches.isEmpty else { return }; current = (current - 1 + matches.count) % matches.count }
}

/// The bar shown above a table while finding.
struct FindBar: View {
    @ObservedObject var finder: TableFinder
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in table", text: $finder.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($focused)
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) { finder.previous() } else { finder.next() }
                    focused = true
                }
            Text(status).font(.caption.monospacedDigit()).foregroundStyle(finder.matches.isEmpty && !finder.query.isEmpty ? .red : .secondary)
                .frame(minWidth: 90, alignment: .leading)
            Button { finder.previous() } label: { Image(systemName: "chevron.up") }
                .disabled(finder.matches.isEmpty).help("Previous match (⇧↩)")
            Button { finder.next() } label: { Image(systemName: "chevron.down") }
                .disabled(finder.matches.isEmpty).help("Next match (↩)")
            Spacer()
            Button("Done") { finder.close() }.keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
        .onAppear { focused = true }
        .onChange(of: finder.focusToken) { _ in focused = true }
    }

    private var status: String {
        if finder.query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if finder.matches.isEmpty { return "No matches" }
        return "\(finder.current + 1) of \(finder.matches.count)\(finder.matches.count >= 50_000 ? "+" : "")"
    }
}
