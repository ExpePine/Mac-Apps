import AppKit
import SwiftUI

/// Owns the floating check-in window and the History window.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private var promptWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var emailWindow: NSWindow?

    /// Called when the user closes the check-in window with the red ✕.
    var onPromptClosedByUser: (@MainActor () -> Void)?

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

    func showHistory(store: EntryStore, settings: SettingsStore) {
        if let historyWindow {
            bringToFront(historyWindow)
            return
        }
        let host = NSHostingController(rootView: HistoryView(store: store, settings: settings))
        let window = NSWindow(contentViewController: host)
        window.title = "Activity History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 620))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        historyWindow = window
        bringToFront(window)
    }

    func showEmailSettings(settings: SettingsStore, reports: ReportService) {
        if let emailWindow {
            bringToFront(emailWindow)
            return
        }
        let host = NSHostingController(rootView: EmailSettingsView(settings: settings, reports: reports))
        let window = NSWindow(contentViewController: host)
        window.title = "Daily Summary Email"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        emailWindow = window
        bringToFront(window)
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
        } else if window === historyWindow {
            historyWindow = nil
        } else if window === emailWindow {
            emailWindow = nil
        }
    }
}
