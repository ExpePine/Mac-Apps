import AppKit
import SwiftUI

// MARK: - Stuck

struct StuckView: View {
    let coach: CoachService
    @ObservedObject var stuckStore: StuckStore

    @State private var session: StuckSession?
    @State private var problemDraft = ""
    @State private var replyDraft = ""
    @State private var thinking = false
    @State private var error: String?
    @State private var askingResolution = false
    @State private var resolutionDraft = ""

    var body: some View {
        Group {
            if let session {
                conversation(session)
            } else {
                intro
            }
        }
        .sheet(isPresented: $askingResolution) { resolutionSheet }
    }

    // MARK: Intro

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "lifepreserver.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.orange)
                    PageHeader(title: "Stuck?", subtitle: "Describe what's blocking you. You'll get a first step, a breakdown, and anything similar from your own history.")
                }

                Card(title: "What are you stuck on?", symbol: "text.bubble") {
                    TextEditor(text: $problemDraft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                    Text("Include what you tried and what happened. More detail = better help.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    HStack {
                        Spacer()
                        Button {
                            Task { await start() }
                        } label: {
                            if thinking { ProgressView().controlSize(.small) } else { Label("Get unstuck", systemImage: "arrow.right.circle.fill") }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(thinking || problemDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if !stuckStore.sessions.isEmpty {
                    Card(title: "Recent", symbol: "clock") {
                        ForEach(stuckStore.sessions.prefix(8)) { s in
                            Button { session = s } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: s.resolved ? "checkmark.circle.fill" : "circle.dotted")
                                        .foregroundStyle(s.resolved ? Color.green : Color.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.problem).lineLimit(1)
                                        if let r = s.resolution {
                                            Text("Worked: \(r)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Text(s.date.formatted(.dateTime.day().month(.abbreviated)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    // MARK: Conversation

    private func conversation(_ s: StuckSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { session = nil; error = nil } label: { Label("All problems", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                if s.resolved {
                    Label("Solved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Button { resolutionDraft = ""; askingResolution = true } label: {
                        Label("Solved it", systemImage: "checkmark.circle")
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(s.problem).font(.title3.weight(.semibold)).padding(.bottom, 4)
                        ForEach(s.messages.dropFirst()) { m in Bubble(message: m) }
                        if thinking {
                            HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                                .id("thinking")
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.callout) }
                        if let r = s.resolution {
                            Label("What worked: \(r)", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(24)
                }
                .onChange(of: s.messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            Divider()
            HStack(spacing: 10) {
                TextField("Reply, add detail, or answer the question…", text: $replyDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit { Task { await reply() } }
                Button { Task { await reply() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(thinking || replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
    }

    private var resolutionSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Nice — what worked?", systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(.green)
            Text("A short note helps next time you're stuck on something similar.")
                .foregroundStyle(.secondary)
            TextField("e.g. Re-flashed bootloader with slower SWD clock", text: $resolutionDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack {
                Button("Cancel") { askingResolution = false }
                Spacer()
                Button("Save") { markSolved() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    // MARK: Actions

    private func start() async {
        let text = problemDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var s = StuckSession(problem: text)
        s.messages = [ChatMessage(role: "user", text: text)]
        session = s
        problemDraft = ""
        await ask()
    }

    private func reply() async {
        let text = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var s = session, !thinking else { return }
        s.messages.append(ChatMessage(role: "user", text: text))
        session = s
        replyDraft = ""
        await ask()
    }

    private func ask() async {
        guard var s = session else { return }
        thinking = true
        error = nil
        do {
            let answer = try await coach.stuckReply(to: s)
            s.messages.append(ChatMessage(role: "assistant", text: answer))
            session = s
            stuckStore.upsert(s)
        } catch {
            self.error = error.localizedDescription
            stuckStore.upsert(s)
        }
        thinking = false
    }

    private func markSolved() {
        guard var s = session else { return }
        s.resolved = true
        let note = resolutionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        s.resolution = note.isEmpty ? nil : note
        session = s
        stuckStore.upsert(s)
        askingResolution = false
    }
}

struct Bubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 80) }
            richText(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isUser ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isUser ? 0 : 0.06)))
                .fixedSize(horizontal: false, vertical: true)
            if !isUser { Spacer(minLength: 80) }
        }
    }
}

// MARK: - Deviation panel ("Off your plan?")

@MainActor
final class DeviationModel: ObservableObject, Identifiable {
    enum Phase {
        case asking, reviewing
        case done(Judgement)
        case failed(String)
    }

    let id = UUID()
    let entry: Entry
    let alignment: Alignment
    let goals: [String]
    private let coach: CoachService

    @Published var explanation = ""
    @Published var phase: Phase = .asking
    var onClose: (@MainActor () -> Void)?

    init(entry: Entry, alignment: Alignment, goals: [String], coach: CoachService) {
        self.entry = entry
        self.alignment = alignment
        self.goals = goals
        self.coach = coach
    }

    func submit() async {
        let text = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        phase = .reviewing
        do {
            phase = .done(try await coach.judge(entry: entry, alignment: alignment, explanation: text))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func close() { onClose?() }
}

struct DeviationView: View {
    @ObservedObject var model: DeviationModel

    private let quickReasons = ["Urgent request", "Meeting ran over", "Needed a break",
                                "Priorities changed", "Supporting task for a goal"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Off your plan?").font(.title3.weight(.semibold))
                    Text("\(model.entry.timeRangeText) · \(CoachService.text(of: model.entry))")
                        .foregroundStyle(.secondary).lineLimit(2)
                    Text(model.alignment.reason).font(.callout)
                }
            }

            if !model.goals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TODAY'S GOALS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.goals, id: \.self) { g in
                        Label(g, systemImage: "target").font(.callout).labelStyle(.titleAndIcon)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }

            switch model.phase {
            case .asking:
                asking
            case .reviewing:
                HStack { ProgressView().controlSize(.small); Text("Reviewing your explanation…").foregroundStyle(.secondary) }
                    .padding(.vertical, 8)
            case .done(let j):
                VStack(alignment: .leading, spacing: 8) {
                    Label(j.accepted ? "Makes sense" : "Not quite convincing",
                          systemImage: j.accepted ? "checkmark.seal.fill" : "exclamationmark.bubble.fill")
                        .font(.headline)
                        .foregroundStyle(j.accepted ? Color.green : Color.orange)
                    Text(j.feedback)
                    if let s = j.suggestion, !s.isEmpty {
                        Label(s, systemImage: "lightbulb").foregroundStyle(.secondary)
                    }
                }
                HStack { Spacer(); Button("Done") { model.close() }.keyboardShortcut(.defaultAction) }
            case .failed(let msg):
                Text(msg).foregroundStyle(.red)
                HStack { Spacer(); Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What happened?").font(.headline)
            HStack(spacing: 6) {
                ForEach(quickReasons.prefix(3), id: \.self) { chip($0) }
            }
            HStack(spacing: 6) {
                ForEach(quickReasons.suffix(2), id: \.self) { chip($0) }
            }
            TextField("A sentence is enough", text: $model.explanation, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack {
                Button("Skip") { model.close() }
                Spacer()
                Button("Explain") { Task { await model.submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Button(text) {
            model.explanation = model.explanation.isEmpty ? text + ": " : model.explanation + " " + text
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
