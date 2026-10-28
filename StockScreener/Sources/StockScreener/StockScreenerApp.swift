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

        Window("Daily Gainers", id: "gainers") {
            GainersView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])

        Window("Chart", id: "chart") {
            ChartViewer()
                .environmentObject(vm)
                .frame(minWidth: 900, minHeight: 600)
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])

        Window("My Picks", id: "picks") {
            MyPicksView()
                .environmentObject(vm)
                .frame(minWidth: 980, minHeight: 520)
        }
        .keyboardShortcut("p", modifiers: [.command, .option])

        Window("Combinatorix", id: "combi") {
            CombinatorixView()
                .environmentObject(vm)
                .frame(minWidth: 1100, minHeight: 640)
        }
        .keyboardShortcut("x", modifiers: [.command, .option])

        Window("Chart Reel", id: "reel") {
            ChartReelView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .keyboardShortcut("r", modifiers: [.command, .option])

        Window("Data Lab", id: "datalab") {
            DataLabView()
                .environmentObject(vm)
                .frame(minWidth: 1050, minHeight: 620)
        }
        .keyboardShortcut("b", modifiers: [.command, .option])

        Window("Data Storage", id: "storage") {
            StorageView()
                .frame(minWidth: 760, minHeight: 480)
        }

        Window("F Notes", id: "mbnotes") {
            MBNotesWindow()
                .environmentObject(vm)
                .frame(minWidth: 920, minHeight: 560)
        }
        .keyboardShortcut("n", modifiers: [.command, .option, .shift])

        Window("F Combinations", id: "mbcombos") {
            MBCombosWindow()
                .environmentObject(vm)
                .frame(minWidth: 920, minHeight: 560)
        }
        .keyboardShortcut("f", modifiers: [.command, .option])

        Window("Settings", id: "hub") {
            SettingsHubView()
                .environmentObject(vm)
                .frame(minWidth: 640, minHeight: 520)
        }
        .keyboardShortcut(",", modifiers: [.command, .option])

        Window("Alert Tracker", id: "tracker") {
            TrackerView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 520)
        }
        .keyboardShortcut("j", modifiers: [.command, .option])

        Window("Event Scan", id: "eventscan") {
            EventScanView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .keyboardShortcut("l", modifiers: [.command, .option])

        Window("Timing Lab", id: "timinglab") {
            TimingLabView()
                .environmentObject(vm)
                .frame(minWidth: 1100, minHeight: 640)
        }
        .keyboardShortcut("t", modifiers: [.command, .option])

        Window("News & Deals", id: "newschart") {
            NewsChartView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .keyboardShortcut("n", modifiers: [.command, .option])

        Window("AUTO-PREDICT", id: "autopredict") {
            AutoPredictView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .keyboardShortcut("a", modifiers: [.command, .option])

        Window("Gainer Charts", id: "gainerCharts") {
            GainerChartsView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 700)
        }
        .keyboardShortcut("g", modifiers: [.command, .option])

        Window("Delivery Analysis", id: "delivery") {
            DeliveryView()
                .environmentObject(vm)
                .frame(minWidth: 1100, minHeight: 640)
        }
        .keyboardShortcut("d", modifiers: [.command, .option])

        Window("Multibaggers", id: "multibaggers") {
            MultibaggerView()
                .environmentObject(vm)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .keyboardShortcut("m", modifiers: [.command, .option])

        Window("Experiments", id: "experiments") {
            ExperimentsView()
                .environmentObject(vm)
                .frame(minWidth: 1050, minHeight: 650)
        }
        .keyboardShortcut("e", modifiers: [.command, .option])

        Window("Symbols", id: "symbols") {
            SymbolsView()
                .environmentObject(vm)
                .frame(minWidth: 980, minHeight: 520)
        }
        .keyboardShortcut("y", modifiers: [.command, .option])
        .commands { ToolsCommands() }
    }
}


/// "Tools" menu: every window, with its shortcut.
struct ToolsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Settings…") { openWindow(id: "hub") }
            Button("Data Storage — what the app stores and how big it is") { openWindow(id: "storage") }
            Button("Update 5-minute data now (Yahoo, for MOR / DAY)") { Intraday5mCenter.shared.update(Intraday5mCenter.allSheetSymbols, force: true) }
            ForEach(AppWindows.groups) { g in
                Divider()
                Section(g.name) {
                    ForEach(g.windows) { w in
                        Button(w.note.isEmpty ? w.title : "\(w.title) — \(w.note)") { openWindow(id: w.id) }
                    }
                }
            }
        }
    }
}
