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
    }
}
