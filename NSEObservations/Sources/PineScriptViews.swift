import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Library page

struct PineScriptsView: View {
    @EnvironmentObject private var store: Store
    var openSymbol: (UUID) -> Void

    @State private var selectedID: UUID?
    @State private var addingScript = false

    var body: some View {
        HStack(spacing: 0) {
            scriptList
                .frame(width: 210)
            Divider()
            Group {
                if let id = selectedID, store.script(id) != nil {
                    ScriptDetail(scriptID: id, openSymbol: openSymbol).id(id)
                } else {
                    EmptyStateView(systemImage: "chevron.left.forwardslash.chevron.right",
                                   title: store.data.scripts.isEmpty ? "No Pine Scripts yet" : "Select a script",
                                   message: "Keep every version of your TradingView Pine Scripts in one place: paste or import a file, note what changed, and compare versions line by line.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Pine Scripts")
        .toolbar {
            ToolbarItem {
                Button { addingScript = true } label: { Label("New Script", systemImage: "plus") }
                    .help("New Pine Script")
            }
        }
        .sheet(isPresented: $addingScript) {
            NewScriptSheet { id in selectedID = id }.environmentObject(store)
        }
        .onAppear {
            if selectedID == nil { selectedID = store.scriptsByRecent.first?.id }
        }
    }

    private var scriptList: some View {
        List(selection: $selectedID) {
            ForEach(store.scriptsByRecent) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.body.weight(.medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("v\(s.latest?.number ?? 0)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                        Text(Fmt.day.string(from: s.updatedAt)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(Optional(s.id))
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { addingScript = true } label: { Label("New Script", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                Button { store.revealFolder(store.scriptsFolder) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Show the PineScripts folder in Finder")
            }
            .padding(10)
            .background(.bar)
        }
    }
}

// MARK: - New script

struct NewScriptSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    var onCreate: (UUID) -> Void

    @State private var name = ""
    @State private var notes = ""
    @State private var code = ""
    @State private var note = "First version"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Pine Script").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. EMA Pullback Strategy"))
                TextField("About", text: $notes, prompt: Text("optional — what the script does"))
                TextField("Version note", text: $note)
            }
            CodeInputArea(code: $code) { importedName in
                if name.isEmpty { name = importedName }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    var s = PineScript(name: name.trimmingCharacters(in: .whitespaces))
                    s.notes = notes
                    store.upsert(s)
                    store.addVersion(to: s.id, code: code, note: note)
                    onCreate(s.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
    }
}

/// Code box with Paste and Import File buttons.
struct CodeInputArea: View {
    @Binding var code: String
    var onImport: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pine Script code").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { code = s }
                } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "pine") ?? .plainText, .plainText, .sourceCode]
                    panel.message = "Choose a Pine Script file (.pine or .txt)"
                    if panel.runModal() == .OK, let url = panel.url,
                       let text = try? String(contentsOf: url, encoding: .utf8) {
                        code = text
                        onImport(url.deletingPathExtension().lastPathComponent)
                    }
                } label: { Label("Import File…", systemImage: "square.and.arrow.down") }
            }
            .controlSize(.small)
            TextEditor(text: $code)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }
}

// MARK: - Script detail with version timeline

private struct NewVersionRequest: Identifiable {
    let id = UUID()
    let code: String
    let note: String
}

struct ScriptDetail: View {
    @EnvironmentObject private var store: Store
    let scriptID: UUID
    var openSymbol: (UUID) -> Void

    @State private var selectedVersion: UUID?
    @State private var showDiff = true
    @State private var newVersion: NewVersionRequest?
    @State private var confirmDeleteScript = false
    @State private var confirmDeleteVersion: ScriptVersion?
    @State private var copied = false

    private var script: PineScript? { store.script(scriptID) }
    private var versions: [ScriptVersion] { (script?.versions ?? []).sorted { $0.number > $1.number } }

