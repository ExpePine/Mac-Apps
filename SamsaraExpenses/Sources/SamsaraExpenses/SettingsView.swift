import SwiftUI
import AppKit
import SamsaraCore

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.pageURL) private var pageURL = Store.defaultPageURL
    @AppStorage(SettingsKey.autoSync) private var autoSync = true
    @AppStorage(SettingsKey.intervalMinutes) private var intervalMinutes = 60
    @AppStorage(SettingsKey.syncOnLaunch) private var syncOnLaunch = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @State private var confirmClear = false

    private let intervals: [(Int, String)] = [
        (15, "Every 15 minutes"), (30, "Every 30 minutes"), (60, "Every hour"),
        (180, "Every 3 hours"), (360, "Every 6 hours"), (720, "Every 12 hours"), (1440, "Once a day"),
    ]

    var body: some View {
        Form {
            Section("Samsara page") {
                TextField("Page URL", text: $pageURL)
                    .textFieldStyle(.roundedBorder)
                Text("The app opens this page invisibly, presses its 📥 “Download table as CSV” button and reads the file.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Sign in to Samsara…") { openWindow(id: "signin") }
                    Button("Reset URL") { pageURL = Store.defaultPageURL }
                        .disabled(pageURL == Store.defaultPageURL)
                }
            }

            Section("Automatic download") {
                Toggle("Download automatically", isOn: $autoSync)
                Picker("How often", selection: $intervalMinutes) {
                    ForEach(intervals, id: \.0) { Text($0.1).tag($0.0) }
                }
                .disabled(!autoSync)
                Toggle("Download when the app opens", isOn: $syncOnLaunch)
                    .disabled(!autoSync)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            try LaunchAtLogin.set(on)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text("Auto-download runs while the app is open (closing the window keeps it running; quit with ⌘Q).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Sync now") { Task { await store.sync() } }
                        .disabled(store.status == .syncing)
                    Text(store.status.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Section("Data") {
                LabeledContent("Entries", value: "\(store.expenses.count)")
                if let last = store.lastSync {
                    LabeledContent("Last update", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                HStack {
                    Button("Show data folder") {
                        try? FileManager.default.createDirectory(at: Store.dataDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Store.dataDirectory)
                    }
                    Button("Import CSV…") { store.importWithPanel() }
                    Button("Clear data…", role: .destructive) { confirmClear = true }
                }
                Text("The latest CSV is kept as latest.csv, plus one copy per day in the archive folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
        .confirmationDialog("Remove the downloaded expenses from this Mac?", isPresented: $confirmClear) {
            Button("Clear data", role: .destructive) { store.clearData() }
        } message: {
            Text("Daily archive copies are kept. Your data on the Samsara site is not touched.")
        }
    }
}
