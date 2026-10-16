import Foundation

/// State for one open entry window: text, voice note, countdown.
@MainActor
final class PromptSession: ObservableObject {
    let prompt: Prompt

    @Published var text = ""
    @Published private(set) var remaining: Int
    @Published private(set) var totalSeconds: Int
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var isTranscribing = false
    @Published private(set) var hasAudio = false
    @Published var errorMessage: String?

    var onFinish: (@MainActor (Entry) -> Void)?
    var onStuck: (@MainActor () -> Void)?
    /// Today's open goals, shown as a reminder in the window.
    var goalTexts: [String] = []
    /// The current step of the active plan, if any.
    var currentStep: String?

    private let settings: SettingsStore
    private let store: EntryStore
    private let recorder = AudioRecorder()
    private var deadline: Date
    private var transcript: String?
    private var tickTask: Task<Void, Never>?
    private var finished = false

    private var audioFileName: String { "\(prompt.id.uuidString).m4a" }

    init(prompt: Prompt, settings: SettingsStore, store: EntryStore) {
        self.prompt = prompt
        self.settings = settings
        self.store = store
        let seconds = settings.entryWindowMinutes * 60
        totalSeconds = seconds
        remaining = seconds
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
        startTicking()
    }

    var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAudio
    }

    // MARK: - Countdown

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        if isRecording { recordingSeconds = Int(recorder.currentTime) }
        if remaining == 0 { finish(.autoSaved) }
    }

    func extend(minutes: Int = 1) {
        deadline.addTimeInterval(TimeInterval(minutes * 60))
        totalSeconds += minutes * 60
        tick()
    }

    // MARK: - Voice note

    func toggleRecording() async {
        if isRecording {
            stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        errorMessage = nil
        guard await AudioRecorder.ensureMicPermission() else {
            errorMessage = AudioError.micDenied.errorDescription
            return
        }
        guard !finished else { return }
        do {
            try recorder.start(url: store.audioURL(fileName: audioFileName))
            transcript = nil
            recordingSeconds = 0
            isRecording = true
            hasAudio = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() {
        recorder.stop()
        isRecording = false
        if settings.autoTranscribe {
            Task { await transcribe() }
        }
    }

    private func transcribe() async {
        isTranscribing = true
        defer { isTranscribing = false }
        let url = store.audioURL(fileName: audioFileName)
        do {
            let result = try await Transcriber().transcribe(url: url, localeID: settings.speechLocaleID)
            guard !finished else { return }
            transcript = result
            if !result.isEmpty {
                text = text.isEmpty ? result : text + "\n" + result
            }
        } catch {
            guard !finished else { return }
            errorMessage = "Speech-to-text failed (voice note is still saved): \(error.localizedDescription)"
        }
    }

    /// Used when the user replies from the notification while this window is open.
    func appendText(_ extra: String) {
        let t = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        text = text.isEmpty ? t : text + "\n" + t
    }

    // MARK: - Finish

    func finish(_ requested: Entry.Status) {
        guard !finished else { return }
        finished = true
        tickTask?.cancel()

        let wasRecording = isRecording
        if isRecording {
            recorder.stop()
            isRecording = false
        }

        var status = requested
        var audio: String? = hasAudio ? audioFileName : nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if status == .skipped, let a = audio {
            try? FileManager.default.removeItem(at: store.audioURL(fileName: a))
            audio = nil
        }
        if status == .autoSaved && trimmed.isEmpty && audio == nil {
            status = .missed
        }

        // Transcribe later if we have audio but no transcript yet
        // (timed out mid-recording, or saved while transcription was running).
        let pending = audio != nil && settings.autoTranscribe && (wasRecording || isTranscribing || transcript == nil)

        let entry = Entry(
            prompt: prompt,
            text: status == .skipped ? "" : trimmed,
            status: status,
            audioFileName: audio,
            transcript: transcript,
            transcriptPending: pending
        )
        onFinish?(entry)
    }
}
