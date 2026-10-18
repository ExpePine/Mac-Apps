import SwiftUI
import AppKit

/// "Notes & Scripts": MV2 Build Requirements documents and Pine Script files, in a plain-text editor
/// (copy / paste, undo, ⌘F find & replace). Saved automatically as files you can also open in Finder.
struct NotesView: View {
    @State private var kind: TextDoc.Kind = .requirements
    @State private var docs: [TextDoc] = []
    @State private var selected: TextDoc?
    @State private var text = ""
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?
    @State private var renaming = false
    @State private var newName = ""
    @State private var status = ""
    @State private var cursor = "Ln 1, Col 1"

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if selected != nil {
                    CodeEditor(text: Binding(get: { text }, set: { text = $0; scheduleSave() }),
                               highlightPine: kind == .pine,
                               docID: selected?.id ?? "",
                               onCursor: { cursor = $0 })
                } else {
                    Text("Create a document with +").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(text.count) characters · \(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines · \(cursor)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .navigationTitle(kind.title)
        .onAppear { reload(select: nil) }
        .onChange(of: kind) { _ in saveNow(); reload(select: nil) }
        .onDisappear { saveNow() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $kind) {
                Text("MV2 Requirements").tag(TextDoc.Kind.requirements)
                Text("Pine Scripts").tag(TextDoc.Kind.pine)
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            List(selection: Binding(get: { selected }, set: { d in open(d) })) {
                ForEach(docs) { doc in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.name).lineLimit(1)
                        Text(doc.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(doc)
                    .contextMenu {
                        Button("Rename") { open(doc); newName = doc.name; renaming = true }
                        Button("Duplicate") { duplicate(doc) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { trash(doc) }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { newDoc() } label: { Image(systemName: "plus") }.help(kind == .pine ? "New Pine script" : "New requirements document")
                Button { if let d = selected { trash(d) } } label: { Image(systemName: "minus") }.disabled(selected == nil)
                Spacer()
                Button { NSWorkspace.shared.open(TextDocStore.folder(kind)) } label: { Image(systemName: "folder") }
                    .help("Open the folder in Finder")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if renaming {
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    .onSubmit { commitRename() }
                Button("Rename") { commitRename() }
                Button("Cancel") { renaming = false }
            } else {
                Text(selected?.name ?? "").font(.headline)
                    .onTapGesture(count: 2) { if let d = selected { newName = d.name; renaming = true } }
                    .help("Double-click to rename")
            }
            Spacer()
            Button { copyAll() } label: { Label("Copy all", systemImage: "doc.on.doc") }
                .disabled(text.isEmpty)
                .help(kind == .pine ? "Copy the whole script — paste it into TradingView's Pine Editor" : "Copy the whole document")
            Button { pasteReplace() } label: { Label("Replace with clipboard", systemImage: "doc.on.clipboard") }
                .disabled(selected == nil)
                .help("Replace this document with the text on the clipboard (undo with ⌘Z)")
        }
        .controlSize(.small)
        .padding(8)
    }

    // MARK: Actions

    private func reload(select name: String?) {
        docs = TextDocStore.list(kind)
        let target = name.flatMap { n in docs.first { $0.name == n } } ?? docs.first
        open(target, save: false)
    }

    private func open(_ doc: TextDoc?, save: Bool = true) {
        if save { saveNow() }
        selected = doc
        text = doc.map(TextDocStore.read) ?? ""
        dirty = false
        renaming = false
        status = doc.map { "Saved in \($0.url.deletingLastPathComponent().lastPathComponent)" } ?? ""
    }

    private func scheduleSave() {
        dirty = true
        status = "Editing…"
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        guard dirty, let doc = selected else { return }
        TextDocStore.write(text, to: doc)
        dirty = false
        status = "Saved \(Date().formatted(date: .omitted, time: .standard))"
    }

    private func newDoc() {
        saveNow()
        let name = kind == .pine ? "New script" : "Requirements"
        if let d = try? TextDocStore.create(kind, name: name, text: kind == .pine ? TextDocStore.pineTemplate : TextDocStore.requirementsTemplate) {
            reload(select: d.name)
            newName = d.name
            renaming = true
        }
    }

    private func duplicate(_ doc: TextDoc) {
        saveNow()
        if let d = try? TextDocStore.create(kind, name: doc.name + " copy", text: TextDocStore.read(doc)) { reload(select: d.name) }
    }

    private func trash(_ doc: TextDoc) {
        if doc == selected { dirty = false }
        TextDocStore.delete(doc)
        reload(select: nil)
    }

    private func commitRename() {
        saveNow()
        guard let doc = selected, !newName.trimmingCharacters(in: .whitespaces).isEmpty,
              let renamed = TextDocStore.rename(doc, to: newName) else { renaming = false; return }
        reload(select: renamed.name)
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied \(text.count) characters"
    }

    private func pasteReplace() {
        guard let s = NSPasteboard.general.string(forType: .string) else { status = "No text on the clipboard"; return }
        NotificationCenter.default.post(name: CodeEditor.replaceAll, object: s)
    }
}

/// NSTextView subclass so the ⌘F router can recognise the editor.
final class EditorTextView: NSTextView {
    static let editorID = NSUserInterfaceItemIdentifier("StockScreener.Editor")
}

/// Plain-text editor: monospaced, undo, find & replace bar, optional Pine Script colouring.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var highlightPine: Bool
    var docID: String
    var onCursor: (String) -> Void
    static let replaceAll = Notification.Name("StockScreener.Editor.replaceAll")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let old = scroll.documentView as! NSTextView
        let tv = EditorTextView(frame: old.frame, textContainer: old.textContainer)
        tv.identifier = EditorTextView.editorID
        tv.minSize = old.minSize; tv.maxSize = old.maxSize
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.delegate = context.coordinator
        tv.string = text
        context.coordinator.textView = tv
        context.coordinator.docID = docID
        context.coordinator.highlight()
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: Self.replaceAll, object: nil, queue: .main) { [weak tv] note in
            guard let tv, tv.window?.isKeyWindow == true, let s = note.object as? String else { return }
            let range = NSRange(location: 0, length: (tv.string as NSString).length)
            if tv.shouldChangeText(in: range, replacementString: s) {
                tv.replaceCharacters(in: range, with: s)
                tv.didChangeText()
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if c.docID != docID || tv.string != text && !c.isEditing {
            c.docID = docID
            tv.string = text
            tv.undoManager?.removeAllActions()
            c.highlight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        var docID = ""
        var isEditing = false
        var observer: NSObjectProtocol?
        init(_ p: CodeEditor) { parent = p }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            isEditing = true
            parent.text = tv.string
            isEditing = false
            highlight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            let loc = tv.selectedRange().location
            let s = tv.string as NSString
            let upTo = s.substring(to: min(loc, s.length))
            let line = upTo.components(separatedBy: "\n").count
            let col = (upTo.components(separatedBy: "\n").last?.count ?? 0) + 1
            parent.onCursor("Ln \(line), Col \(col)")
        }

        private static let keywords = try! NSRegularExpression(pattern:
            "\\b(if|else|for|to|by|while|switch|var|varip|import|export|method|type|true|false|na|and|or|not|return|continue|break|series|simple|const|int|float|bool|string|color|line|label|box|table|array|matrix|map)\\b")
        private static let builtins = try! NSRegularExpression(pattern:
            "\\b(indicator|strategy|library|plot|plotshape|plotchar|hline|fill|bgcolor|barcolor|alertcondition|alert|input|ta|math|request|str|timeframe|syminfo|close|open|high|low|volume|time|bar_index)\\b")
        private static let numbers = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
        private static let strings = try! NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\\])*\"|'(\\\\.|[^'\\\\])*'")
        private static let comments = try! NSRegularExpression(pattern: "//[^\\n]*")

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                   .foregroundColor: NSColor.textColor], range: full)
            if parent.highlightPine && storage.length < 300_000 {
                let s = storage.string
                func paint(_ re: NSRegularExpression, _ color: NSColor, bold: Bool = false) {
                    for m in re.matches(in: s, range: full) {
                        storage.addAttribute(.foregroundColor, value: color, range: m.range)
                        if bold { storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), range: m.range) }
                    }
                }
                paint(Self.keywords, .systemPurple, bold: true)
                paint(Self.builtins, .systemBlue)
                paint(Self.numbers, .systemOrange)
                paint(Self.strings, .systemGreen)
                paint(Self.comments, .secondaryLabelColor)
            }
            storage.endEditing()
        }
    }
}
