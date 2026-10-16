import Combine
import SwiftUI

/// Timed brain-dump: one prompt at a time, each with its own countdown.
/// Type or speak; when time runs out it moves on and keeps what was written.
struct BrainDumpView: View {
    @Binding var notes: [DumpNote]
    let localeID: String
    let busy: Bool
    let onDone: () -> Void
    let onFreeText: () -> Void

    enum Phase { case intro, running, review }

    @AppStorage("brainDumpSeconds") private var seconds = 60
    @State private var phase: Phase = .intro
    @State private var index = 0
    @State private var deadline = Date()
    @State private var total = 60
    @State private var remaining = 60
    @State private var recorder = AudioRecorder()
    @State private var recording = false
    @State private var recordingURL: URL?
    @State private var recordingIndex = 0
    @State private var transcribing = 0
    @State private var micError: String?
    @State private var started = false

    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var hasContent: Bool {
        notes.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        Card(title: "Brain-dump", symbol: "brain.head.profile") {
            switch phase {
            case .intro: intro
            case .running: running
            case .review: review
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            phase = hasContent ? .review : .intro
        }
        .onReceive(ticker) { _ in tick() }
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before any questions, empty your head about this task. \(BrainDump.prompts.count) short prompts, a timer for each — type or speak. Don't polish; the coach reads all of it and won't ask what you've already covered.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(BrainDump.prompts.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 16)
                        Text(p.0).font(.callout)
                    }
                }
            }
            HStack {
                Text("Time per prompt")
                Picker("Time per prompt", selection: $seconds) {
                    Text("30 s").tag(30)
                    Text("1 min").tag(60)
                    Text("90 s").tag(90)
                    Text("2 min").tag(120)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Text("≈ \(durationText(Double(seconds * BrainDump.prompts.count)))")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button("Write freely instead", action: onFreeText).buttonStyle(.borderless)
                Spacer()
                Button { start() } label: { Label("Start brain-dump", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    // MARK: Running

    @ViewBuilder private var running: some View {
        if index < notes.count {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("\(index + 1) of \(notes.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ProgressView(value: Double(index), total: Double(notes.count)).frame(width: 180)
                    Spacer()
                    CountdownRing(remaining: remaining, total: total)
                }
                Text(notes[index].prompt).font(.title2.weight(.semibold))
                Text(BrainDump.hint(for: notes[index].prompt)).foregroundStyle(.secondary)
                TextField("Note", text: $notes[index].text, prompt: Text("Type freely — don't polish"), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...12)
                    .font(.body)
                if let micError { Text(micError).font(.callout).foregroundStyle(.red) }
                HStack(spacing: 10) {
                    Button { toggleMic() } label: {
                        Label(recording ? "Stop" : "Speak", systemImage: recording ? "stop.circle.fill" : "mic.circle.fill")
                    }
                    .tint(recording ? .red : nil)
                    .keyboardShortcut("r", modifiers: .command)
                    if recording {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Listening…").foregroundStyle(.secondary)
                    } else if transcribing > 0 {
                        ProgressView().controlSize(.small)
                        Text("Converting speech…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("+30s") { addTime() }
                    Button("Skip") { next() }
                    Button(index + 1 == notes.count ? "Finish" : "Next") { next() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                Text("Moves on automatically when time's up — whatever you wrote or said is kept. ⌘↩ for next, ⌘R to speak.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your notes — edit anything. The coach uses these for the questions, the heart of the problem, the brief and the steps.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($notes) { $n in
                VStack(alignment: .leading, spacing: 4) {
                    Text(n.prompt.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    TextField(n.prompt, text: $n.text, prompt: Text("(nothing yet)"), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...8)
                }
            }
            if transcribing > 0 {
                HStack { ProgressView().controlSize(.small); Text("Still converting speech…").foregroundStyle(.secondary) }
            }
            HStack {
                Button("Redo brain-dump") { start() }.buttonStyle(.borderless)
                Button("Write freely instead", action: onFreeText).buttonStyle(.borderless)
                Spacer()
                Button(action: onDone) { Label("Ask me questions", systemImage: "questionmark.bubble") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasContent || busy || transcribing > 0)
            }
        }
    }

    // MARK: Timer

    private func start() {
        if notes.count != BrainDump.prompts.count {
            let old = Dictionary(notes.map { ($0.prompt, $0.text) }, uniquingKeysWith: { a, _ in a })
            notes = BrainDump.fresh().map { var n = $0; n.text = old[n.prompt] ?? ""; return n }
        }
        index = 0
        startTimer()
        phase = .running
    }

    private func startTimer() {
        total = seconds
        remaining = seconds
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
    }

    private func tick() {
        guard phase == .running else { return }
        remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        if remaining == 0 { next() }
    }

    private func addTime() {
        deadline.addTimeInterval(30)
        total += 30
        tick()
    }

    private func next() {
        if recording { stopRecording() }
        if index + 1 < notes.count {
            index += 1
            startTimer()
        } else {
            phase = .review
        }
    }

    // MARK: Voice

    private func toggleMic() {
        if recording { stopRecording(); return }
        micError = nil
        Task {
            guard await AudioRecorder.ensureMicPermission() else {
                micError = AudioError.micDenied.errorDescription
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("braindump-\(UUID().uuidString).m4a")
            do {
                try recorder.start(url: url)
                recordingURL = url
                recordingIndex = index
                recording = true
            } catch {
                micError = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        recorder.stop()
        recording = false
        guard let url = recordingURL else { return }
        recordingURL = nil
        let target = recordingIndex
        transcribing += 1
        Task {
            defer {
                transcribing -= 1
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let text = try await Transcriber().transcribe(url: url, localeID: localeID)
                guard !text.isEmpty, target < notes.count else { return }
                notes[target].text += (notes[target].text.isEmpty ? "" : " ") + text
            } catch {
                micError = "Speech-to-text failed: \(error.localizedDescription)"
            }
        }
    }
}
