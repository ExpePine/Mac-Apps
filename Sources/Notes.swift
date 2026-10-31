import AppKit
import SwiftUI

// MARK: - Model & storage

struct NoteItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var created = Date()
    var updated = Date()
    var text = ""
    var goal: String? = nil
    var pinned = false

    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.isEmpty ? "New note" : String(first.prefix(80))
    }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [NoteItem] = []
    private let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("notes.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let list = try? decoder.decode([NoteItem].self, from: data) {
            notes = list
        }
    }

    var sorted: [NoteItem] {
        notes.sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) }
    }

    func notes(on day: Date) -> [NoteItem] {
        notes.filter { !$0.text.isEmpty && Calendar.current.isDate($0.created, inSameDayAs: day) }.sorted { $0.created > $1.created }
    }

    @discardableResult
    func add(_ text: String, goal: String? = nil) -> NoteItem {
        let n = NoteItem(text: text, goal: goal)
        notes.append(n)
        save()
        return n
    }

    func update(_ id: UUID, _ change: (inout NoteItem) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        notes[i].updated = Date()
        save()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(notes) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - Notes screen (list + editor, like Apple Notes)

struct NotesView: View {
    @ObservedObject var notes: NotesStore
    let goalOptions: [String]

    @State private var selection: UUID?
    @State private var search = ""
    @State private var draft = ""

    private var visible: [NoteItem] {
        let all = notes.sorted
        guard !search.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(search) || ($0.goal ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Notes").font(.title2.weight(.bold))
                    Spacer()
                    Button { newNote() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("n", modifiers: .command)
                        .help("New note (⌘N)")
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
                TextField("Search", text: $search, prompt: Text("Search notes"))
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                List(selection: $selection) {
                    ForEach(visible) { n in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if n.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                                Text(n.title).font(.body.weight(.semibold)).lineLimit(1)
                            }
                            HStack(spacing: 6) {
                                Text(n.updated.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                if let g = n.goal { Text(g).foregroundStyle(areaColor(g)).lineLimit(1) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(n.id)
                        .contextMenu {
                            Button(n.pinned ? "Unpin" : "Pin") { notes.update(n.id) { $0.pinned.toggle() } }
                            Button("Delete", role: .destructive) { delete(n.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand { if let id = selection { delete(id) } }
            }
            .frame(width: 260)

            Divider()

            if let id = selection, let note = notes.notes.first(where: { $0.id == id }) {
                editor(note)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "note.text").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("Ideas, findings, things to remember").foregroundStyle(.secondary)
                    Button("New note") { newNote() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selection) { _ in loadDraft() }
        .onAppear { if selection == nil { selection = notes.sorted.first?.id }; loadDraft() }
    }

    private func editor(_ note: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(note.created.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("No goal") { notes.update(note.id) { $0.goal = nil } }
                    ForEach(goalOptions, id: \.self) { g in Button(g) { notes.update(note.id) { $0.goal = g } } }
                } label: {
                    Label(note.goal ?? "Link to goal", systemImage: "target")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button { notes.update(note.id) { $0.pinned.toggle() } } label: {
                    Image(systemName: note.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless).help(note.pinned ? "Unpin" : "Pin")
                Button { delete(note.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete")
            }
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .onChange(of: draft) { text in
                    if text != note.text { notes.update(note.id) { $0.text = text } }
                }
        }
        .padding(20)
    }

    private func loadDraft() {
        draft = selection.flatMap { id in notes.notes.first { $0.id == id }?.text } ?? ""
    }

    private func newNote() {
        search = ""
        selection = notes.add("").id
        loadDraft()
    }

    private func delete(_ id: UUID) {
        if selection == id { selection = nil }
        notes.delete(id)
    }
}
