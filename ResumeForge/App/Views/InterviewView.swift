import SwiftUI

struct InterviewView: View {
    @EnvironmentObject var store: AppStore
    @State private var input = ""
    @State private var focusKey = "general"

    private var focusTitle: String {
        let s = store.data.interview
        if let jid = s.focusJobID, let job = store.data.jobs.first(where: { $0.id == jid }) {
            if let gid = s.focusGapID, let gap = job.gaps.first(where: { $0.id == gid }) {
                return "\(gap.theme) — for \(job.title) at \(job.company)"
            }
            return "\(job.title) at \(job.company)"
        }
        return "General — your strongest untold stories"
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                focusBar
                Divider()
                if store.data.interview.turns.isEmpty {
                    EmptyHint(icon: "bubble.left.and.bubble.right",
                              title: "Let the app interview you",
                              message: "It asks one question at a time and keeps probing — context, what YOU did, scale, numbers — until there's a resume-ready story. Pick a focus above (a missing story from a job, or general) and press Start.")
                } else {
                    transcript
                }
                Divider()
                composer
            }
            .frame(minWidth: 480)

            DraftPanel()
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)
        }
        .onAppear {
            let s = store.data.interview
            if let j = s.focusJobID, let g = s.focusGapID { focusKey = "\(j.uuidString)|\(g.uuidString)" }
        }
    }

    private var focusBar: some View {
        HStack {
            Picker("Focus", selection: $focusKey) {
                Text("General — find my strongest untold stories").tag("general")
                ForEach(store.data.jobs.filter { $0.gaps.contains { $0.status == .open } }) { job in
                    Section(job.title + " · " + job.company) {
                        ForEach(job.gaps.filter { $0.status == .open }) { gap in
                            Text(gap.theme).tag("\(job.id.uuidString)|\(gap.id.uuidString)")
                        }
                    }
                }
            }
            .frame(maxWidth: 520)
            Button(store.data.interview.turns.isEmpty ? "Start" : "Restart") {
                let parts = focusKey.split(separator: "|").map(String.init)
                if parts.count == 2 {
                    store.startInterview(jobID: UUID(uuidString: parts[0]), gapID: UUID(uuidString: parts[1]))
                } else {
                    store.startInterview(jobID: nil, gapID: nil)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.busy != nil)
            Spacer()
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Focus: " + focusTitle).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.data.interview.turns) { ChatBubble(turn: $0).id($0.id) }
                    }
                }
                .padding(14)
            }
            .onChange(of: store.data.interview.turns.count) { _ in
                if let last = store.data.interview.turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Your answer… (⌘↩ to send)", text: $input, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.roundedBorder)
            Button("Send") { send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || store.busy != nil
                          || store.data.interview.turns.isEmpty)
        }
        .padding(10)
    }

    private func send() {
        let text = input
        input = ""
        store.run("Thinking…") { try await store.interviewSend(text) }
    }
}

struct ChatBubble: View {
    let turn: ChatTurn
    var body: some View {
        HStack {
            if turn.role == "user" { Spacer(minLength: 60) }
            Text(turn.text)
                .textSelection(.enabled)
                .padding(10)
                .background(turn.role == "user" ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12))
            if turn.role != "user" { Spacer(minLength: 60) }
        }
    }
}

/// The story being built from the conversation — editable, then saved into the story bank.
struct DraftPanel: View {
    @EnvironmentObject var store: AppStore

    private var draft: Binding<Story> {
        Binding(get: { store.data.interview.draft ?? Story() },
                set: { store.data.interview.draft = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Story draft").font(.headline)
                Spacer()
                if store.data.interview.readyToSave { Pill(text: "ready", color: .green) }
            }
            .padding(12)
            Divider()
            if store.data.interview.draft == nil {
                EmptyHint(icon: "text.badge.plus", title: "Nothing yet",
                          message: "As you answer, the draft builds here using only what you've said.")
            } else {
                Form {
                    TextField("Title", text: draft.title)
                    TextField("Company", text: draft.company)
                    HStack {
                        TextField("Role", text: draft.role)
                        TextField("Period", text: draft.period)
                    }
                    TextEditor(text: draft.text).frame(minHeight: 180)
                    // Re-seed these fields only when the interviewer replies (not while you type).
                    CommaField(title: "Metrics", values: draft.metrics)
                        .id("m\(store.data.interview.turns.count)")
                    CommaField(title: "Skills", values: draft.skills)
                        .id("s\(store.data.interview.turns.count)")
                }
                .formStyle(.grouped)
                HStack {
                    Button("Discard", role: .destructive) { store.data.interview.draft = nil }
                    Spacer()
                    Button {
                        store.saveInterviewDraft()
                        store.section = .stories
                    } label: { Label("Save to my stories", systemImage: "tray.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                    .disabled((store.data.interview.draft?.text ?? "").isEmpty)
                }
                .padding(12)
            }
        }
    }
}
