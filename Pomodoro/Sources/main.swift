// Pomodoro for the MacBook Pro Touch Bar.
// Single file, AppKit only. Built with build.sh (swiftc, no Xcode project).
//
// Public API: NSTouchBar on the app's window (shows while the app is frontmost),
// plus a menu bar countdown (always visible).
// Experimental (off by default): a tomato button in the Control Strip that opens
// the timer from any app. That part uses private, undocumented Apple APIs, looked
// up at runtime so the app still runs if they are missing. See README.md.

import Cocoa

// MARK: - Settings (override with: defaults write local.pomodoro workMinutes -int 50)

let defaults = UserDefaults.standard
func minutes(_ key: String, _ fallback: Int) -> Int {
    let v = defaults.integer(forKey: key)
    return v > 0 ? v : fallback
}

enum Phase {
    case work, shortBreak, longBreak

    var seconds: Int {
        switch self {
        case .work:       return minutes("workMinutes", 25) * 60
        case .shortBreak: return minutes("shortBreakMinutes", 5) * 60
        case .longBreak:  return minutes("longBreakMinutes", 15) * 60
        }
    }
    var emoji: String { self == .work ? "🍅" : "☕️" }
    var name: String {
        switch self {
        case .work: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }
}

// MARK: - Timer model

final class Pomodoro {
    private(set) var phase: Phase = .work
    private(set) var remaining: Int = Phase.work.seconds
    private(set) var running = false
    private(set) var completedWork = 0

    var onChange: (() -> Void)?
    var onPhaseEnd: ((Phase) -> Void)?

    private var timer: Timer?
    private var endDate: Date?

    func toggle() { running ? pause() : start() }

    func start() {
        guard !running else { return }
        running = true
        endDate = Date().addingTimeInterval(TimeInterval(remaining))
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keeps ticking while menus are open
        timer = t
        onChange?()
    }

    func pause() {
        guard running else { return }
        if let end = endDate { remaining = max(0, Int(ceil(end.timeIntervalSinceNow))) }
        running = false
        timer?.invalidate(); timer = nil
        endDate = nil
        onChange?()
    }

    func reset() {
        pause()
        remaining = phase.seconds
        onChange?()
    }

    func skip() { advance(finished: false) }

    private func tick() {
        guard let end = endDate else { return }
        let left = Int(ceil(end.timeIntervalSinceNow))
        if left <= 0 { advance(finished: true); return }
        if left != remaining { remaining = left; onChange?() }
    }

    private func advance(finished: Bool) {
        let ended = phase
        pause()
        if ended == .work {
            if finished { completedWork += 1 }
            let every = minutes("longBreakEvery", 4)
            phase = (finished && completedWork % every == 0) ? .longBreak : .shortBreak
        } else {
            phase = .work
        }
        remaining = phase.seconds
        if finished { onPhaseEnd?(ended) }
        if defaults.bool(forKey: "autoStartNext") { start() }
        onChange?()
    }

    var display: String {
        String(format: "%@ %02d:%02d", phase.emoji, remaining / 60, remaining % 60)
    }
}

// MARK: - Private Touch Bar APIs (experimental, runtime lookup only)
//
// These names come from what open-source Touch Bar tools (e.g. MTMR, Pock) have
// used. They are undocumented, could change or vanish in any macOS update, and
// I could not test them. Every call checks the symbol exists first.

enum PrivateTouchBar {
    private typealias ClassMethod1 = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias ClassMethod2 = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
    private typealias SetPresence  = @convention(c) (NSString, ObjCBool) -> Void

    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    private static func classIMP(_ cls: AnyClass, _ name: String) -> (Selector, IMP)? {
        let sel = NSSelectorFromString(name)
        guard let m = class_getClassMethod(cls, sel) else { return nil }
        return (sel, method_getImplementation(m))
    }

    static var isAvailable: Bool {
        classIMP(NSTouchBarItem.self, "addSystemTrayItem:") != nil
            && classIMP(NSTouchBar.self, "presentSystemModalTouchBar:systemTrayItemIdentifier:") != nil
            && dfr != nil && dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") != nil
    }

