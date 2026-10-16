import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let settings: SettingsStore
    let store: EntryStore
    let scheduler: Scheduler
    let windows: WindowManager
    let reports: ReportService

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
        settings = SettingsStore()
        store = EntryStore()
        scheduler = Scheduler(settings: settings)
        windows = WindowManager()
        reports = ReportService(settings: settings, store: store)
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
    }

    // MARK: - Check-in flow

    private func firePrompt(start: Date, end: Date) {
        // Still writing the previous one — don't interrupt.
        if activeSession != nil { return }

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

    func showHistory() {
        windows.showHistory(store: store, settings: settings)
    }

    func showEmailSettings() {
        windows.showEmailSettings(settings: settings, reports: reports)
    }

    private func openSession(for prompt: Prompt) {
        if let s = activeSession, s.prompt.id == prompt.id {
            windows.bringPromptToFront()
            return
        }
        let session = PromptSession(prompt: prompt, settings: settings, store: store)
        session.onFinish = { [weak self] entry in self?.resolve(entry) }
        activeSession = session
        windows.showPrompt(session)
    }

    private func resolve(_ entry: Entry) {
        store.add(entry)
        if entry.transcriptPending {
            store.transcribeInBackground(entry.id, localeID: settings.speechLocaleID)
        }
        if pendingPrompt?.id == entry.id { pendingPrompt = nil }
        removeNotification(entry.id)
        activeSession = nil
        windows.closePrompt()
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
