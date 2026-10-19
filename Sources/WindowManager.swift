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
        window.center()
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

    // MARK: Helpers

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
        } else if window === deviationWindow {
            deviationWindow = nil
            deviationModel = nil
        }
    }
}
