import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// LinkedIn networking: people found for the jobs you apply to, message drafts by connection type,
/// and your history with each person (from screenshots or pasted text).
struct ConnectionsView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: UUID?
    @State private var search = ""
    @State private var statusFilter = "active"
    @State private var groupByCompany = true
    @State private var dropTargeted = false
    @State private var showPaste = false
    @State private var findJob: UUID?

    private var filtered: [Contact] {
        let q = search.lowercased()
        return store.contacts
            .filter { c in
                switch statusFilter {
                case "active": return c.status != "ignored"
                case "all": return true
                default: return c.status == statusFilter
                }
            }
            .filter { q.isEmpty || ($0.name + " " + $0.headline + " " + $0.company).lowercased().contains(q) }
            .sorted { a, b in
                if a.company != b.company { return (a.lastInteraction ?? a.createdAt) > (b.lastInteraction ?? b.createdAt) }
                return a.relevance > b.relevance
            }
    }

    private var companies: [String] {
        var seen = Set<String>(), out: [String] = []
        for c in filtered where seen.insert(c.company).inserted { out.append(c.company) }
        return out
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                List(selection: $selected) {
                    if groupByCompany {
                        ForEach(companies, id: \.self) { co in
                            Section(co.isEmpty ? "No company" : co) {
                                ForEach(filtered.filter { $0.company == co }) { c in ContactRow(contact: c).tag(c.id) }
                            }
                        }
                    } else {
                        ForEach(filtered) { c in ContactRow(contact: c).tag(c.id) }
                    }
                }
                .onAppear { if let s = store.selectedContactID { selected = s; store.selectedContactID = nil } }
                .onChange(of: store.selectedContactID) { v in if let v { selected = v; store.selectedContactID = nil } }
                .searchable(text: $search, placement: .sidebar, prompt: "Search people")
                .overlay {
                    if store.contacts.isEmpty {
                        EmptyHint(icon: "person.2.wave.2",
                                  title: "No connections yet",
                                  message: "When you press Apply, the app finds the likely hiring manager, recruiters and team leaders at that company on LinkedIn (Google search), and drafts messages for each. You can also drop LinkedIn screenshots here to keep a record of how you networked.")
                    }
                }
                Divider()
                dropZone
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)

            Group {
                if let id = selected, store.contactIndex(id) != nil {
                    ContactDetail(id: id).id(id)
                } else {
                    EmptyHint(icon: "person.crop.circle.badge.plus", title: "Pick a person",
                              message: "Choose a connection type and tone, and the AI drafts connection notes (≤ 200 characters, LinkedIn's limit) plus a longer message for after they accept.")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showPaste) { PasteConversationSheet { id in selected = id } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connections").font(.headline)
                Spacer()
                Picker("", selection: $statusFilter) {
                    Text("Active").tag("active")
                    Text("All").tag("all")
                    Divider()
                    ForEach(ConnectionStatus.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 130)
                Toggle("By company", isOn: $groupByCompany).toggleStyle(.checkbox).font(.caption)
            }
            HStack(spacing: 6) {
                Picker("", selection: $findJob) {
                    Text("Find people for a job…").tag(UUID?.none)
                    ForEach(store.data.jobs.filter { !$0.company.isEmpty }) { j in Text("\(j.company) · \(j.title)").tag(UUID?.some(j.id)) }
                }
                .labelsHidden()
                Button("Find") {
                    guard let jid = findJob else { return }
                    store.run("Finding people…") { try await store.findPeople(jobID: jid) }
                }
                .disabled(findJob == nil || store.peopleSearchStatus != nil)
            }
            if let s = store.peopleSearchStatus {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(s).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Searches today: \(WebSearch.usedToday)/\(WebSearch.dailyCap)\(WebSearch.usable.isEmpty ? " · add a Serper or Tavily key in Settings ▸ Networking" : "")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    private var dropZone: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Drop LinkedIn screenshots here").font(.callout.bold())
                Text("Conversations, invites, profiles — saved to that person's history").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Paste text…") { showPaste = true }
            Button("Choose…") { choose() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35)))
        .padding(8)
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onPasteCommand(of: [.png, .tiff, .image]) { providers in
            for p in providers {
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in importImage(data, name: "pasted image") }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    private func importFiles(_ urls: [URL]) {
        for u in urls {
            guard let d = try? Data(contentsOf: u) else { continue }
            importImage(d, name: u.lastPathComponent)
        }
    }

    private func importImage(_ data: Data, name: String) {
        store.run("Reading \(name)…") {
            if let id = try await store.importConversation(image: data, text: nil) { selected = id }
        }
    }
}

struct ContactRow: View {
    let contact: Contact
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ContactCategory(rawValue: contact.category)?.icon ?? "person")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name).font(.headline).lineLimit(1)
                if !contact.headline.isEmpty {
                    Text(contact.headline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Pill(text: ConnectionStatus(rawValue: contact.status)?.label ?? contact.status, color: color)
                    if contact.relevance > 0 && contact.source == "search" { Text("\(contact.relevance)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    if !contact.interactions.isEmpty {
                        Label("\(contact.interactions.count)", systemImage: "bubble.left").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
    private var color: Color {
        switch contact.status {
        case "requested": return .orange
        case "connected": return .blue
        case "replied", "meeting": return .green
        case "ignored": return .gray
        default: return .purple
        }
    }
}

struct ContactDetail: View {
    @EnvironmentObject var store: AppStore
    let id: UUID
    @AppStorage("connType") private var typeRaw = ConnectionType.hiringManager.rawValue
    @AppStorage("connTone") private var tone = "Warm and professional"
    @State private var goal = ""
    @State private var drafting = false
    @State private var newNote = ""
    @State private var newLogMode = "note"
    @State private var copiedID: String?

    private var c: Contact { store.contactIndex(id).map { store.contacts[$0] } ?? Contact() }
    private var binding: Binding<Contact> {
        Binding(get: { c }, set: { v in if let i = store.contactIndex(id) { store.data.contacts?[i] = v } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                composer
                if let d = c.drafts.first { draftView(d) }
                history
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.headline)
                    TextEditor(text: binding.notes).frame(minHeight: 60).font(.callout)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            }
            .padding(18)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name).font(.title2.bold())
                    if !c.headline.isEmpty { Text(c.headline).foregroundStyle(.secondary) }
                    HStack(spacing: 6) {
                        Label(ContactCategory(rawValue: c.category)?.label ?? "", systemImage: ContactCategory(rawValue: c.category)?.icon ?? "person")
                            .font(.caption)
                        if !c.why.isEmpty { Text("· \(c.why)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                Picker("", selection: Binding(get: { c.status }, set: { store.setContactStatus(id, ConnectionStatus(rawValue: $0) ?? .suggested) })) {
                    ForEach(ConnectionStatus.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 150)
            }
            HStack {
                if let url = URL(string: c.linkedinURL), !c.linkedinURL.isEmpty {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open LinkedIn profile", systemImage: "person.crop.square") }
                } else {
                    TextField("LinkedIn profile URL", text: binding.linkedinURL)
                }
                ForEach(c.jobIDs, id: \.self) { jid in
                    if let j = store.data.jobs.first(where: { $0.id == jid }) {
                        Button { store.section = .jobs; store.selectedJobID = jid } label: { Label(j.title, systemImage: "briefcase") }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Write a message").font(.headline)
            Picker("Connection type", selection: $typeRaw) {
                ForEach(ConnectionType.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Tone", selection: $tone) {
                ForEach(["Warm and professional", "Concise and direct", "Formal", "Friendly and casual", "Confident, senior-to-senior"], id: \.self) { Text($0).tag($0) }
            }
            TextField("Anything specific? (optional) e.g. mention we both worked on biometric devices", text: $goal)
            HStack {
                Button {
                    drafting = true
                    let t = ConnectionType(rawValue: typeRaw) ?? .hiringManager
                    store.run("Writing messages to \(c.name)…") {
                        defer { drafting = false }
                        try await store.draftMessages(contactID: id, type: t, tone: tone, goal: goal)
                    }
                } label: { Label(c.drafts.isEmpty ? "Write messages" : "Write new options", systemImage: "sparkles") }
                .buttonStyle(.borderedProminent)
                .disabled(drafting)
                if drafting { ProgressView().controlSize(.small) }
                Spacer()
                Text("Free LinkedIn: notes ≤ 200 characters, only a few personalised notes a month")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func draftView(_ d: MessageDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(d.type) · \(d.tone)").font(.subheadline.bold())
                Spacer()
                if c.drafts.count > 1 {
                    Menu("Earlier drafts (\(c.drafts.count - 1))") {
                        ForEach(c.drafts.dropFirst()) { old in
                            Button("\(old.type) — \(old.at.formatted(date: .abbreviated, time: .shortened))") {
                                if let i = store.contactIndex(id), let k = store.contacts[i].drafts.firstIndex(where: { $0.id == old.id }) {
                                    let item = store.data.contacts![i].drafts.remove(at: k)
                                    store.data.contacts![i].drafts.insert(item, at: 0)
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            if !d.tip.isEmpty { Label(d.tip, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary) }
            Text("Connection request note").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(d.notes.enumerated()), id: \.offset) { i, n in messageCard(n, key: "\(d.id)-n\(i)", limit: 200, isNote: true) }
            if !d.followUps.isEmpty {
                Text("After they accept").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(Array(d.followUps.enumerated()), id: \.offset) { i, n in messageCard(n, key: "\(d.id)-f\(i)", limit: nil, isNote: false) }
            }
        }
    }

    private func messageCard(_ text: String, key: String, limit: Int?, isNote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let limit {
                    Text("\(text.count)/\(limit)").font(.caption2.monospacedDigit()).foregroundStyle(text.count > limit ? .red : .secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copiedID = key
                } label: { Label(copiedID == key ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                Button {
                    store.useMessage(text, contactID: id, isNote: isNote)
                    copiedID = key
                } label: { Label(isNote ? "Copy & connect" : "Copy & open", systemImage: "arrow.up.forward.app") }
                .help("Copies the message, opens their LinkedIn profile, and records it in your history. Paste it into LinkedIn yourself.")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Text("\(c.interactions.count) message\(c.interactions.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(c.interactions.sorted { $0.date > $1.date }) { it in
                HStack(alignment: .top) {
                    if !it.fromMe { Spacer(minLength: 0) }
                    VStack(alignment: it.fromMe ? .leading : .trailing, spacing: 2) {
                        Text(it.text).font(.callout).textSelection(.enabled)
                            .padding(8)
                            .background(it.fromMe ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 8))
                        Text(caption(it)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if it.fromMe { Spacer(minLength: 0) }
                }
                .contextMenu {
                    if AppStore.isTracked(it) {
                        Menu("Outcome") {
                            Button("Work it out automatically") { store.setOutcome(contactID: id, msgID: it.id, nil) }
                            Divider()
                            ForEach(OutreachOutcome.allCases) { o in Button(o.label) { store.setOutcome(contactID: id, msgID: it.id, o) } }
                        }
                        Menu("Type") {
                            ForEach(OutreachKind.allCases) { k in Button(k.label) { store.setMessageField(contactID: id, msgID: it.id, kind: k.rawValue) } }
                        }
                    }
                    Button("Delete", role: .destructive) {
                        if let i = store.contactIndex(id) { store.data.contacts?[i].interactions.removeAll { $0.id == it.id } }
                    }
                }
            }
            HStack {
                Picker("", selection: $newLogMode) {
                    Text("Note to self").tag("note")
                    Text("Message I sent").tag("sent")
                    Text("Their reply").tag("reply")
                }
                .labelsHidden().frame(width: 140)
                TextField(newLogMode == "note" ? "e.g. 'Spoke on call, will refer next week'" : newLogMode == "sent" ? "Paste the message you sent" : "Paste what they wrote (or leave short, e.g. 'replied')", text: $newNote, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit(addLog)
                Button("Add", action: addLog).disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func caption(_ it: Interaction) -> String {
        let who: String = it.fromMe ? "Me" : (c.name.split(separator: " ").first.map(String.init) ?? "Them")
        let when: String = it.dateText.isEmpty ? it.date.formatted(date: .abbreviated, time: .omitted) : it.dateText
        var bits = ["\(who)", when]
        if AppStore.isTracked(it) {
            if let k = it.kind.flatMap(OutreachKind.init(rawValue:)) { bits.append(k.label) }
            if let r = store.sentRecords.first(where: { $0.id == it.id }) { bits.append(r.outcome.label + (r.automatic ? "" : " ✓")) }
        } else {
            bits.append(it.source)
        }
        return bits.joined(separator: " · ")
    }

    private func addLog() {
        let t = newNote.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = store.contactIndex(id) else { return }
        var it = Interaction()
        it.text = t
        it.source = newLogMode == "sent" ? "manual-sent" : "manual"
        if newLogMode == "sent" { it.kind = c.interactions.contains(where: AppStore.isTracked) ? "message" : "note" }
        if newLogMode == "reply" {
            it.fromMe = false
            if AppStore.statusRank(c.status) < 4 { store.data.contacts?[i].status = "replied" }
        }
        store.data.contacts?[i].interactions.append(it)
        newNote = ""
    }
}
