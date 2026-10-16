import SwiftUI

extension Notification.Name {
    static let newSymbol = Notification.Name("NSEObs.newSymbol")
    static let newObservation = Notification.Name("NSEObs.newObservation")
}

@main
struct NSEObservationsApp: App {
    @StateObject private var store = Store()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        Window("NSE Observations", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Observation…") {
                    NotificationCenter.default.post(name: .newObservation, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Add Symbol…") {
                    NotificationCenter.default.post(name: .newSymbol, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Backup…") { store.exportJSON() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Backup…") { store.importJSON() }
                Divider()
                Button("Show Data File in Finder") { store.revealDataFile() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}