    var body: some View {
        if let s = script {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    header(s)
                    Text("Version timeline").font(.headline).padding(.top, 4)
                    List(selection: $selectedVersion) {
                        ForEach(versions) { v in
                            VersionRow(version: v, isLatest: v.id == s.latest?.id).tag(Optional(v.id))
                                .contextMenu {
                                    Button("Make This the Latest Version") {
                                        newVersion = NewVersionRequest(code: v.code, note: "Restored from v\(v.number)")
                                    }
                                    Button("Export as .pine…") { store.exportScriptVersion(v, scriptName: s.name) }
                                    Divider()
                                    Button("Delete Version…", role: .destructive) { confirmDeleteVersion = v }
                                }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 220)
                }
                .padding(14)
                .frame(width: 280)

                Divider()
                codePane(s)
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
            .sheet(item: $newVersion) { req in
                NewVersionSheet(scriptID: scriptID, initialCode: req.code, initialNote: req.note) { id in
                    selectedVersion = id
                }
                .environmentObject(store)
            }
            .confirmationDialog("Delete \(s.name) and its whole history?", isPresented: $confirmDeleteScript) {
                Button("Delete Script", role: .destructive) { store.deleteScript(s.id) }
            } message: {
                Text("Files already saved in the PineScripts folder and your safe folder are kept.")
            }
            .confirmationDialog("Delete v\(confirmDeleteVersion?.number ?? 0) from the timeline?",
                                isPresented: Binding(get: { confirmDeleteVersion != nil }, set: { if !$0 { confirmDeleteVersion = nil } }),
                                presenting: confirmDeleteVersion) { v in
                Button("Delete Version", role: .destructive) {
                    store.deleteVersion(v.id, of: s.id)
                    if selectedVersion == v.id { selectedVersion = nil }
                }
            } message: { _ in
                Text("Its saved .pine file stays in the PineScripts folder.")
            }
            .onAppear { if selectedVersion == nil { selectedVersion = s.latest?.id } }
        }
    }

