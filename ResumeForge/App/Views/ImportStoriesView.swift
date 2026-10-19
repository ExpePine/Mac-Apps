import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Import stories you already wrote: pick or drop files (Word, PDF, text/Markdown, RTF, CSV, JSON) or paste text,
/// review what was found, then add the ones you want. Every story stays fully editable afterwards.
struct ImportStoriesSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    struct Candidate: Identifiable {
        var id = UUID()
        var story: Story
        var include = true
        var duplicate = false
        var source: String
    }

    @State private var files: [URL] = []
    @State private var pasted = ""
    @State private var useAI = !Keychain.load().isEmpty
    @State private var candidates: [Candidate] = []
    @State private var working = false
    @State private var status = ""
    @State private var dropTargeted = false
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(reviewing ? "Review imported stories" : "Import your stories").font(.title2.bold())
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)
            Divider()
            if reviewing { reviewStep } else { inputStep }
        }
        .frame(width: 760, height: 640)
    }

    // MARK: Step 1 — files or pasted text

    private var inputStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring in stories you've already written. Word, PDF, text/Markdown, RTF, CSV and JSON files work, and one file can hold many stories. You'll review everything before it's added.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Image(systemName: "doc.on.doc").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(files.isEmpty ? "Drop files here" : "\(files.count) file\(files.count == 1 ? "" : "s") selected")
                    .font(.headline)
                Button("Choose files…") { chooseFiles() }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
            .dropDestination(for: URL.self) { urls, _ in
                add(urls)
                return true
            } isTargeted: { dropTargeted = $0 }

            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(files, id: \.self) { url in
                        HStack {
                            Image(systemName: "doc")
                            Text(url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button { files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                        }
                        .font(.callout)
                    }
                }
            }

            Text("…or paste text").font(.headline)
            TextEditor(text: $pasted)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Toggle(isOn: $useAI) {
                Text("Use AI to find the separate stories (keeps your wording)")
            }
            .disabled(Keychain.load().isEmpty)
            .help(Keychain.load().isEmpty ? "Add a Groq key in Settings to enable this." : "")
            Text(useAI
                 ? "Groq splits the text into stories and fills in company, period, metrics and skills where you mention them. It's told not to rewrite anything you wrote."
                 : "Without AI, each heading (# Title, \"Story 1:\") or block separated by two blank lines becomes one story.")
                .font(.caption).foregroundStyle(.secondary)

            Spacer(minLength: 0)
            HStack {
                Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Find stories") { readAll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || (files.isEmpty && pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(20)
    }

    // MARK: Step 2 — review

    private var reviewStep: some View {
        VStack(spacing: 0) {
            HStack {
                let n = candidates.filter(\.include).count
                Text("\(candidates.count) found · \(n) selected")
                if candidates.contains(where: \.duplicate) {
                    Text("· duplicates are unticked").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select all") { for i in candidates.indices { candidates[i].include = true } }
                Button("Select none") { for i in candidates.indices { candidates[i].include = false } }
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
            List {
                ForEach($candidates) { $c in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: $c.include).labelsHidden()
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("Title", text: $c.story.title).font(.headline)
                                if c.duplicate { Pill(text: "already in your stories", color: .orange) }
                            }
                            HStack {
                                TextField("Company", text: $c.story.company)
                                TextField("Period", text: $c.story.period).frame(width: 140)
                            }
                            .font(.callout)
                            Text(c.story.text)
                                .font(.callout).foregroundStyle(.secondary)
                                .lineLimit(4)
                            Text("from \(c.source)\(c.story.metrics.isEmpty ? "" : " · \(c.story.metrics.count) metrics")")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                    .opacity(c.include ? 1 : 0.55)
                }
            }
            Divider()
            HStack {
                Text("You can edit every story in full after adding.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Back") { reviewing = false }
                Button("Add \(candidates.filter(\.include).count) stories") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!candidates.contains(where: \.include))
            }
            .padding(16)
        }
    }

    // MARK: Actions

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = StoryImport.allowedTypes
        panel.message = "Choose files with your stories"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        for u in urls where !files.contains(u) { files.append(u) }
        status = ""
    }

    private func readAll() {
        working = true
        status = "Reading…"
        let urls = files
        let text = pasted
        let ai = useAI
        Task { @MainActor in
            defer { working = false }
            var found: [Candidate] = []
            var problems: [String] = []
            for url in urls {
                status = "Reading \(url.lastPathComponent)…"
                do {
                    switch try StoryImport.read(url) {
                    case .stories(let s):
                        found += s.map { Candidate(story: $0, source: url.lastPathComponent) }
                    case .text(let t):
                        let s = try await store.parseStories(from: t, source: url.lastPathComponent, useAI: ai) { status = $0 }
                        found += s.map { Candidate(story: $0, source: url.lastPathComponent) }
                    }
                } catch {
                    problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let s = try await store.parseStories(from: text, source: "pasted text", useAI: ai) { status = $0 }
                    found += s.map { Candidate(story: $0, source: "pasted text") }
                } catch {
                    problems.append("Pasted text: \(error.localizedDescription)")
                }
            }

            // Mark duplicates — against your existing stories and within this import.
            var seen = Set(store.data.stories.map(StoryImport.fingerprint))
            for i in found.indices {
                let fp = StoryImport.fingerprint(found[i].story)
                if seen.contains(fp) { found[i].duplicate = true; found[i].include = false }
                seen.insert(fp)
            }

            candidates = found
            if found.isEmpty {
                status = problems.isEmpty ? "No stories found. Try turning AI on, or add headings between stories." : problems.joined(separator: " · ")
            } else {
                status = problems.joined(separator: " · ")
                reviewing = true
            }
        }
    }

    private func commit() {
        let now = Date()
        let chosen = candidates.filter(\.include).map { c -> Story in
            var s = c.story
            s.id = UUID()
            s.origin = "file"
            s.createdAt = now
            s.updatedAt = now
            if s.title.isEmpty { s.title = "Imported story" }
            return s
        }
        store.data.stories.insert(contentsOf: chosen, at: 0)
        store.selectedStoryID = chosen.first?.id
        dismiss()
    }
}

// MARK: - Export (backup, or edit elsewhere and re-import)

enum StoryExport {
    @MainActor
    static func export(_ stories: [Story], asMarkdown: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = asMarkdown ? [UTType(filenameExtension: "md") ?? .plainText] : [.json]
        panel.nameFieldStringValue = asMarkdown ? "My stories.md" : "My stories.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if asMarkdown {
                try StoryImport.markdownExport(stories).write(to: url, atomically: true, encoding: .utf8)
            } else {
                let enc = JSONEncoder()
                enc.dateEncodingStrategy = .iso8601
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(stories).write(to: url, options: .atomic)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
