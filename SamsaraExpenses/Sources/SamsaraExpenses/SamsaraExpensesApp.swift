import SwiftUI
import AppKit
import SamsaraCore

@main
struct SamsaraExpensesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Samsara Expenses", id: "main") {
            RootView()
                .environmentObject(appDelegate.store)
                .frame(minWidth: 1050, minHeight: 680)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import CSV…") { appDelegate.store.importWithPanel() }
                    .keyboardShortcut("o")
                Button("Export Period as CSV…") {
                    let s = appDelegate.store
                    s.exportWithPanel(s.current, name: "samsara-\(s.period.tag.replacingOccurrences(of: ":", with: "-")).csv")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Sync") {
                Button("Sync Now") { Task { await appDelegate.store.sync() } }
                    .keyboardShortcut("r")
                SignInMenuItem()
            }
        }

        Window("Sign in to Samsara", id: "signin") {
            SignInView().environmentObject(appDelegate.store)
        }
        .defaultSize(width: 1000, height: 720)

        Settings {
            SettingsView().environmentObject(appDelegate.store)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(appDelegate.store)
        } label: {
            MenuBarLabel().environmentObject(appDelegate.store)
        }
    }
}

private struct SignInMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Sign in to Samsara…") { openWindow(id: "signin") }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let month = store.analyzer.filter(store.expenses, in: store.analyzer.interval(for: store.analyzer.period(containing: Date())))
        if store.expenses.isEmpty {
            Image(systemName: "indianrupeesign.circle")
        } else {
            Text("₹ " + Money.compact(Analyzer.total(month)).replacingOccurrences(of: "₹", with: ""))
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let a = store.analyzer
        let thisMonth = a.period(containing: Date())
        let month = a.filter(store.expenses, in: a.interval(for: thisMonth))
        let today = a.filter(store.expenses, in: a.interval(for: .lastDays(1)))
        Text("\(thisMonth.label): \(Money.format(Analyzer.total(month))) (\(month.count) items)")
        Text("Today: \(Money.format(Analyzer.total(today))) (\(today.count) items)")
        Divider()
        Text(store.status.message)
        Button("Sync Now") { Task { await store.sync() } }
            .disabled(store.status == .syncing)
        Button("Open Samsara Expenses") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--screenshots") {
            Screenshots.capture()
            exit(0)
        }
        if args.contains("--probe-fetch") {
            Task {
                await Probe.run(url: URL(string: Store.defaultPageURL)!)
                exit(0)
            }
            return
        }
        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keep auto-downloading in the background; the menu bar item stays available
    }
}