    static func report() -> String {
        let checks: [(String, Bool)] = [
            ("+[NSTouchBarItem addSystemTrayItem:]", classIMP(NSTouchBarItem.self, "addSystemTrayItem:") != nil),
            ("+[NSTouchBarItem removeSystemTrayItem:]", classIMP(NSTouchBarItem.self, "removeSystemTrayItem:") != nil),
            ("+[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]",
             classIMP(NSTouchBar.self, "presentSystemModalTouchBar:systemTrayItemIdentifier:") != nil),
            ("+[NSTouchBar dismissSystemModalTouchBar:]", classIMP(NSTouchBar.self, "dismissSystemModalTouchBar:") != nil),
            ("DFRFoundation loaded", dfr != nil),
            ("DFRElementSetControlStripPresenceForIdentifier",
             dfr.map { dlsym($0, "DFRElementSetControlStripPresenceForIdentifier") != nil } ?? false),
        ]
        return checks.map { "SELFTEST \($0.1 ? "found  " : "MISSING") \($0.0)" }.joined(separator: "\n")
            + "\nSELFTEST control strip feature available: \(isAvailable)"
    }

    static func addToControlStrip(_ item: NSTouchBarItem) {
        guard let m = classIMP(NSTouchBarItem.self, "addSystemTrayItem:") else { return }
        unsafeBitCast(m.1, to: ClassMethod1.self)(NSTouchBarItem.self as AnyObject, m.0, item)
        setPresence(item.identifier, true)
    }

    static func removeFromControlStrip(_ item: NSTouchBarItem) {
        setPresence(item.identifier, false)
        if let m = classIMP(NSTouchBarItem.self, "removeSystemTrayItem:") {
            unsafeBitCast(m.1, to: ClassMethod1.self)(NSTouchBarItem.self as AnyObject, m.0, item)
        }
    }

    static func presentModal(_ bar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) {
        guard let m = classIMP(NSTouchBar.self, "presentSystemModalTouchBar:systemTrayItemIdentifier:") else { return }
        unsafeBitCast(m.1, to: ClassMethod2.self)(NSTouchBar.self as AnyObject, m.0, bar, trayIdentifier.rawValue as NSString)
    }

    static func dismissModal(_ bar: NSTouchBar) {
        guard let m = classIMP(NSTouchBar.self, "dismissSystemModalTouchBar:") else { return }
        unsafeBitCast(m.1, to: ClassMethod1.self)(NSTouchBar.self as AnyObject, m.0, bar)
    }

    private static func setPresence(_ id: NSTouchBarItem.Identifier, _ on: Bool) {
        guard let dfr = dfr, let sym = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        unsafeBitCast(sym, to: SetPresence.self)(id.rawValue as NSString, ObjCBool(on))
    }
}

// MARK: - App

extension NSTouchBarItem.Identifier {
    static let timer = NSTouchBarItem.Identifier("local.pomodoro.timer")
    static let reset = NSTouchBarItem.Identifier("local.pomodoro.reset")
    static let skip  = NSTouchBarItem.Identifier("local.pomodoro.skip")
    static let tray  = NSTouchBarItem.Identifier("local.pomodoro.tray")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSWindowDelegate {
    let pomodoro = Pomodoro()
    var window: NSWindow!
    var bigLabel: NSTextField!
    var windowButton: NSButton!
    var statusItem: NSStatusItem!
    var stripMenuItem: NSMenuItem!

    var timerButtons: [NSButton] = []      // one per Touch Bar that shows the timer
    var modalBar: NSTouchBar?
    var trayItem: NSCustomTouchBarItem?
    var trayButton: NSButton?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMainMenu()
        buildWindow()
        buildStatusItem()

        pomodoro.onChange = { [weak self] in self?.refresh() }
        pomodoro.onPhaseEnd = { [weak self] ended in self?.phaseEnded(ended) }

        if defaults.bool(forKey: "controlStrip") { setControlStrip(true) }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }

    func applicationWillTerminate(_ note: Notification) {
        if let item = trayItem { PrivateTouchBar.removeFromControlStrip(item) }
    }

    // MARK: Touch Bar

