import AppKit
import SwiftUI

/// JDs you liked, grouped by their auto-classification (role family, domain, seniority, work mode).
struct SavedJDsView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("savedGroupBy") private var groupBy = 0
    @State private var selected: String?

    /// Liked feed jobs plus liked jobs that didn't come from the feed.
    private var items: [(key: String, title: String, company: String, tags: [String], score: Int?, feedID: String?, jobID: UUID?)] {
        var out = store.feed.filter { $0.liked == true }.map {
            (key: "f-" + $0.id, title: $0.title, company: $0.company, tags: $0.classTags, score: $0.match?.score, feedID: Optional($0.id), jobID: $0.jobID)
        }
        for j in store.data.jobs where j.liked == true && j.feedKey == nil {
            out.append((key: "j-" + j.id.uuidString, title: j.title, company: j.company, tags: j.classTags, score: j.match?.score, feedID: nil, jobID: Optional(j.id)))
        }
        return out
    }

    private var groups: [(String, [(key: String, title: String, company: String, tags: [String], score: Int?, feedID: String?, jobID: UUID?)])] {
        let all = items
        let names = Array(Set(all.map { $0.tags.indices.contains(groupBy) ? $0.tags[groupBy] : "Other" })).sorted()
        return names.map { n in (n, all.filter { ($0.tags.indices.contains(groupBy) ? $0.tags[groupBy] : "Other") == n }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Saved JDs").font(.headline)
                    Text("\(items.count)").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Group by", selection: $groupBy) {
                        ForEach(Array(JobClassifier.dimensions.enumerated()), id: \.offset) { i, d in Text(d).tag(i) }
                    }
                    .frame(width: 180)
                }
                .padding(10)
                Divider()
                List(selection: $selected) {
                    ForEach(groups, id: \.0) { name, rows in
                        Section("\(name) · \(rows.count)") {
                            ForEach(rows, id: \.key) { r in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.title).font(.headline).lineLimit(2)
                                        Text(r.company).font(.caption).foregroundStyle(.secondary)
                                        Text(r.tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let s = r.score { Text("\(s)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                }
                                .tag(r.key)
                            }
                        }
                    }
                }
                .overlay {
                    if items.isEmpty {
                        EmptyHint(icon: "heart", title: "No saved JDs yet",
                                  message: "Press ♥ Like on any job in the Job Feed (or on a job's page). Liked JDs collect here, sorted by role, domain, seniority and work mode, and they're checked by the AI first.")
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)

            Group {
                if let key = selected, key.hasPrefix("f-"), let f = store.feed.first(where: { "f-" + $0.id == key }) {
                    FeedDetail(job: f).id(key)
                } else if let key = selected, key.hasPrefix("j-"), let j = store.data.jobs.first(where: { "j-" + $0.id.uuidString == key }) {
                    VStack(spacing: 12) {
                        Text(j.title).font(.title2.bold())
                        Text(j.company).foregroundStyle(.secondary)
                        Button("Open in Jobs") { store.section = .jobs; store.selectedJobID = j.id }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyHint(icon: "heart.text.square", title: "Pick a saved JD", message: "")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A space for good lines — compressed from your stories or written in reaction to a JD.
struct LinesView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var kindFilter = "all"
    @State private var starredOnly = false
    @State private var newText = ""
    @State private var newKind = LineKind.bullet.rawValue
    @State private var copied: UUID?

    private var filtered: [LineItem] {
        let q = search.lowercased()
        return store.lines
            .filter { kindFilter == "all" || $0.kind == kindFilter }
            .filter { !starredOnly || $0.starred }
            .filter { q.isEmpty || ($0.text + " " + $0.tags.joined(separator: " ") + " " + $0.context).lowercased().contains(q) }
            .sorted { ($0.starred ? 1 : 0, $0.createdAt) > ($1.starred ? 1 : 0, $1.createdAt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Lines").font(.title3.bold())
                Text("\(store.lines.count)").foregroundStyle(.secondary)
                Spacer()
                if let s = store.linesStatus { ProgressView().controlSize(.small); Text(s).font(.caption).foregroundStyle(.secondary) }
                Button {
                    store.run("Compressing your stories…") { _ = try await store.compressStories() }
                } label: { Label("Compress my stories", systemImage: "rectangle.compress.vertical") }
                .disabled(store.data.stories.isEmpty || store.linesStatus != nil)
                .help("Turns each story into 2 resume bullets, a one-liner and an opener")
            }
            .padding(10)
            HStack {
                TextField("Search lines or tags", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("", selection: $kindFilter) {
                    Text("All kinds").tag("all")
                    ForEach(LineKind.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 150)
                Toggle("★ only", isOn: $starredOnly).toggleStyle(.checkbox)
                Spacer()
                Text("★ lines are offered to the resume writer as your preferred wording").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            List {
                ForEach(filtered) { l in LineRow(line: l, copied: $copied) }
            }
            .overlay {
                if store.lines.isEmpty {
                    EmptyHint(icon: "text.quote", title: "Your bank of good lines",
                              message: "Press Compress my stories to boil each story down to reusable bullets, one-liners and openers. On any JD, press Lines to get bullets, a summary line and openers written for that job. Or write your own below. Star the best ones.")
                }
            }
            Divider()
            HStack {
                Picker("", selection: $newKind) { ForEach(LineKind.allCases) { Text($0.label).tag($0.rawValue) } }
                    .labelsHidden().frame(width: 150)
                TextField("Write a line you like…", text: $newText).onSubmit(add)
                Button("Add", action: add).disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
        }
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var l = LineItem()
        l.text = t
        l.kind = newKind
        l.context = "Written by you"
        store.addLines([l])
        newText = ""
    }
}

struct LineRow: View {
    @EnvironmentObject var store: AppStore
    let line: LineItem
    @Binding var copied: UUID?
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { toggleStar() } label: { Image(systemName: line.starred ? "star.fill" : "star").foregroundStyle(line.starred ? .yellow : .secondary) }
                .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    TextField("", text: $draft, axis: .vertical).lineLimit(1...5)
                        .onSubmit(save)
                    HStack { Button("Save", action: save); Button("Cancel") { editing = false } }.font(.caption)
                } else {
                    Text(line.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Pill(text: LineKind(rawValue: line.kind)?.label ?? line.kind, color: .blue)
                    ForEach(line.tags.prefix(3), id: \.self) { Pill(text: $0, color: .gray) }
                    if !line.context.isEmpty { Text(line.context).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    Text("\(line.text.split(separator: " ").count) words").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
                copied = line.id
            } label: { Image(systemName: copied == line.id ? "checkmark" : "doc.on.doc") }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Edit") { draft = line.text; editing = true }
            Button(line.starred ? "Unstar" : "Star") { toggleStar() }
            Divider()
            Button("Delete", role: .destructive) { store.data.lines?.removeAll { $0.id == line.id } }
        }
    }

    private func toggleStar() {
        if let i = store.data.lines?.firstIndex(where: { $0.id == line.id }) { store.data.lines?[i].starred.toggle() }
    }
    private func save() {
        if let i = store.data.lines?.firstIndex(where: { $0.id == line.id }) { store.data.lines?[i].text = draft }
        editing = false
    }
}
