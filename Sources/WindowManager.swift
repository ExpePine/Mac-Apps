import AppKit
import SwiftUI

/// Owns the floating check-in window, the main window and the deviation panel.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private var promptWindow: NSWindow?
    private var mainWindow: NSWindow?
    private var deviationWindow: NSWindow?
    private var deviationModel: DeviationModel?
    private var gateWindow: NSWindow?
    private var replayWindow: NSWindow?

    var isBusy: Bool { promptWindow != nil || gateWindow != nil || deviationWindow != nil || replayWindow != nil }

    /// Called when the user closes the check-in window with the red ✕.
    var onPromptClosedByUser: (@MainActor () -> Void)?

    // MARK: Check-in window

    func showPrompt(_ session: PromptSession) {
        closePrompt()
        let host = NSHostingController(rootView: PromptView(session: session))
        let window = NSWindow(contentViewController: host)
        window.title = "Check-in"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        placeTopRight(window)
        promptWindow = window
        bringToFront(window)
    }

    func bringPromptToFront() {
        if let promptWindow { bringToFront(promptWindow) }
    }

    func closePrompt() {
        let window = promptWindow
        promptWindow = nil      // so windowWillClose doesn't treat it as a user close
        window?.close()
    }

    // MARK: Main window (sidebar: Today, Goals, Insights, Stuck, History, Settings)

    func showMain(app: AppDelegate, nav: Navigator) {
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainWindowView(app: app, nav: nav))
            let window = NSWindow(contentViewController: host)
            window.title = "Activity Logger"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1000, height: 700))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("ActivityLoggerMain")
            if !window.setFrameUsingName("ActivityLoggerMain") { window.center() }
            mainWindow = window
        }
        // Show in the Dock and ⌘-Tab while the main window is open.
        NSApp.setActivationPolicy(.regular)
        if let mainWindow { bringToFront(mainWindow) }
    }

    // MARK: Deviation panel

    func showDeviation(_ model: DeviationModel) {
        deviationWindow?.close()
        model.onClose = { [weak self] in self?.closeDeviation() }
        let host = NSHostingController(rootView: DeviationView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Check-in review"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        deviationWindow = window
        deviationModel = model
        bringToFront(window)
    }

    private func closeDeviation() {
        let window = deviationWindow
        deviationWindow = nil
        deviationModel = nil
        window?.close()
    }

    // MARK: Goals gate (no close button: plan, snooze or take the day off)

    func showGate<V: View>(_ view: V) {
        if let gateWindow {
            bringToFront(gateWindow)
            return
        }
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Plan your day"
        window.styleMask = [.titled]
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.center()
        gateWindow = window
        bringToFront(window)
    }

    func closeGate() {
        gateWindow?.close()
        gateWindow = nil
    }

    // MARK: 4-hour replay

    func showReplay(_ story: DayStory) {
        closeReplay()
        let view = DayStoryView(story: story, onClose: { [weak self] in self?.closeReplay() })
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Your last 4 hours"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        replayWindow = window
        // Don't steal focus from what the user is typing: show it without activating.
        window.orderFrontRegardless()
    }

    func closeReplay() {
        let window = replayWindow
        replayWindow = nil
        window?.close()
    }

    // MARK: Helpers

    /// Top-right corner, just under the menu bar, so the check-in doesn't cover the middle of the screen.
    private func placeTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { window.center(); return }
        let vf = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 8))
    }

    private func bringToFront(_ window: NSWindow) {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === promptWindow {
            promptWindow = nil
            onPromptClosedByUser?()
        } else if window === mainWindow {
            mainWindow = nil
            NSApp.setActivationPolicy(.accessory)   // back to menu-bar only
        } else if window === replayWindow {
            replayWindow = nil
        } else if window === deviationWindow {
            deviationWindow = nil
            deviationModel = nil
        }
    }
}
