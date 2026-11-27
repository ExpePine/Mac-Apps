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
        remaining = left
        onChange?()   // every tick (4x a second) so the progress bar moves smoothly
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

    /// 0 at the start of a phase, 1 when it's over. Smooth (sub-second) while running.
    var progress: Double {
        let total = Double(phase.seconds)
        guard total > 0 else { return 0 }
        let left = endDate.map { max(0, $0.timeIntervalSinceNow) } ?? Double(remaining)
        return min(1, max(0, 1 - left / total))
    }

    var timeText: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }

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

// MARK: - Task (what you're working on)

enum CurrentTask {
    static var text: String {
        get { defaults.string(forKey: "task")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { defaults.set(newValue, forKey: "task") }
    }
}

// MARK: - Progress bar view (used on the Touch Bar and in the window)
//
// A rounded bar that fills left to right as the phase runs, with the task
// written on the left and the time left on the right. Tapping it starts/pauses.

final class ProgressBarView: NSView {
    var progress: Double = 0 { didSet { if progress != oldValue { needsDisplay = true } } }
    var title = ""           { didSet { if title != oldValue { needsDisplay = true } } }
    var timeText = ""        { didSet { if timeText != oldValue { needsDisplay = true } } }
    var fillColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    var paused = true        { didSet { if paused != oldValue { needsDisplay = true } } }
    var fontSize: CGFloat
    var onTap: (() -> Void)?

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        tap.allowedTouchTypes = [.direct]   // finger taps on the Touch Bar; mouse clicks work as usual
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func tapped() { onTap?() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let radius = min(7, r.height / 2)
        let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        NSColor(white: 0.18, alpha: 1).setFill()
        shape.fill()

        let w = r.width * CGFloat(progress)
        if w > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            fillColor.withAlphaComponent(paused ? 0.45 : 0.9).setFill()
            NSRect(x: r.minX, y: r.minY, width: w, height: r.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let pad: CGFloat = 10
        let time = NSAttributedString(string: (paused ? "▶︎ " : "") + timeText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let ts = time.size()
        time.draw(at: NSPoint(x: r.maxX - pad - ts.width, y: r.midY - ts.height / 2))

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ])
        let lh = label.size().height
        label.draw(in: NSRect(x: r.minX + pad, y: r.midY - lh / 2,
                              width: max(0, r.width - 3 * pad - ts.width), height: lh))
    }
}

// MARK: - Memory pressure
//
// Level: kern.memorystatus_vm_pressure_level (1 normal, 2 warning, 4 critical), the same
// value the earlier mempressure.sh script read. Used %: (active + wired + compressed) / RAM,
// roughly what Activity Monitor calls "Memory Used". On a CI runner this read 30% while
// 100 - kern.memorystatus_level read only 9% (that one counts reclaimable cache as free),
// so the latter is only a fallback.

enum MemoryPressure {
    enum Level { case normal, warning, critical }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static var level: Level {
        switch sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    /// 0...100, or nil if neither source could be read.
    static var usedPercent: Int? {
        if let v = vmStatsUsedPercent { return v }
        if let free = sysctlInt("kern.memorystatus_level"), (0...100).contains(free) { return 100 - free }
        return nil
    }

    static var vmStatsUsedPercent: Int? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, let page = sysctlInt("hw.pagesize") else { return nil }
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(page)
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return Int(min(100, used * 100 / total))
    }

    static func report() -> String {
        "SELFTEST memory: pressure level sysctl=\(sysctlInt("kern.memorystatus_vm_pressure_level").map(String.init) ?? "unreadable")"
            + ", memorystatus_level (free %)=\(sysctlInt("kern.memorystatus_level").map(String.init) ?? "unreadable")"
            + ", vm_stats used %=\(vmStatsUsedPercent.map(String.init) ?? "unreadable")"
    }
}

/// A small ring: the arc fills with memory used, colored by macOS's pressure level.
final class MemoryRingView: NSView {
    var used: Int? { didSet { if used != oldValue { needsDisplay = true } } }
    var level: MemoryPressure.Level = .normal { didSet { if level != oldValue { needsDisplay = true } } }
    var onTap: (() -> Void)?

    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        tap.allowedTouchTypes = [.direct]
        addGestureRecognizer(tap)
        toolTip = "Memory pressure"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func tapped() { onTap?() }

