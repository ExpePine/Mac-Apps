import SwiftUI

@main
struct ActivityLoggerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                app: appDelegate,
                settings: appDelegate.settings,
                scheduler: appDelegate.scheduler,
                store: appDelegate.store
            )
        } label: {
            MenuBarLabel(scheduler: appDelegate.scheduler)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var scheduler: Scheduler

    var body: some View {
        Image(systemName: scheduler.isPaused ? "pause.circle" : "clock.badge.checkmark")
    }
}
