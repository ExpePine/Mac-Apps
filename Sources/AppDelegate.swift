import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let settings: SettingsStore
    let store: EntryStore
    let scheduler: Scheduler
    let windows: WindowManager
    let reports: ReportService
    let tracker: UsageTracker
    let goals: GoalsStore
    let stuckStore: StuckStore
    let coach: CoachService
    let archive: ReportArchive
    let plans: PlanStore
    let analysis: AnalysisStore
    let nav = Navigator()

    /// The check-in that is waiting for an answer (if any).
    private var pendingPrompt: Prompt?
    /// The entry window currently on screen (if any).
    private var activeSession: PromptSession?

    private enum Note {
        static let category = "CHECKIN"
        static let reply = "REPLY"
        static let open = "OPEN"
        static let skip = "SKIP"
        static let promptKey = "promptID"
    }

    override init() {
        SandboxMigration.runIfNeeded()   // must run before stores load
        settings = SettingsStore()
        store = EntryStore()
        scheduler = Scheduler(settings: settings)
        windows = WindowManager()
        let usage = UsageStore(baseDirectory: store.directory)
        tracker = UsageTracker(settings: settings, usage: usage)
        goals = GoalsStore(directory: store.directory)
        stuckStore = StuckStore(directory: store.directory)
        coach = CoachService(settings: settings, store: store, goals: goals, usage: usage, stuck: stuckStore)
        plans = PlanStore(directory: store.directory)
        coach.plans = plans
        archive = ReportArchive(baseDirectory: store.directory, store: store, usage: usage, goals: goals)
        archive.plans = plans
        analysis = AnalysisStore(directory: store.directory)
        reports = ReportService(settings: settings, store: store, usage: usage, goals: goals, archive: archive)
        super.init()

        scheduler.onPrompt = { [weak self] start, end in
            self?.firePrompt(start: start, end: end)
        }
        windows.onPromptClosedByUser = { [weak self] in
            self?.activeSession?.finish(.autoSaved)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reply = UNTextInputNotificationAction(
            identifier: Note.reply,
            title: "Quick reply",
            options: [],
            textInputButtonTitle: "Save",
            textInputPlaceholder: "What did you work on?"
        )
        let open = UNNotificationAction(identifier: Note.open, title: "Open entry window", options: [.foreground])
        let skip = UNNotificationAction(identifier: Note.skip, title: "Skip", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Note.category, actions: [reply, open, skip],
                                   intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Morning goals: check shortly after launch, then every 10 minutes.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            while !Task.isCancelled {
                self?.maybeAskForGoals()
                try? await Task.sleep(nanoseconds: 600_000_000_000)
            }
        }
    }

    // MARK: - Main window & goals

    /// Creates a draft plan and opens it in Plans.
    func startPlan(goal: String, template: Plan? = nil, autoSuggest: Bool = false) {
        var plan = Plan(goal: goal)
        if let template {
            plan.steps = template.steps.map { PlanStep(text: $0.text, minutes: $0.minutes, why: $0.why, source: $0.source) }
        }
        plan.log(.created, template == nil ? "Draft created" : "Draft created from an earlier plan")
        plans.upsert(plan)
        nav.selectedPlan = plan.id
        if autoSuggest && !goal.isEmpty && template == nil { nav.autoSuggestPlan = plan.id }
        showMain(.plans)
    }

    func showMain(_ section: MainSection) {
        nav.section = section
        windows.showMain(app: self, nav: nav)
    }

    /// Opens Goals once per day (from 5 am) if today's goals are empty.
    /// Shows the goals gate when goals are missing (re-checked every 10 minutes).
    private func maybeAskForGoals() {
        guard needsGoals else { return }
        // Don't pop up while the user is away (idle > 5 min).
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 300 else { return }
        if let until = gateSnoozedUntil, Date() < until { return }
        showGoalsGate()
    }

    // MARK: - Goals gate

    private var gateSnoozedUntil: Date?

    /// Today is marked "day off": no check-ins, no gate.
    var isDayOff: Bool { UserDefaults.standard.string(forKey: "dayOff") == GoalsStore.dayKey(Date()) }

    /// Check-ins wait until today's goals (and this month's) exist.
    var needsGoals: Bool {
        guard settings.requireGoals, !isDayOff else { return false }
        // Between midnight and 5 am the previous day's goals still count.
        guard Calendar.current.component(.hour, from: Date()) >= 5 else { return false }
        return goals.activeToday.isEmpty || goals.activeMonth.isEmpty
    }

    func showGoalsGate() {
        windows.showGate(GoalsGateView(goals: goals, onStart: { [weak self] in self?.gateDone() },
                                       onSnooze: { [weak self] in self?.snoozeGate() },
                                       onDayOff: { [weak self] in self?.takeDayOff() }))
    }

    private func gateDone() {
        windows.closeGate()
        gateSnoozedUntil = nil
        // The first check-in comes one full interval after the day is planned.
        if scheduler.isPaused { scheduler.resume() } else { scheduler.restart() }
        pendingPrompt = nil
    }

    private func snoozeGate() {
        gateSnoozedUntil = Date().addingTimeInterval(600)
        windows.closeGate()
    }

    private func takeDayOff() {
        UserDefaults.standard.set(GoalsStore.dayKey(Date()), forKey: "dayOff")
        windows.closeGate()
    }

    // MARK: - Check-in flow

    private func firePrompt(start: Date, end: Date) {
        // Still writing the previous one — don't interrupt.
        if activeSession != nil { return }
        if isDayOff { return }
        // No goals yet: plan the day first, no check-in.
        if needsGoals {
            if let until = gateSnoozedUntil, Date() < until { return }
            showGoalsGate()
            return
        }

        // Previous check-in was never answered.
        if let old = pendingPrompt {
            store.add(Entry(prompt: old, text: "", status: .missed))
            removeNotification(old.id)
        }

        let prompt = Prompt(start: start, end: end)
        pendingPrompt = prompt
        postNotification(for: prompt)
        if settings.autoOpenWindow {
            openSession(for: prompt)
        }
    }

    /// Menu bar "Log now".
    func logNow() {
        if needsGoals {
            gateSnoozedUntil = nil
            showGoalsGate()
            return
        }
        if activeSession != nil {
            windows.bringPromptToFront()
            return
        }
        if let pending = pendingPrompt {
            openSession(for: pending)
            return
        }
        let prompt = Prompt(start: scheduler.lastFire, end: Date())
        scheduler.restart()
        pendingPrompt = prompt
        openSession(for: prompt)
    }

    func showHistory() { showMain(.history) }

    func showEmailSettings() { showMain(.settings) }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.flush()
    }

    private func openSession(for prompt: Prompt) {
        if let s = activeSession, s.prompt.id == prompt.id {
            windows.bringPromptToFront()
            return
        }
        let session = PromptSession(prompt: prompt, settings: settings, store: store)
        session.goalTexts = goals.activeToday.filter { !$0.done }.map(\.text)
        if let plan = plans.activePlan, let i = plan.currentIndex { session.currentStep = plan.steps[i].text }
        configurePath(session)
        session.onFinish = { [weak self] entry in self?.resolve(entry) }
        session.onStuck = { [weak self] in self?.showMain(.stuck) }
        activeSession = session
        windows.showPrompt(session)
    }

    /// Goals, active plan steps and time-per-goal for the one-tap check-in.
    private func configurePath(_ session: PromptSession) {
        let month = goals.activeMonth.map(\.text)
        let today = goals.activeToday.filter { !$0.done }.map(\.text).filter { !month.contains($0) }
        session.goalOptions = month + today

        let active = plans.plans.filter { $0.status == .active }.sorted { $0.lastActivity > $1.lastActivity }.prefix(2)
        session.planPaths = active.compactMap { p in
            let remaining = p.steps.filter { $0.status == .todo || $0.status == .doing || $0.status == .blocked }
            guard !remaining.isEmpty else { return nil }
            let current = p.currentIndex.map { p.steps[$0].id }
            return PromptSession.PlanPath(id: p.id, goal: p.goal, steps: Array(remaining.prefix(4)), currentStepID: current)
        }

        let all = month + goals.activeToday.map(\.text).filter { !month.contains($0) }
        session.todayRows = GoalAccounting.rows(store.entries(on: Date()), goals: all)
        // What I said I'd do in this period (from the last check-in, if recent).
        let maxGap = TimeInterval(settings.intervalMinutes * 60 * 2 + 300)
        if let last = store.entries
            .filter({ $0.status != .missed && $0.status != .skipped && $0.periodEnd <= session.prompt.start.addingTimeInterval(60) })
            .max(by: { $0.periodEnd < $1.periodEnd }),
           session.prompt.start.timeIntervalSince(last.periodEnd) <= maxGap,
           let text = last.nextIntent, !text.isEmpty {
            session.previousIntent = PromptSession.Intent(text: text, goal: last.nextGoal, kind: last.nextKind,
                                                         planID: last.nextPlanID, stepID: last.nextStepID)
        }
        let judged = store.entries(on: Date()).compactMap(\.intentResult)
        if !judged.isEmpty {
            let done = judged.reduce(0.0) { $0 + ($1 == "did" ? 1 : ($1 == "partly" ? 0.5 : 0)) }
            session.followThrough = (done, judged.count)
        }

        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())
        let weekEntries = store.entries.filter { week?.contains($0.periodEnd) ?? false }
        session.weekRows = GoalAccounting.rows(weekEntries, goals: all)
    }

    private func resolve(_ entry: Entry) {
        store.add(entry)
        advancePlan(with: entry)
        if entry.transcriptPending {
            store.transcribeInBackground(entry.id, localeID: settings.speechLocaleID)
        }
        if pendingPrompt?.id == entry.id { pendingPrompt = nil }
        removeNotification(entry.id)
        activeSession = nil
        windows.closePrompt()
        reviewAgainstGoals(entry)
    }

    /// Ask the coach whether this check-in served today's goals; if not, ask why.
    /// A check-in on a plan step starts it, or completes it if ticked.
    private func advancePlan(with entry: Entry) {
        guard let pid = entry.planID, let sid = entry.stepID else { return }
        plans.update(pid) { p in
            guard let i = p.steps.firstIndex(where: { $0.id == sid }) else { return }
            if p.steps[i].startedAt == nil { p.steps[i].startedAt = entry.periodStart }
            if entry.stepCompleted == true {
                p.steps[i].status = .done
                p.steps[i].finishedAt = entry.periodEnd
                p.log(.stepDone, "Done: \(p.steps[i].text)", step: sid)
            } else if p.steps[i].status == .todo {
                p.steps[i].status = .doing
                p.log(.stepStarted, "Started: \(p.steps[i].text)", step: sid)
            }
        }
    }

    private func reviewAgainstGoals(_ entry: Entry) {
        guard entry.status == .completed || entry.status == .quickReply || entry.status == .autoSaved else {
            return
        }
        // Said something in free text last time and the app couldn't tell: let the coach judge.
        if let intent = entry.intentFor, entry.intentResult == nil, coach.hasKey {
            let usage = usageSummary(tracker.usage.usage(for: entry.periodEnd), from: entry.periodStart, to: entry.periodEnd)
            Task { [weak self] in
                guard let self, let r = await self.coach.judgeIntent(intent: intent, did: CoachService.text(of: entry), usage: usage) else { return }
                self.store.update(entry.id) {
                    $0.intentResult = r.result
                    if $0.intentReason == nil { $0.intentReason = r.reason }
                }
            }
        }
        // Tapped a goal or step: it's on plan, no AI check needed.
        if let tag = entry.goalTag, entry.checkinKind != "drift" {
            store.update(entry.id) {
                $0.goalAligned = true
                $0.alignedGoal = tag
            }
            return
        }
        // Breaks, meetings and admin are neutral.
        if let k = entry.checkinKind, GoalAccounting.breakKinds[k] != nil { return }
        // Marked as drift: ask why straight away.
        if entry.checkinKind == "drift" {
            let reason = "You marked this time as drift."
            store.update(entry.id) {
                $0.goalAligned = false
                $0.deviationNote = reason
            }
            let latest = store.entries.first { $0.id == entry.id } ?? entry
            windows.showDeviation(DeviationModel(entry: latest, alignment: Alignment(aligned: false, goal: nil, reason: reason),
                                                 goals: goals.activeToday.map(\.text), coach: coach))
            return
        }
        Task { [weak self] in
            guard let self, let alignment = await self.coach.review(entry), !alignment.aligned else { return }
            let latest = self.store.entries.first { $0.id == entry.id } ?? entry
            let model = DeviationModel(entry: latest, alignment: alignment,
                                       goals: self.goals.activeToday.map(\.text), coach: self.coach)
            self.windows.showDeviation(model)
        }
    }

    // MARK: - Notifications

    private func postNotification(for prompt: Prompt) {
        let content = UNMutableNotificationContent()
        content.title = "What did you do in the last \(settings.intervalMinutes) min?"
        content.body = settings.autoOpenWindow
            ? "\(prompt.rangeText) · entry window is open for \(settings.entryWindowMinutes) min"
            : "\(prompt.rangeText) · click to log, or use Quick reply"
        content.categoryIdentifier = Note.category
        content.userInfo = [Note.promptKey: prompt.id.uuidString]
        if settings.playSound { content.sound = .default }

        let request = UNNotificationRequest(identifier: prompt.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func removeNotification(_ id: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    private func handleNotificationResponse(action: String, promptID: String?, typed: String?) {
        guard let idString = promptID,
              let id = UUID(uuidString: idString),
              let prompt = pendingPrompt, prompt.id == id
        else { return } // already answered or missed

        let session = (activeSession?.prompt.id == id) ? activeSession : nil

        switch action {
        case Note.reply:
            let text = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let session {
                session.appendText(text)
                session.finish(.completed)
            } else {
                resolve(Entry(prompt: prompt, text: text, status: text.isEmpty ? .missed : .quickReply))
            }
        case Note.skip:
            if let session { session.finish(.skipped) }
            else { resolve(Entry(prompt: prompt, text: "", status: .skipped)) }
        default:
            // Clicked the notification itself, or "Open entry window".
            openSession(for: prompt)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let promptID = response.notification.request.content.userInfo[Note.promptKey] as? String
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            self.handleNotificationResponse(action: action, promptID: promptID, typed: typed)
        }
    }
}