    var color: NSColor {
        switch level {
        case .normal: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemRed
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let line: CGFloat = 3.5
        let r = bounds.insetBy(dx: line / 2 + 1, dy: line / 2 + 1)
        let c = NSPoint(x: r.midX, y: r.midY), radius = min(r.width, r.height) / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = line
        NSColor(white: 0.3, alpha: 1).setStroke()
        track.stroke()

        if let used = used, used > 0 {
            let arc = NSBezierPath()
            // clockwise from 12 o'clock
            arc.appendArc(withCenter: c, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(used) / 100, clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        }

        let text = NSAttributedString(string: used.map { "\($0)" } ?? "?", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: bounds.height * 0.34, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let ts = text.size()
        text.draw(at: NSPoint(x: c.x - ts.width / 2, y: c.y - ts.height / 2))
    }
}

// MARK: - App

extension NSTouchBarItem.Identifier {
    static let bar   = NSTouchBarItem.Identifier("local.pomodoro.bar")
    static let task  = NSTouchBarItem.Identifier("local.pomodoro.task")
    static let reset = NSTouchBarItem.Identifier("local.pomodoro.reset")
    static let skip  = NSTouchBarItem.Identifier("local.pomodoro.skip")
    static let tray  = NSTouchBarItem.Identifier("local.pomodoro.tray")
    static let memory = NSTouchBarItem.Identifier("local.pomodoro.memory")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSTextFieldDelegate {
    let pomodoro = Pomodoro()
    var window: NSWindow!
    var taskField: NSTextField!
    var windowButton: NSButton!
    var statusItem: NSStatusItem!
    var stripMenuItem: NSMenuItem!

    var bars: [ProgressBarView] = []
    var rings: [MemoryRingView] = []
    var memoryTimer: Timer?       // every progress bar on screen (Touch Bars + window)
    var modalBar: NSTouchBar?
    var trayItem: NSCustomTouchBarItem?
    var trayButton: NSButton?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMainMenu()
        buildWindow()
        buildStatusItem()

        pomodoro.onChange = { [weak self] in self?.refresh() }
        pomodoro.onPhaseEnd = { [weak self] ended in self?.phaseEnded(ended) }

        // On by default: the 🍅 Control Strip button is the only way to see the bar while
        // another app is in front. Turn off from the menu bar if it misbehaves.
        defaults.register(defaults: ["controlStrip": true])
        if defaults.bool(forKey: "controlStrip") { setControlStrip(true, quiet: true) }
        refresh()

        let mt = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshMemory() }
        RunLoop.main.add(mt, forMode: .common)
        memoryTimer = mt

        // Whenever the window stops being the one in front (minimized, hidden, or you switch
        // apps), put the timer on the Touch Bar system-wide so it stays visible.
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keepOnTouchBar()
        }
        nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.keepOnTouchBar()
        }

        NSApp.activate(ignoringOtherApps: true)
        // Don't start with the cursor in the task box: while a text field is being edited,
        // macOS shows typing suggestions on the Touch Bar instead of the app's own items.
        if CurrentTask.text.isEmpty { window.makeFirstResponder(taskField) } else { window.makeFirstResponder(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow(); return true
    }

    func applicationWillTerminate(_ note: Notification) {
        if let item = trayItem { PrivateTouchBar.removeFromControlStrip(item) }
    }

    // MARK: Touch Bar: [ ✎ ] [ ███████ task ........ 12:34 ] [ ↺ ] [ ⏭ ]

    func makeTimerTouchBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.task, .bar, .memory, .reset, .skip]
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        switch id {
        case .bar:
            let v = ProgressBarView(fontSize: 14)
            v.onTap = { [weak self] in self?.pomodoro.toggle() }
            v.widthAnchor.constraint(equalToConstant: 430).isActive = true
            v.heightAnchor.constraint(equalToConstant: 30).isActive = true
            bars.append(v)
            item.view = v
            refresh()
        case .task:
            item.view = NSButton(title: "✎", target: self, action: #selector(editTask))
        case .reset:
            item.view = NSButton(title: "↺", target: self, action: #selector(reset))
        case .memory:
            let ring = MemoryRingView(size: 30)
            ring.onTap = { Self.openActivityMonitor() }
            rings.append(ring)
            item.view = ring
            refreshMemory()
        case .skip:
            item.view = NSButton(title: "⏭", target: self, action: #selector(skip))
        default:
            return nil
        }
        return item
    }

    // MARK: Control Strip (experimental)

    func setControlStrip(_ on: Bool, quiet: Bool = false) {
        if on {
            guard PrivateTouchBar.isAvailable else {
                defaults.set(false, forKey: "controlStrip")
                stripMenuItem.state = .off
                if quiet { return }
                let a = NSAlert()
                a.messageText = "Control Strip button isn't available"
                a.informativeText = "This macOS version doesn't expose the private Touch Bar calls this feature relies on. The timer still works in the app and the menu bar."
                a.runModal()
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

    /// Shows the timer on the Touch Bar over whatever app is in front (private API).
    @objc func showModalBar() {
        guard PrivateTouchBar.isAvailable else { showWindow(); return }
        if trayItem == nil || !defaults.bool(forKey: "controlStrip") { setControlStrip(true, quiet: true) }
        if modalBar == nil { modalBar = makeTimerTouchBar() }
        PrivateTouchBar.presentModal(modalBar!, trayIdentifier: .tray)
    }

    func keepOnTouchBar() {
        guard defaults.bool(forKey: "controlStrip"), defaults.object(forKey: "keepOnTouchBar") == nil || defaults.bool(forKey: "keepOnTouchBar") else { return }
        showModalBar()
    }

    static func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    func refreshMemory() {
        let used = MemoryPressure.usedPercent, level = MemoryPressure.level
        for r in rings { r.used = used; r.level = level }
    }

    @objc func toggleControlStrip() { setControlStrip(stripMenuItem.state != .on) }

    // MARK: Actions

    @objc func toggle() {
        window.makeFirstResponder(nil)   // Return in the task box starts the timer and leaves the box
        pomodoro.toggle()
        // Starting from the menu bar: put the bar on the Touch Bar even if another app is in front.
        if pomodoro.running && !NSApp.isActive && defaults.bool(forKey: "controlStrip") { showModalBar() }
    }
    @objc func reset()  { pomodoro.reset() }
    @objc func skip()   { pomodoro.skip() }

    /// The Touch Bar has no keyboard, so editing the task brings up the window with the field focused.
    @objc func editTask() {
        showWindow()
        window.makeFirstResponder(taskField)
        taskField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ note: Notification) {
        CurrentTask.text = taskField.stringValue
        refresh()
    }

    func controlTextDidEndEditing(_ note: Notification) {
        CurrentTask.text = taskField.stringValue
        refresh()
        // Leave the text box so the Touch Bar switches back from typing suggestions to the timer.
        DispatchQueue.main.async { self.window.makeFirstResponder(nil) }
    }

    func phaseEnded(_ ended: Phase) {
        NSSound(named: NSSound.Name("Glass"))?.play()
        NSApp.requestUserAttention(.informationalRequest)
        if trayItem != nil && defaults.bool(forKey: "controlStrip") { showModalBar() }
    }

    var barTitle: String {
        let task = CurrentTask.text
        switch pomodoro.phase {
        case .work:
            return task.isEmpty ? "🍅 No task yet. Tap ✎ to write one" : "🍅 " + task
        case .shortBreak, .longBreak:
            return "☕️ \(pomodoro.phase.name)" + (task.isEmpty ? "" : " · next: \(task)")
        }
    }

    func refresh() {
        let color: NSColor = pomodoro.phase == .work ? .systemRed : .systemGreen
        for v in bars {
            v.progress = pomodoro.progress
            v.title = barTitle
            v.timeText = pomodoro.timeText
            v.fillColor = color
            v.paused = !pomodoro.running
        }
        trayButton?.title = pomodoro.running ? "🍅 " + pomodoro.timeText : "🍅"

        var short = CurrentTask.text
        if short.count > 20 { short = String(short.prefix(19)) + "…" }
        statusItem?.button?.title = pomodoro.display + (short.isEmpty ? "" : " · " + short)

        windowButton?.title = pomodoro.running ? "Pause" : "Start"
        window?.title = "Pomodoro · \(pomodoro.phase.name) · \(pomodoro.completedWork) done"
    }

    // MARK: UI scaffolding

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 170),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()

        taskField = NSTextField(string: CurrentTask.text)
        taskField.placeholderString = "What are you working on?"
        taskField.font = NSFont.systemFont(ofSize: 15)
        taskField.delegate = self

        let bar = ProgressBarView(fontSize: 16)
        bar.onTap = { [weak self] in self?.pomodoro.toggle() }
        bar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        bars.append(bar)

        windowButton = NSButton(title: "Start", target: self, action: #selector(toggle))
        windowButton.keyEquivalent = "\r"
        let resetButton = NSButton(title: "Reset", target: self, action: #selector(reset))
        let skipButton = NSButton(title: "Skip", target: self, action: #selector(skip))
        let buttons = NSStackView(views: [windowButton, resetButton, skipButton])

        let stack = NSStackView(views: [taskField, bar, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        taskField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        window.contentView = stack

        window.touchBar = makeTimerTouchBar()   // public API: shown while this app is frontmost
        window.makeKeyAndOrderFront(nil)
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let menu = NSMenu()
        menu.addItem(withTitle: "Start / Pause", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show on Touch Bar", action: #selector(showModalBar), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Set Task…", action: #selector(editTask), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset", action: #selector(reset), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Skip", action: #selector(skip), keyEquivalent: "").target = self
        menu.addItem(.separator())
        stripMenuItem = menu.addItem(withTitle: "🍅 Button in Control Strip",
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
        // Edit menu so ⌘C / ⌘V / ⌘A work in the task field
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

// `Pomodoro --selftest` prints which private Touch Bar calls exist on this Mac and exits.
if CommandLine.arguments.contains("--selftest") {
    print(PrivateTouchBar.report())
    print(MemoryPressure.report())
    exit(0)
}

// `Pomodoro --render-preview out.png` draws a sample Touch Bar strip to a PNG and exits (used by CI).
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let samples: [(String, Double, String, NSColor, Bool)] = [
        ("🍅 Write the quarterly report", 0.42, "14:30", .systemRed, false),
        ("🍅 Write the quarterly report", 0.42, "14:30", .systemRed, true),
        ("☕️ Short break · next: Write the quarterly report", 0.7, "01:30", .systemGreen, false),
    ]
    let row: CGFloat = 30, gap: CGFloat = 10, width: CGFloat = 430
    let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width + row + 3 * gap,
                                      height: CGFloat(samples.count) * (row + gap) + gap))
    canvas.wantsLayer = true
    canvas.layer?.backgroundColor = NSColor.black.cgColor
    for (n, s) in samples.enumerated() {
        let v = ProgressBarView(fontSize: 14)
        v.translatesAutoresizingMaskIntoConstraints = true
        v.frame = NSRect(x: gap, y: canvas.bounds.height - CGFloat(n + 1) * (row + gap), width: width, height: row)
        v.title = s.0; v.progress = s.1; v.timeText = s.2; v.fillColor = s.3; v.paused = s.4
        canvas.addSubview(v)
        let ring = MemoryRingView(size: row)
        ring.translatesAutoresizingMaskIntoConstraints = true
        ring.frame = NSRect(x: gap * 2 + width, y: v.frame.minY, width: row, height: row)
        ring.used = [41, 68, 92][n]
        ring.level = [.normal, .warning, .critical][n]
        canvas.addSubview(ring)
    }
    let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
    rep.size = canvas.bounds.size
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
