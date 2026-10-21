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

    // MARK: Path (one-tap logging)

    struct PlanPath: Identifiable {
        let id: UUID
        let goal: String
        let steps: [PlanStep]          // remaining steps, current first
        let currentStepID: UUID?
    }

    /// Goals to tap (this month's, then today's).
    var goalOptions: [String] = []
    var planPaths: [PlanPath] = []
    var todayRows: [GoalTimeRow] = []
    var weekRows: [GoalTimeRow] = []

    // MARK: Intentions

    struct Intent {
        let text: String
        let goal: String?
        let kind: String?
        let planID: UUID?
        let stepID: UUID?
    }

    enum NextChoice: Equatable {
        case none, same, nextStep(planID: UUID, stepID: UUID, text: String), goal(String), kind(String)
    }

    /// What I said I'd do in this period (from the previous check-in).
    var previousIntent: Intent?
    var followThrough: (done: Double, total: Int)?

    @Published var intentResult: String?          // did / partly / didnt
    @Published var intentReason: String?
    private var intentManual = false
    @Published var nextChoice: NextChoice = .none
    @Published var nextText = ""
    private var nextManual = false

    func setIntentResult(_ r: String) {
        intentManual = true
        intentResult = (intentResult == r) ? nil : r
        if intentResult == "did" { intentReason = nil }
    }

    func setNext(_ c: NextChoice) {
        nextManual = true
        nextChoice = (nextChoice == c) ? .none : c
    }

    /// The step after the selected one in the same plan path.
    var followingStep: (path: PlanPath, step: PlanStep)? {
        guard let sid = selectedStep, let path = planPaths.first(where: { $0.steps.contains { $0.id == sid } }),
              let i = path.steps.firstIndex(where: { $0.id == sid }), i + 1 < path.steps.count else { return nil }
        return (path, path.steps[i + 1])
    }

    /// Compares what I said with what I picked (unless I set it by hand).
    private func autoAssess() {
        guard let p = previousIntent, !intentManual else { return }
        if selectedKind == "drift" { intentResult = "didnt"; return }
        if let ps = p.stepID, selectedStep == ps { intentResult = "did"; return }
        if let ps = p.stepID, let sel = selectedStep, ps != sel,
           let plan = planPaths.first(where: { $0.id == p.planID }), plan.steps.contains(where: { $0.id == sel }) {
            intentResult = "did"; return      // moved on to a later step of the same plan
        }
        if let pg = p.goal, let sg = selectedGoal, pg == sg { intentResult = "did"; return }
        if let pk = p.kind, pk == selectedKind { intentResult = "did"; return }
        if (p.goal != nil || p.stepID != nil || p.kind != nil) && hasSelection { intentResult = "didnt"; return }
        intentResult = nil
    }

    /// Default "next" follows the current selection unless chosen by hand.
    private func autoNext() {
        guard !nextManual else { return }
        if stepDone, let f = followingStep {
            nextChoice = .nextStep(planID: f.path.id, stepID: f.step.id, text: f.step.text)
        } else {
            nextChoice = hasSelection && selectedKind != "drift" ? .same : .none
        }
    }

    func selectionChanged() {
        autoAssess()
        autoNext()
    }

    /// Starts on what I said I'd do (the guess may still override it).
    func preselectFromIntent() {
        guard let p = previousIntent, !userPicked else { return }
        if let k = p.kind, ["break", "meeting", "admin"].contains(k) {
            selectedKind = k
        } else if let sid = p.stepID, let pid = p.planID, planPaths.contains(where: { $0.id == pid }) {
            selectedStep = sid; selectedPlan = pid; selectedGoal = p.goal
        } else if let g = p.goal {
            selectedGoal = g
        } else {
            return
        }
        guessNote = "Pre-filled from what you planned — tap to change"
        selectionChanged()
    }

    @Published var selectedGoal: String?
    @Published var selectedKind: String?          // break / meeting / admin / drift
    @Published var selectedStep: UUID?
    @Published var selectedPlan: UUID?
    @Published var stepDone = false { didSet { if oldValue != stepDone { selectionChanged() } } }
    @Published var guessing = false
    @Published var guessNote: String?
    private var userPicked = false

    var intervalMinutes: Int { settings.intervalMinutes }

    var hasSelection: Bool { selectedGoal != nil || selectedKind != nil || selectedStep != nil }

    func pickGoal(_ g: String) {
        defer { selectionChanged() }
        userPicked = true; guessNote = nil
        if selectedGoal == g && selectedStep == nil { selectedGoal = nil; return }
        selectedGoal = g; selectedKind = nil; selectedStep = nil; selectedPlan = nil; stepDone = false
    }

    func pickKind(_ k: String) {
        defer { selectionChanged() }
        userPicked = true; guessNote = nil
        if selectedKind == k { selectedKind = nil; return }
        selectedKind = k; selectedGoal = nil; selectedStep = nil; selectedPlan = nil; stepDone = false
    }

    func pickStep(_ step: PlanStep, in path: PlanPath) {
        defer { selectionChanged() }
        userPicked = true; guessNote = nil
        if selectedStep == step.id { selectedStep = nil; selectedPlan = nil; selectedGoal = nil; stepDone = false; return }
        selectedStep = step.id
        selectedPlan = path.id
        selectedGoal = GoalAccounting.match(path.goal, in: goalOptions) ?? path.goal
        selectedKind = nil
    }

    /// Applies the coach's guess, unless the user already chose something.
    func applyGuess(_ g: PositionGuess) {
        guard !userPicked, !finished else { return }
        defer { selectionChanged() }
        if let k = ["break", "meeting", "admin", "drift"].first(where: { $0 == g.kind }) {
            selectedKind = k
        } else if let sid = g.stepID, let pid = g.planID {
            selectedStep = sid; selectedPlan = pid; selectedGoal = g.goal
        } else if let goal = g.goal {
            selectedGoal = goal
        } else {
            return
        }
        guessNote = g.why.isEmpty ? "Best guess — tap to change" : "Guess: \(g.why) — tap to change"
    }

    private var composedText: String {
        if let k = selectedKind {
            return ["break": "Break", "meeting": "Meeting", "admin": "Admin / email", "drift": "Drifted from plan"][k] ?? k
        }
        if let sid = selectedStep, let step = planPaths.flatMap(\.steps).first(where: { $0.id == sid }) {
            return "Worked on: \(step.text)" + (stepDone ? " — done ✓" : "")
        }
        if let g = selectedGoal { return "Worked on: \(g)" }
        return ""
    }

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
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAudio || hasSelection
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
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typed words win; otherwise the tapped path position becomes the text.
        let trimmed = typed.isEmpty ? composedText : (hasSelection ? "\(composedText) — \(typed)" : typed)

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

        var entry = Entry(
            prompt: prompt,
            text: status == .skipped ? "" : trimmed,
            status: status,
            audioFileName: audio,
            transcript: transcript,
            transcriptPending: pending
        )
        if let p = previousIntent, status != .skipped {
            entry.intentFor = p.text
            entry.intentResult = status == .missed ? "didnt" : intentResult
            entry.intentReason = intentReason
        }
        if status != .skipped && status != .missed {
            // Next interval intention
            let typedNext = nextText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch nextChoice {
            case .same:
                entry.nextGoal = selectedGoal
                entry.nextKind = selectedKind ?? (selectedGoal != nil ? "goal" : nil)
                entry.nextPlanID = selectedStep != nil && !stepDone ? selectedPlan : nil
                entry.nextStepID = stepDone ? nil : selectedStep
                entry.nextIntent = typedNext.isEmpty ? "Continue: " + composedText.replacingOccurrences(of: "Worked on: ", with: "") : typedNext
            case .nextStep(let pid, let sid, let text):
                entry.nextPlanID = pid; entry.nextStepID = sid
                entry.nextGoal = selectedGoal ?? planPaths.first { $0.id == pid }.map { GoalAccounting.match($0.goal, in: goalOptions) ?? $0.goal }
                entry.nextKind = "goal"
                entry.nextIntent = typedNext.isEmpty ? text : typedNext
            case .goal(let g):
                entry.nextGoal = g; entry.nextKind = "goal"
                entry.nextIntent = typedNext.isEmpty ? g : typedNext
            case .kind(let k):
                entry.nextKind = k
                entry.nextIntent = typedNext.isEmpty ? (k == "break" ? "Take a break" : k.capitalized) : typedNext
            case .none:
                entry.nextIntent = typedNext.isEmpty ? nil : typedNext
            }
            entry.goalTag = selectedGoal
            entry.checkinKind = selectedKind ?? (selectedGoal != nil ? "goal" : nil)
            entry.planID = selectedPlan
            entry.stepID = selectedStep
            entry.stepCompleted = selectedStep != nil ? stepDone : nil
        }
        onFinish?(entry)
    }
}