    private func header(_ s: PineScript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Name", text: Binding(
                    get: { store.script(scriptID)?.name ?? "" },
                    set: { var c = s; c.name = $0; store.upsert(c) }))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.bold))
                Menu {
                    Button("Delete Script…", role: .destructive) { confirmDeleteScript = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            TextField("What this script does", text: Binding(
                get: { store.script(scriptID)?.notes ?? "" },
                set: { var c = s; c.notes = $0; store.upsert(c) }), axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1...4)

            HStack(spacing: 6) {
                Menu {
                    ForEach(store.symbols.sorted { $0.ticker < $1.ticker }) { sym in
                        Button {
                            var c = s
                            if c.symbolIDs.contains(sym.id) { c.symbolIDs.removeAll { $0 == sym.id } } else { c.symbolIDs.append(sym.id) }
                            store.upsert(c)
                        } label: {
                            if s.symbolIDs.contains(sym.id) { Label(sym.ticker, systemImage: "checkmark") } else { Text(sym.ticker) }
                        }
                    }
                } label: { Label("Symbols", systemImage: "link") }
                .fixedSize()
                ForEach(s.symbolIDs, id: \.self) { id in
                    if let sym = store.symbol(id) {
                        Button(sym.ticker) { openSymbol(id) }.buttonStyle(.link).font(.caption)
                    }
                }
            }

            Button {
                newVersion = NewVersionRequest(code: s.latest?.code ?? "", note: "")
            } label: {
                Label("Add New Version", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func codePane(_ s: PineScript) -> some View {
        let all = versions
        if let v = all.first(where: { $0.id == selectedVersion }) ?? all.first {
            let previous = all.first { $0.number < v.number }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("v\(v.number)\(v.id == s.latest?.id ? " · latest" : "")").font(.headline)
                        Text("\(Fmt.dayTime.string(from: v.date))\(previous.map { " · vs v\($0.number)" } ?? "")\(v.note.isEmpty ? "" : " — \(v.note)")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if previous != nil {
                        Picker("View", selection: $showDiff) {
                            Text("Changes").tag(true)
                            Text("Full code").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(v.code, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .help("Copy to paste into TradingView's Pine Editor")
                    Button { store.exportScriptVersion(v, scriptName: s.name) } label: { Image(systemName: "square.and.arrow.up") }
                        .help("Export as .pine file")
                }
                .padding(12)
                Divider()
                if showDiff, let prev = previous {
                    DiffView(old: prev.code, new: v.code)
                } else {
                    CodeView(code: v.code)
                }
                if let file = v.fileName {
                    Divider()
                    HStack {
                        Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(.green)
                        Text("Saved as PineScripts/\(file)\(store.mirrorFolderName.map { " · copied to \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder") { store.revealFolder(store.scriptsFolder.appendingPathComponent(file)) }
                            .buttonStyle(.link).font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        } else {
            EmptyStateView(systemImage: "doc.text", title: "No versions", message: "Add a version to start the timeline.")
        }
    }
}

private struct VersionRow: View {
    let version: ScriptVersion
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isLatest ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("v\(version.number)").font(.body.weight(.semibold).monospacedDigit())
                    if let a = version.linesAdded, let r = version.linesRemoved {
                        Text("+\(a)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                        Text("−\(r)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                    }
                    if isLatest {
                        Text("Latest").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                Text(Fmt.dayTime.string(from: version.date)).font(.caption).foregroundStyle(.secondary)
                if !version.note.isEmpty {
                    Text(version.note).font(.caption).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - New version

struct NewVersionSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let scriptID: UUID
    var initialCode: String
    var initialNote: String
    var onAdded: (UUID) -> Void

    @State private var code = ""
    @State private var note = ""
    @State private var date = Date()

    private var unchanged: Bool {
        guard let latest = store.script(scriptID)?.latest else { return false }
        return latest.code == code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Version of \(store.script(scriptID)?.name ?? "Script")").font(.title2.weight(.semibold))
            Form {
                TextField("What changed", text: $note, prompt: Text("e.g. tightened stop to 1.5× ATR, added volume filter"))
                DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
            }
            CodeInputArea(code: $code)
            HStack {
                if unchanged {
                    Label("Same as the latest version — paste or import the updated code.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Version") {
                    if let v = store.addVersion(to: scriptID, code: code, note: note.trimmingCharacters(in: .whitespaces), date: date) {
                        onAdded(v.id)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(unchanged || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .onAppear { code = initialCode; note = initialNote }
    }
}

// MARK: - Code and diff rendering

struct CodeView: View {
    let code: String
    var body: some View {
        let lines = LineDiff.lines(code)
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").foregroundStyle(.tertiary).frame(width: 38, alignment: .trailing)
                        Text(line.isEmpty ? " " : line)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 1)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct DiffView: View {
    let old: String
    let new: String

    var body: some View {
        if let diff = LineDiff.compute(LineDiff.lines(old), LineDiff.lines(new)) {
            let changed = diff.contains { if case .same = $0 { return false } else { return true } }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !changed {
                        Text("No changes from the previous version.").foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(Array(diff.enumerated()), id: \.offset) { _, d in
                        row(d)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            VStack {
                Text("This script is too large to compare line by line. Showing the full code.")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
                CodeView(code: new)
            }
        }
    }

    private func row(_ d: LineDiff) -> some View {
        let (mark, text, color): (String, String, Color) = {
            switch d {
            case .same(let s): return (" ", s, .clear)
            case .added(let s): return ("+", s, .green)
            case .removed(let s): return ("−", s, .red)
            }
        }()
        return HStack(spacing: 8) {
            Text(mark).foregroundStyle(color == .clear ? Color.secondary : color).frame(width: 14)
            Text(text.isEmpty ? " " : text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(color.opacity(0.12))
    }
}
