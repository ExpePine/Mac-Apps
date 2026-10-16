import AppKit
import SwiftUI

struct MenuContentView: View {
    let app: AppDelegate
    @ObservedObject var settings: SettingsStore
    @ObservedObject var scheduler: Scheduler
    @ObservedObject var store: EntryStore
    @ObservedObject var tracker: UsageTracker

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status
            HStack {
                Button {
                    app.logNow()
                } label: { Label("Log now", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderedProminent)
                Button {
                    scheduler.isPaused ? scheduler.resume() : scheduler.pause()
                } label: {
                    Label(scheduler.isPaused ? "Resume" : "Pause",
                          systemImage: scheduler.isPaused ? "play.fill" : "pause.fill")
                }
            }

            Divider()

            section("Check in every")
            Picker("", selection: $settings.intervalMinutes) {
                ForEach(SettingsStore.intervalPresets, id: \.self) { Text("\($0)m").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Stepper("Custom: \(settings.intervalMinutes) min",
                    value: $settings.intervalMinutes, in: 5...180, step: 5)

            section("Time to respond")
            Stepper("\(settings.entryWindowMinutes) min, then auto-save",
                    value: $settings.entryWindowMinutes, in: 1...10)

            Divider()

            Toggle("Open entry window automatically", isOn: $settings.autoOpenWindow)
            Toggle("Notification sound", isOn: $settings.playSound)
            Toggle("Speech-to-text after recording", isOn: $settings.autoTranscribe)
            Picker("Speech language", selection: $settings.speechLocaleID) {
                ForEach(SettingsStore.speechLocales, id: \.id) { Text($0.name).tag($0.id) }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    loginError = LoginItem.set(newValue)
                    launchAtLogin = LoginItem.isEnabled
                }
            ))
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }

            Divider()

            HStack {
                Image(systemName: "globe")
                Text(settings.trackUsage
                     ? "Active today: \(durationText(tracker.today.activeSeconds))"
                     : "Website & app tracking off")
                Spacer()
            }
            HStack {
                Image(systemName: "envelope")
                Text(settings.reportEnabled
                     ? "Daily email at \(String(format: "%02d:%02d", settings.reportHour, settings.reportMinute))"
                     : "Daily email off")
                Spacer()
                Button("Set up…") { app.showEmailSettings() }
            }

            Divider()

            HStack {
                Button("History…") { app.showHistory() }
                Button("Data folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 2) {
                if scheduler.isPaused {
                    Text("Paused").font(.headline)
                } else {
                    let secs = Int(scheduler.nextFire.timeIntervalSinceNow.rounded(.up))
                    Text("Next check-in in \(mmss(secs))")
                        .font(.headline)
                        .monospacedDigit()
                }
                Text("\(store.loggedTodayCount) entries logged today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}
