import AppKit
import SwiftUI

/// Every action across all jobs in one place, with an AI commentary on the whole workload beside it.
struct ActionsView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: UUID?
    @State private var showDone = false
    @State private var jobFilter: UUID?
    @State private var quickText = ""
    @State private var quickKind = ActionKind.custom.rawValue
    @State private var quickJob: UUID?

    private var open: [ActionItem] {
        store.actions.filter { $0.isOpen && (jobFilter == nil || $0.jobID == jobFilter) }
    }

    private func group(_ name: String) -> [ActionItem] {
        let cal = Calendar.current
        let now = Date()
        let items: [ActionItem]
        switch name {
        case "Overdue": items = open.filter { ($0.due ?? .distantFuture) < now && !cal.isDateInToday($0.due!) }
        case "Today": items = open.filter { $0.due.map { cal.isDateInToday($0) } ?? false }
        case "Upcoming": items = open.filter { ($0.due ?? .distantPast) > now && !cal.isDateInToday($0.due!) }
        case "No date": items = open.filter { $0.due == nil }
        default: items = store.actions.filter { !$0.isOpen && (jobFilter == nil || $0.jobID == jobFilter) }
        }
        return items.sorted { ($0.due ?? $0.createdAt) < ($1.due ?? $1.createdAt) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                List(selection: $selected) {
                    ForEach(["Overdue", "Today", "Upcoming", "No date"], id: \.self) { g in
                        let items = group(g)
                        if !items.isEmpty {
                            Section {
                                ForEach(items) { a in ActionRow(item: a, overdue: g == "Overdue").tag(a.id) }
                            } header: {
                                Text("\(g) · \(items.count)").foregroundStyle(g == "Overdue" ? .red : .secondary)
                            }
                        }
                    }
                    if showDone {
                        let done = group("Done")
                        if !done.isEmpty {
                            Section("Done / dropped · \(done.count)") {
                                ForEach(done) { a in ActionRow(item: a, overdue: false).tag(a.id) }
                            }
                        }
                    }
                }
                .overlay {
                    if store.actions.isEmpty {
                        EmptyHint(icon: "checklist",
                                  title: "No actions yet",
                                  message: "In Safari, right-click a job page → ResumeForge → Add action (Meet on LinkedIn, Message on WhatsApp, Call, Email, Apply or your own). The AI fills in the company, consultant and date. Or add one below.")
                    }
                }
                Divider()
                quickAdd
            }
            .frame(minWidth: 420, idealWidth: 520)

            VStack(spacing: 0) {
                if let id = selected, store.actionIndex(id) != nil {
                    ActionDetail(id: id).id(id)
                    Divider()
                }
                CommentaryPanel()
            }
            .frame(minWidth: 340, idealWidth: 420)
        }
    }

    private var toolbar: some View {
        HStack {
            Text("Actions").font(.title3.bold())
            Text("\(open.count) open").foregroundStyle(.secondary)
            Spacer()
            Picker("Job", selection: $jobFilter) {
                Text("All jobs").tag(UUID?.none)
                ForEach(store.data.jobs) { j in Text("\(j.title) · \(j.company)").tag(UUID?.some(j.id)) }
            }
            .frame(maxWidth: 260)
            Toggle("Show done", isOn: $showDone).toggleStyle(.checkbox)
        }
        .padding(10)
    }

    private var quickAdd: some View {
        HStack(spacing: 6) {
            Picker("", selection: $quickKind) {
                ForEach(ActionKind.allCases) { k in Label(k.label, systemImage: k.icon).tag(k.rawValue) }
            }
            .labelsHidden()
            .frame(width: 170)
            TextField("Add an action… e.g. \"Call Rahul from ABC Search tomorrow 11am\"", text: $quickText)
                .onSubmit(add)
            Picker("", selection: $quickJob) {
                Text("No job").tag(UUID?.none)
                ForEach(store.data.jobs) { j in Text(j.company.isEmpty ? j.title : "\(j.company) · \(j.title)").tag(UUID?.some(j.id)) }
            }
            .labelsHidden()
            .frame(width: 180)
            Button("Add", action: add).disabled(quickText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(8)
    }

    private func add() {
        let t = quickText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var a = ActionItem()
        a.kind = quickKind
        a.text = t
        a.jobID = quickJob
        if let j = quickJob.flatMap({ id in store.data.jobs.first { $0.id == id } }) { a.company = j.company; a.pageURL = j.url }
        store.addAction(a)
        quickText = ""
    }
}

struct ActionRow: View {
    @EnvironmentObject var store: AppStore
    let item: ActionItem
    let overdue: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { store.setActionStatus(item.id, item.isOpen ? "done" : "open") } label: {
                Image(systemName: item.isOpen ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(item.isOpen ? Color.secondary : Color.green)
            }
            .buttonStyle(.borderless)
            Image(systemName: ActionKind(rawValue: item.kind)?.icon ?? "checklist").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).strikethrough(!item.isOpen).lineLimit(2)
                let who = [item.person, item.company].filter { !$0.isEmpty }.joined(separator: " · ")
                if !who.isEmpty { Text(who).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 6) {
                    if let d = item.due {
                        Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(overdue ? .red : .secondary)
                    }
                    if !item.enriched && item.enrichError == nil && ProviderSettings.anyKeyConfigured {
                        ProgressView().controlSize(.mini)
                        Text("reading the job…").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Button { store.open(item) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .help("Open LinkedIn / WhatsApp / email / the job")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(item.isOpen ? "Mark done" : "Reopen") { store.setActionStatus(item.id, item.isOpen ? "done" : "open") }
            Button("Drop") { store.setActionStatus(item.id, "dropped") }
            Divider()
            Button("Delete", role: .destructive) { store.deleteAction(item.id) }
        }
    }
}

struct ActionDetail: View {
    @EnvironmentObject var store: AppStore
    let id: UUID

    private var binding: Binding<ActionItem> {
        Binding(get: { store.actionIndex(id).map { store.actions[$0] } ?? ActionItem() },
                set: { v in if let i = store.actionIndex(id) { store.data.actions?[i] = v } })
    }

    var body: some View {
        let a = binding.wrappedValue
        Form {
            Section {
                TextField("Action", text: binding.title, prompt: Text(a.text))
                Picker("Type", selection: binding.kind) {
                    ForEach(ActionKind.allCases) { k in Label(k.label, systemImage: k.icon).tag(k.rawValue) }
                }
                Picker("Job", selection: binding.jobID) {
                    Text("No job").tag(UUID?.none)
                    ForEach(store.data.jobs) { j in Text("\(j.title) · \(j.company)").tag(UUID?.some(j.id)) }
                }
                TextField("Company", text: binding.company)
                HStack {
                    TextField("Person", text: binding.person)
                    TextField("Role", text: binding.personRole)
                }
                TextField("Contact (phone, email or LinkedIn URL)", text: binding.contact)
                Toggle("Has a date", isOn: Binding(get: { a.due != nil },
                                                    set: { on in binding.wrappedValue.due = on ? (a.due ?? Date().addingTimeInterval(86400)) : nil }))
                if a.due != nil {
                    DatePicker("Due", selection: Binding(get: { a.due ?? Date() }, set: { binding.wrappedValue.due = $0 }))
                }
                TextField("Notes", text: binding.notes, axis: .vertical).lineLimit(1...4)
                if !a.text.isEmpty && a.text != a.title { Text("You wrote: \(a.text)").font(.caption).foregroundStyle(.secondary) }
                if let e = a.enrichError { Text(e).font(.caption).foregroundStyle(.orange).lineLimit(3) }
                HStack {
                    Button { store.open(a) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                    Button { Task { await store.enrichAction(id) } } label: { Label("Re-read with AI", systemImage: "sparkles") }
                    Spacer()
                    Button(a.isOpen ? "Mark done" : "Reopen") { store.setActionStatus(id, a.isOpen ? "done" : "open") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 430)
    }
}

struct CommentaryPanel: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Workload commentary", systemImage: "text.bubble").font(.headline)
                Spacer()
                if store.commentaryBusy { ProgressView().controlSize(.small) }
                Button { store.scheduleCommentary(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.commentaryBusy)
                    .help("Refresh commentary")
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let c = store.data.commentary {
                        Text(c.headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        block("Do now", c.doNow, "bolt.fill", .accentColor, numbered: true)
                        block("Overdue / at risk", c.overdue, "exclamationmark.triangle.fill", .red)
                        block("Stalled", c.stalled, "pause.circle.fill", .orange)
                        block("Suggestions", c.suggestions, "lightbulb.fill", .yellow)
                        HStack {
                            Text("Updated \(c.generatedAt.formatted(date: .omitted, time: .shortened))")
                            if store.commentaryStale { Text("· things changed since — refresh") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(ProviderSettings.anyKeyConfigured
                             ? "Add a few actions, then press refresh. The AI looks across all your jobs and actions: what to do first, what's overdue, and which jobs have stalled."
                             : "Add an AI provider key in Settings to get workload commentary.")
                            .foregroundStyle(.secondary)
                    }
                    if let e = store.commentaryError { Text(e).font(.caption).foregroundStyle(.orange) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func block(_ title: String, _ items: [String], _ icon: String, _ color: Color, numbered: Bool = false) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon).font(.callout.bold()).foregroundStyle(color)
                ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                    Text((numbered ? "\(i + 1). " : "• ") + t).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Actions for one job, shown inside the job's page.
struct JobActionsBox: View {
    @EnvironmentObject var store: AppStore
    let jobID: UUID
    @State private var text = ""
    @State private var kind = ActionKind.custom.rawValue

    var body: some View {
        let items = store.actions.filter { $0.jobID == jobID }.sorted { $0.isOpen && !$1.isOpen }
        VStack(alignment: .leading, spacing: 6) {
            Text("Actions").font(.headline)
            ForEach(items) { a in ActionRow(item: a, overdue: (a.due ?? .distantFuture) < Date() && a.isOpen) }
            HStack {
                Picker("", selection: $kind) {
                    ForEach(ActionKind.allCases) { k in Text(k.label).tag(k.rawValue) }
                }
                .labelsHidden().frame(width: 160)
                TextField("Add an action for this job…", text: $text).onSubmit(add)
                Button("Add", action: add).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var a = ActionItem()
        a.kind = kind
        a.text = t
        a.jobID = jobID
        if let j = store.data.jobs.first(where: { $0.id == jobID }) { a.company = j.company; a.pageURL = j.url }
        store.addAction(a)
        text = ""
    }
}