    func makeTimerTouchBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.timer, .fixedSpaceSmall, .reset, .skip]
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        switch id {
        case .timer:
            let b = NSButton(title: pomodoro.display, target: self, action: #selector(toggle))
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            timerButtons.append(b)
            item.view = b
            refresh()
        case .reset:
            item.view = NSButton(title: "↺ Reset", target: self, action: #selector(reset))
        case .skip:
            item.view = NSButton(title: "⏭ Skip", target: self, action: #selector(skip))
        default:
            return nil
        }
        return item
    }

    // MARK: Control Strip (experimental)

    func setControlStrip(_ on: Bool) {
        if on {
            guard PrivateTouchBar.isAvailable else {
                let a = NSAlert()
                a.messageText = "Control Strip button isn't available"
                a.informativeText = "This macOS version doesn't expose the private Touch Bar calls this feature relies on. The timer still works in the app and the menu bar."
                a.runModal()
                defaults.set(false, forKey: "controlStrip")
                stripMenuItem.state = .off
                return
            }
            if trayItem == nil {
                let b = NSButton(title: "🍅", target: self, action: #selector(showModalBar))
                let item = NSCustomTouchBarItem(identifier: .tray)
                item.view = b
                trayItem = item; trayButton = b
            }
            PrivateTouchBar.addToControlStrip(trayItem!)
        } else if let item = trayItem {
            if let bar = modalBar { PrivateTouchBar.dismissModal(bar) }
            PrivateTouchBar.removeFromControlStrip(item)
        }
        defaults.set(on, forKey: "controlStrip")
        stripMenuItem.state = on ? .on : .off
        refresh()
    }

    @objc func showModalBar() {
        if modalBar == nil { modalBar = makeTimerTouchBar() }
        PrivateTouchBar.presentModal(modalBar!, trayIdentifier: .tray)
    }

    @objc func toggleControlStrip() { setControlStrip(stripMenuItem.state != .on) }

    // MARK: Actions

    @objc func toggle() { pomodoro.toggle() }
    @objc func reset()  { pomodoro.reset() }
    @objc func skip()   { pomodoro.skip() }

    func phaseEnded(_ ended: Phase) {
        NSSound(named: NSSound.Name("Glass"))?.play()
        NSApp.requestUserAttention(.informationalRequest)
        if trayItem != nil && defaults.bool(forKey: "controlStrip") { showModalBar() }
    }

    func refresh() {
        let text = pomodoro.display
        let color: NSColor? = pomodoro.running
            ? (pomodoro.phase == .work ? .systemRed : .systemGreen)
            : nil
        for b in timerButtons {
            b.title = pomodoro.running ? text : "▶︎ " + text
            b.bezelColor = color
        }
        trayButton?.title = pomodoro.running ? text : "🍅"
        statusItem?.button?.title = text
        bigLabel?.stringValue = text
        windowButton?.title = pomodoro.running ? "Pause" : "Start"
        window?.title = "Pomodoro · \(pomodoro.phase.name) · \(pomodoro.completedWork) done"
    }

    // MARK: UI scaffolding

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 150),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        bigLabel = NSTextField(labelWithString: pomodoro.display)
        bigLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        bigLabel.alignment = .center

        windowButton = NSButton(title: "Start", target: self, action: #selector(toggle))
        windowButton.keyEquivalent = " "
        let resetButton = NSButton(title: "Reset", target: self, action: #selector(reset))
        let skipButton = NSButton(title: "Skip", target: self, action: #selector(skip))

        let buttons = NSStackView(views: [windowButton, resetButton, skipButton])
        let stack = NSStackView(views: [bigLabel, buttons])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack

        window.touchBar = makeTimerTouchBar()   // public API: shown while this app is frontmost
        window.makeKeyAndOrderFront(nil)
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let menu = NSMenu()
        menu.addItem(withTitle: "Start / Pause", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset", action: #selector(reset), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Skip", action: #selector(skip), keyEquivalent: "").target = self
        menu.addItem(.separator())
        stripMenuItem = menu.addItem(withTitle: "Button in Control Strip (experimental)",
                                     action: #selector(toggleControlStrip), keyEquivalent: "")
        stripMenuItem.target = self
        menu.addItem(withTitle: "Show Window", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pomodoro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Pomodoro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

// `Pomodoro --selftest` prints which private Touch Bar calls exist on this Mac and exits.
if CommandLine.arguments.contains("--selftest") {
    print(PrivateTouchBar.report())
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
