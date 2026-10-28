import AppKit
import Charts
import SwiftUI

/// Every LinkedIn note and message you send, who answered, and what works best for you.
struct OutreachView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("outreachTab") private var tab = "log"
    @State private var showLog = false
    @State private var prefill = ""

    var body: some View {
        let recs = store.sentRecords
        VStack(spacing: 0) {
            header(recs)
            Divider()
            switch tab {
            case "insights": OutreachInsights(recs: recs)
            case "coach": OutreachCoach(recs: recs)
            default: OutreachLog(recs: recs)
            }
        }
        .sheet(isPresented: $showLog) { LogMessageSheet(prefill: prefill) }
    }

    private func header(_ recs: [SentRecord]) -> some View {
        let notes = recs.filter { $0.kind == "note" && $0.outcome.resolved }
        let msgs = recs.filter { $0.outcome.resolved }
        let answered = msgs.filter { $0.outcome == .replied || $0.outcome == .meeting }
        let gaps = recs.compactMap { r in r.replyAt.map { $0.timeIntervalSince(r.msg.date) / 86400 } }
        let avgDays = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Outreach").font(.title3.bold())
                if let s = store.outreachStatus { ProgressView().controlSize(.small); Text(s).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Picker("", selection: $tab) {
                    Text("Messages").tag("log")
                    Text("What works").tag("insights")
                    Text("Coach").tag("coach")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Spacer()
                Button {
                    prefill = NSPasteboard.general.string(forType: .string) ?? ""
                    showLog = true
                } label: { Label("Log copied message", systemImage: "doc.on.clipboard") }
                .help("Opens the log form with the text you just copied from LinkedIn")
                Button { prefill = ""; showLog = true } label: { Label("Log a message", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 10) {
                Stat(title: "Sent", value: "\(recs.count)", sub: "\(recs.filter { $0.outcome == .waiting }.count) waiting")
                Stat(title: "Notes accepted", value: pct(notes.filter(\.worked).count, notes.count), sub: "of \(notes.count) with an outcome")
                Stat(title: "Answered", value: pct(answered.count, msgs.count), sub: "of \(msgs.count) with an outcome")
                Stat(title: "Calls / meetings", value: "\(recs.filter { $0.outcome == .meeting }.count)", sub: "")
                Stat(title: "Avg. time to reply", value: avgDays.map { $0 < 1 ? "< 1 day" : String(format: "%.1f days", $0) } ?? "—", sub: "")
            }
        }
        .padding(12)
    }

    private func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "—" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }
}

private struct Stat: View {
    let title: String, value: String, sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Messages

struct OutreachLog: View {
    @EnvironmentObject var store: AppStore
    let recs: [SentRecord]
    @State private var outcomeFilter = "all"
    @State private var kindFilter = "all"
    @State private var search = ""
    @State private var replyTo: SentRecord?

    private var followUps: [SentRecord] {
        // Waiting past the follow-up point, or a note accepted with nothing sent since.
        let lastPer = Dictionary(grouping: recs, by: \.contactID).compactMapValues { list in list.max { a, b in a.msg.date < b.msg.date } }
        return lastPer.values.filter { r in
            (r.outcome == .waiting && r.kind != "note" && r.days >= AppStore.followUpDays)
                || (r.outcome == .accepted && r.kind == "note")
        }
        .sorted { $0.msg.date < $1.msg.date }
    }

    private var filtered: [SentRecord] {
        let q = search.lowercased()
        return recs
            .filter { outcomeFilter == "all" || (outcomeFilter == "worked" ? $0.worked : $0.outcome.rawValue == outcomeFilter) }
            .filter { kindFilter == "all" || $0.kind == kindFilter }
            .filter { q.isEmpty || ($0.name + " " + $0.company + " " + $0.msg.text).lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search people, companies, text", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("", selection: $kindFilter) {
                    Text("All types").tag("all")
                    ForEach(OutreachKind.allCases) { Text($0.label).tag($0.rawValue) }
                }.labelsHidden().frame(width: 150)
                Picker("", selection: $outcomeFilter) {
                    Text("All outcomes").tag("all")
                    Text("Worked").tag("worked")
                    ForEach(OutreachOutcome.allCases) { Text($0.label).tag($0.rawValue) }
                }.labelsHidden().frame(width: 150)
                Spacer()
                Text("No answer after \(AppStore.noReplyDays) days counts as no response").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            List {
                if !followUps.isEmpty && outcomeFilter == "all" && search.isEmpty {
                    Section("Follow up (\(followUps.count))") {
                        ForEach(followUps) { r in FollowUpRow(r: r) }
                    }
                }
                Section("Sent (\(filtered.count))") {
                    ForEach(filtered) { r in SentRow(r: r, replyTo: $replyTo) }
                }
            }
            .overlay {
                if recs.isEmpty {
                    EmptyHint(icon: "paperplane",
                              title: "Log the LinkedIn messages you send",
                              message: "Four ways in: press Copy & connect on a draft in Connections; right-click on LinkedIn in Safari → ResumeForge: LinkedIn → Log the message I'm sending; copy a message and press Log copied message; or drop a screenshot of a conversation into Connections. Replies are picked up when you log the conversation again (Safari → Log this conversation), or mark them here.")
                }
            }
        }
        .sheet(item: $replyTo) { r in ReplySheet(r: r) }
    }
}

