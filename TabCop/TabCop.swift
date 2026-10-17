// TabCop — a menu-bar app that nudges you to focus when too many browser tabs are open.
// Counts tabs in Google Chrome and Safari via AppleScript (only if the browser is already running).
// Requires macOS 13+ (for SMAppService "Launch at Login").

import Cocoa
import UserNotifications
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    // MARK: - Settings
    private let checkInterval: TimeInterval = 30        // seconds between tab counts
    private let nagCooldown: TimeInterval = 10 * 60     // min seconds between repeat nudges while over the limit
    private let thresholdChoices = [10, 15, 20, 25, 30, 40, 50]

    private let browsers: [(name: String, bundleID: String)] = [
        ("Google Chrome", "com.google.Chrome"),
        ("Safari",        "com.apple.Safari"),
    ]

    private let focusMessages = [
        "Pick the ONE tab that matters right now. Close the rest.",
        "Too many open loops. Finish one thing before opening another.",
        "Your tabs are a to-do list you never agreed to. Trim it.",
        "Bookmark it, note it, or close it. Then get back to the task.",
        "Deep work needs a quiet screen. Close what you're not using.",
        "What were you actually trying to get done? Go back to that.",
    ]

    // MARK: - State
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var counts: [String: Int] = [:]          // browser name -> tab count (absent = not running)
    private var permissionDenied: Set<String> = []   // browsers where Automation permission was refused
    private var lastNotified: Date = .distantPast
    private var pausedUntil: Date = .distantPast

    private var threshold: Int {
        get { let v = defaults.integer(forKey: "threshold"); return v > 0 ? v : 15 }
        set { defaults.set(newValue, forKey: "threshold") }
    }

    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🗂 –"

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error { NSLog("TabCop: notification auth error: \(error)") }
            if !granted { NSLog("TabCop: notifications not allowed") }
        }

        check()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    // Show the banner even though the app counts as "active".
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Tab counting
    /// Returns nil if the browser isn't running or the script failed.
    private func countTabs(name: String, bundleID: String) -> Int? {
        // Don't use `tell application` on a closed browser — that would launch it.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return nil
        }
        let source = """
        set total to 0
        tell application id "\(bundleID)"
            repeat with w in windows
                try
                    set total to total + (count of tabs of w)
                end try
            end repeat
        end tell
        return total
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 { permissionDenied.insert(name) }   // errAEEventNotPermitted
            NSLog("TabCop: \(name) script error \(code): \(error)")
            return nil
        }
        permissionDenied.remove(name)
        return Int(result.int32Value)
    }

    @objc private func check() {
        var total = 0
        counts.removeAll()
        for b in browsers {
            if let n = countTabs(name: b.name, bundleID: b.bundleID) {
                counts[b.name] = n
                total += n
            }
        }

        let over = total > threshold
        statusItem.button?.title = over ? "⚠️ \(total)" : "🗂 \(total)"

        let now = Date()
        if over {
            if now > pausedUntil && now.timeIntervalSince(lastNotified) > nagCooldown {
                lastNotified = now
                sendNudge(total: total)
            }
        } else {
            lastNotified = .distantPast   // next time you cross the limit, nudge immediately
        }
        rebuildMenu()
    }

    private func sendNudge(total: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(total) tabs open — time to focus"
        content.body = focusMessages.randomElement() ?? "Close some tabs and focus."
        content.sound = .default
        // Same identifier replaces the previous nudge instead of stacking them.
        let request = UNNotificationRequest(identifier: "tabcop.nudge", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { NSLog("TabCop: failed to post notification: \(error)") }
        }
    }

    // MARK: - Menu
    private func rebuildMenu() {
        let menu = NSMenu()

        for b in browsers {
            let detail: String
            if permissionDenied.contains(b.name) { detail = "permission needed" }
            else if let n = counts[b.name] { detail = "\(n) tabs" }
            else { detail = "not running" }
            menu.addItem(NSMenuItem(title: "\(b.name): \(detail)", action: nil, keyEquivalent: ""))
        }

        if !permissionDenied.isEmpty {
            let fix = NSMenuItem(title: "Open Automation Settings…", action: #selector(openAutomationSettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }

        menu.addItem(.separator())

        let limitItem = NSMenuItem(title: "Tab limit: \(threshold)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for t in thresholdChoices {
            let item = NSMenuItem(title: "\(t) tabs", action: #selector(setThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = t
            item.state = (t == threshold) ? .on : .off
            sub.addItem(item)
        }
        limitItem.submenu = sub
        menu.addItem(limitItem)

        let pauseTitle: String
        if Date() < pausedUntil {
            let f = DateFormatter(); f.timeStyle = .short
            pauseTitle = "Paused until \(f.string(from: pausedUntil)) — Resume"
        } else {
            pauseTitle = "Pause nudges for 1 hour"
        }
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let checkNow = NSMenuItem(title: "Check now", action: #selector(check), keyEquivalent: "r")
        checkNow.target = self
        menu.addItem(checkNow)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TabCop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        threshold = sender.tag
        lastNotified = .distantPast
        check()
    }

    @objc private func togglePause() {
        pausedUntil = (Date() < pausedUntil) ? .distantPast : Date().addingTimeInterval(3600)
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("TabCop: launch-at-login change failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add TabCop manually in System Settings → General → Login Items."
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
