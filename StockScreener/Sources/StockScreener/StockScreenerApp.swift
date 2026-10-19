import SwiftUI

@main
struct StockScreenerApp: App {
    @StateObject private var vm = ScreenerViewModel()

    var body: some Scene {
        WindowGroup("Data Import", id: "data") {
            ImportView()
                .environmentObject(vm)
                .frame(minWidth: 900, minHeight: 520)
        }

        Window("Filter", id: "filter") {
            FilterView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 560)
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])

        Window("Alerts", id: "alertlog") {
            AlertsBrowserView()
                .environmentObject(vm)
                .frame(minWidth: 820, minHeight: 480)
        }
        .keyboardShortcut("3", modifiers: [.command, .shift])

        Window("Email & Rules", id: "alerts") {
            AlertsView()
                .environmentObject(vm)
                .frame(minWidth: 680, minHeight: 600)
        }
        .keyboardShortcut("2", modifiers: [.command, .shift])

        Window("Neural Net", id: "nn") {
            NeuralNetView()
                .environmentObject(vm)
                .frame(minWidth: 980, minHeight: 600)
        }
        .keyboardShortcut("4", modifiers: [.command, .shift])

        Window("Watchlists", id: "watch") {
            WatchlistView()
                .environmentObject(vm)
                .frame(minWidth: 980, minHeight: 520)
        }
        .keyboardShortcut("5", modifiers: [.command, .shift])

        Window("Screenshots", id: "shots") {
            ScreenshotsView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .keyboardShortcut("6", modifiers: [.command, .shift])

        Window("Notes & Scripts", id: "notes") {
            NotesView()
                .frame(minWidth: 860, minHeight: 520)
        }
        .keyboardShortcut("7", modifiers: [.command, .shift])

        Window("Changes", id: "changes") {
            ChangesView()
                .environmentObject(vm)
                .frame(minWidth: 760, minHeight: 520)
        }
        .keyboardShortcut("8", modifiers: [.command, .shift])

        Window("Performance", id: "perf") {
            PerformanceView()
                .environmentObject(vm)
                .frame(minWidth: 1050, minHeight: 640)
        }
        .keyboardShortcut("9", modifiers: [.command, .shift])

        Window("Sectors", id: "sectors") {
            SectorsView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .keyboardShortcut("0", modifiers: [.command, .shift])
        .commands { ToolsCommands() }
    }
}


/// "Tools" menu: every window, with its shortcut.
struct ToolsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Tools") {
            Text("Shortcuts ⇧⌘1 … ⇧⌘0 are in the Window menu")
            Divider()
            Button("Data Import") { openWindow(id: "data") }
            Button("Filter") { openWindow(id: "filter") }
            Button("Changes (cards)") { openWindow(id: "changes") }
            Button("Performance") { openWindow(id: "perf") }
            Button("Sectors & regime alerts") { openWindow(id: "sectors") }
            Button("Email & Rules") { openWindow(id: "alerts") }
            Button("Alerts") { openWindow(id: "alertlog") }
            Button("Neural Net") { openWindow(id: "nn") }
            Divider()
            Button("Watchlists") { openWindow(id: "watch") }
            Button("Screenshots") { openWindow(id: "shots") }
            Button("MV2 Requirements & Pine Scripts") { openWindow(id: "notes") }
        }
    }
}