private struct FollowUpRow: View {
    @EnvironmentObject var store: AppStore
    let r: SentRecord
    var body: some View {
        HStack {
            Image(systemName: r.outcome == .accepted ? "person.crop.circle.badge.checkmark" : "clock.arrow.circlepath")
                .foregroundStyle(r.outcome == .accepted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.headline)
                Text(r.outcome == .accepted ? "Accepted your request — send a first message" : "No answer for \(r.days) days — a short, useful follow-up")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Draft message") { store.selectedContactID = r.contactID; store.section = .connections }
            Button("Add to Actions") {
                var a = ActionItem()
                a.kind = "linkedin"
                a.text = r.outcome == .accepted ? "Send a first message to \(r.name)" : "Follow up with \(r.name)"
                a.title = a.text
                a.person = r.name
                a.personRole = r.headline
                a.company = r.company
                a.jobID = r.msg.jobID
                a.due = Date()
                store.addAction(a)
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct SentRow: View {
    @EnvironmentObject var store: AppStore
    let r: SentRecord
    @Binding var replyTo: SentRecord?

    var color: Color {
        switch r.outcome {
        case .replied, .meeting: return .green
        case .accepted: return .teal
        case .waiting: return .orange
        case .noReply: return .gray
        case .declined: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(r.name).font(.headline)
                    if !r.company.isEmpty { Text("· \(r.company)").foregroundStyle(.secondary) }
                    Pill(text: OutreachKind(rawValue: r.kind)?.label ?? r.kind, color: .blue)
                    if let i = r.msg.intent.flatMap(ConnectionType.init(rawValue:)) { Pill(text: i.label, color: .purple) }
                    if let a = r.msg.angle { Pill(text: a, color: .gray) }
                }
                Text(r.msg.text).font(.callout).lineLimit(3).textSelection(.enabled)
                if !r.replyText.isEmpty && r.replyText != "(replied)" {
                    Label(r.replyText, systemImage: "arrowshape.turn.up.left").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Menu {
                    Button("Work it out automatically") { store.setOutcome(contactID: r.contactID, msgID: r.id, nil) }
                    Divider()
                    ForEach(OutreachOutcome.allCases) { o in Button(o.label) { store.setOutcome(contactID: r.contactID, msgID: r.id, o) } }
                } label: {
                    Text(r.outcome.label + (r.automatic ? "" : " ✓")).font(.caption.bold()).foregroundStyle(color)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(r.automatic ? "Worked out automatically — click to set it yourself" : "Set by you")
                Text(r.msg.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
                if r.outcome == .waiting || r.outcome == .accepted || r.outcome == .noReply {
                    Button("They replied…") { replyTo = r }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Open in Connections") { store.selectedContactID = r.contactID; store.section = .connections }
            Menu("Type") {
                ForEach(OutreachKind.allCases) { k in Button(k.label) { store.setMessageField(contactID: r.contactID, msgID: r.id, kind: k.rawValue) } }
            }
            Menu("Purpose") {
                Button("Not set") { store.setMessageField(contactID: r.contactID, msgID: r.id, intent: .some(nil)) }
                ForEach(ConnectionType.allCases) { t in Button(t.label) { store.setMessageField(contactID: r.contactID, msgID: r.id, intent: .some(t.rawValue)) } }
            }
            Divider()
            Button("Delete from history", role: .destructive) {
                if let i = store.contactIndex(r.contactID) { store.data.contacts?[i].interactions.removeAll { $0.id == r.id } }
            }
        }
    }
}

private struct ReplySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let r: SentRecord
    @State private var text = ""
    @State private var date = Date()
    @State private var meeting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(r.firstName) replied").font(.title3.bold())
            Text("Paste what they wrote (optional — it helps the coach), or leave it empty.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).frame(minHeight: 110).border(.quaternary)
            DatePicker("When", selection: $date, in: r.msg.date..., displayedComponents: .date)
            Toggle("We agreed a call / meeting", isOn: $meeting)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    store.addReply(contactID: r.contactID, to: r.id, text: text, date: date)
                    if meeting { store.setContactStatus(r.contactID, .meeting) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

/// Log a message you sent outside the app's drafts.
struct LogMessageSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var prefill = ""
    @State private var contactID: UUID?
    @State private var who = ""
    @State private var name = ""
    @State private var company = ""
    @State private var headline = ""
    @State private var url = ""
    @State private var kind = "note"
    @State private var intent = ""
    @State private var date = Date()
    @State private var text = ""
    @State private var replied = false
    @State private var reply = ""

    private var matches: [Contact] {
        let q = who.lowercased()
        guard !q.isEmpty else { return [] }
        return Array(store.contacts.filter { ($0.name + " " + $0.company).lowercased().contains(q) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log a message I sent").font(.title3.bold())
            if let id = contactID, let c = store.contacts.first(where: { $0.id == id }) {
                HStack {
                    Label("\(c.name) · \(c.company)", systemImage: "person.crop.circle.fill")
                    Button("Change") { contactID = nil }.buttonStyle(.borderless)
                }
            } else {
                TextField("Who to — search your Connections, or type a new name", text: $who)
                ForEach(matches) { c in
                    Button("\(c.name) · \(c.company)") { contactID = c.id }.buttonStyle(.borderless)
                }
                if matches.isEmpty && !who.isEmpty {
                    Grid(alignment: .leading) {
                        GridRow { Text("New person").foregroundStyle(.secondary); Text(who) }
                        GridRow { Text("Company"); TextField("", text: $company) }
                        GridRow { Text("Title"); TextField("e.g. Head of Product", text: $headline) }
                        GridRow { Text("Profile link"); TextField("https://www.linkedin.com/in/…", text: $url) }
                    }
                }
            }
            HStack {
                Picker("Type", selection: $kind) { ForEach(OutreachKind.allCases) { Text($0.label).tag($0.rawValue) } }
                Picker("Purpose", selection: $intent) {
                    Text("Not set").tag("")
                    ForEach(ConnectionType.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            DatePicker("Sent on", selection: $date, in: ...Date(), displayedComponents: .date)
            Text("Message").font(.caption.bold())
            TextEditor(text: $text).frame(minHeight: 110).border(.quaternary)
            HStack {
                Text("\(text.count) characters").font(.caption2).foregroundStyle(kind == "note" && text.count > 300 ? .red : .secondary)
                Spacer()
            }
            Toggle("They've already replied", isOn: $replied)
            if replied { TextEditor(text: $reply).frame(minHeight: 60).border(.quaternary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let id = store.logSent(contactID: contactID, name: contactID == nil ? who : "", company: company, headline: headline,
                                           url: url, kind: kind, intent: intent.isEmpty ? nil : intent, date: date, text: text,
                                           replyText: replied ? reply : nil, replyDate: replied ? Date() : nil)
                    if id != nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (contactID == nil && who.isEmpty))
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear {
            text = prefill
            if !prefill.isEmpty && prefill.count > 300 { kind = "message" }
        }
    }
}

// MARK: - What works

struct OutreachInsights: View {
    @EnvironmentObject var store: AppStore
    let recs: [SentRecord]

    private struct Week: Identifiable { let id: Date; let sent: Int; let worked: Int }

    private var weeks: [Week] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .weekOfYear, value: -11, to: cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()) ?? Date()
        let byWeek = Dictionary(grouping: recs.filter { $0.msg.date >= start }) { cal.dateInterval(of: .weekOfYear, for: $0.msg.date)?.start ?? $0.msg.date }
        return (0..<12).compactMap { i in
            guard let w = cal.date(byAdding: .weekOfYear, value: i, to: start) else { return nil }
            let r = byWeek[w] ?? []
            return Week(id: w, sent: r.count, worked: r.filter(\.worked).count)
        }
    }

    var body: some View {
        let groups = store.insightGroups(recs)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("A note counts as working if it's accepted; any other message if they answer. Messages still waiting are left out until they have an outcome. Small groups (fewer than 5) are greyed out — treat them as hints, not proof.")
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox("Last 12 weeks") {
                    Chart(weeks) { w in
                        BarMark(x: .value("Week", w.id, unit: .weekOfYear), y: .value("Messages", w.sent))
                            .foregroundStyle(by: .value("Series", "Sent"))
                            .position(by: .value("Series", "Sent"))
                        BarMark(x: .value("Week", w.id, unit: .weekOfYear), y: .value("Messages", w.worked))
                            .foregroundStyle(by: .value("Series", "Worked"))
                            .position(by: .value("Series", "Worked"))
                    }
                    .chartForegroundStyleScale(["Sent": Color.secondary.opacity(0.35), "Worked": Color.green])
                    .frame(height: 160)
                }
                if groups.isEmpty {
                    EmptyHint(icon: "chart.bar", title: "Not enough results yet",
                              message: "Once a few messages have an outcome (answered, accepted or no response), this shows which types, purposes, lengths and angles work best for you.")
                        .frame(height: 220)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.0) { title, rows in
                        GroupBox(title) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(rows) { row in
                                    HStack {
                                        Text(row.label).lineLimit(1)
                                        Spacer()
                                        Text("\(row.worked)/\(row.sent)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        ProgressView(value: row.rate).frame(width: 70)
                                        Text("\(Int((row.rate * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                                    }
                                    .opacity(row.sent < 5 ? 0.45 : 1)
                                }
                            }
                            .padding(4)
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Coach

struct OutreachCoach: View {
    @EnvironmentObject var store: AppStore
    let recs: [SentRecord]
    @State private var draft = ""
    @State private var kind = "note"
    @State private var intent = ""
    @State private var who = "hiringManager"
    @State private var review: DraftReview?
    @State private var reviewing = false
    @State private var copied = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                playbook
                Divider()
                checker
            }
            .padding(14)
        }
    }

    private var playbook: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your playbook").font(.headline)
                if let p = store.data.outreachPlaybook {
                    Text("from \(p.basedOn) messages · \(p.at.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                let ready = recs.filter { $0.outcome.resolved }.count
                Button {
                    store.run("Studying your messages…") { try await store.coachOutreach() }
                } label: { Label(store.data.outreachPlaybook == nil ? "Build my playbook" : "Update playbook", systemImage: "sparkles") }
                .disabled(ready < 5)
                .help(ready < 5 ? "Needs at least 5 messages with an outcome (\(ready) so far)" : "Compares the messages that worked with the ones that didn't")
            }
            if let p = store.data.outreachPlaybook {
                if !p.caution.isEmpty { Label(p.caution, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                HStack(alignment: .top, spacing: 14) {
                    bullets("What's working", p.working, "checkmark.circle", .green)
                    bullets("What isn't", p.notWorking, "xmark.circle", .red)
                }
                bullets("Rules for your next messages (used by the draft writer)", p.rules, "list.number", .accentColor)
                bullets("Try next (A/B tests)", p.experiments, "flask", .purple)
                if !p.templates.isEmpty {
                    Text("Templates").font(.subheadline.bold())
                    ForEach(p.templates, id: \.self) { t in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(t.kind) · \(t.purpose)").font(.caption).foregroundStyle(.secondary)
                                Text(t.text).textSelection(.enabled)
                            }
                            Spacer()
                            copyButton(t.text)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                Text("After at least 5 messages have an outcome, the coach compares the ones that worked with the ones that didn't and writes rules, templates and experiments from your own results. Your rules and best notes are then given to the draft writer in Connections, so drafts improve as your results grow. Names and companies are replaced with {name} and {company} before anything is sent to the AI.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var checker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check a message before you send it").font(.headline)
            HStack {
                Picker("Type", selection: $kind) { ForEach(OutreachKind.allCases) { Text($0.label).tag($0.rawValue) } }
                Picker("To", selection: $who) { ForEach(ContactCategory.allCases) { Text($0.label).tag($0.rawValue) } }
                Picker("Purpose", selection: $intent) {
                    Text("Not set").tag("")
                    ForEach(ConnectionType.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            TextEditor(text: $draft).frame(minHeight: 100).border(.quaternary)
            HStack {
                Text("\(draft.count) characters").font(.caption2).foregroundStyle(kind == "note" && draft.count > 200 ? .red : .secondary)
                Spacer()
                if reviewing { ProgressView().controlSize(.small) }
                Button("Check it") {
                    reviewing = true
                    Task {
                        defer { reviewing = false }
                        do { review = try await store.reviewDraft(draft, kind: kind, intent: intent.isEmpty ? nil : intent, category: who) }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || reviewing)
            }
            if let r = review {
                HStack {
                    Text("\(r.score)/10").font(.title2.bold()).foregroundStyle(r.score >= 8 ? .green : r.score >= 6 ? .orange : .red)
                    Text(r.verdict)
                }
                HStack(alignment: .top, spacing: 14) {
                    bullets("Good", r.good, "checkmark.circle", .green)
                    bullets("Change", r.fix, "pencil.circle", .orange)
                }
                if !r.improved.isEmpty {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Improved (\(r.improved.count) characters)").font(.caption).foregroundStyle(.secondary)
                            Text(r.improved).textSelection(.enabled)
                        }
                        Spacer()
                        VStack {
                            copyButton(r.improved)
                            Button("Use") { draft = r.improved; review = nil }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func bullets(_ title: String, _ items: [String], _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            ForEach(items, id: \.self) { s in
                Label { Text(s).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(color) }
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = text
        } label: { Image(systemName: copied == text ? "checkmark" : "doc.on.doc") }
        .buttonStyle(.borderless)
    }
}
