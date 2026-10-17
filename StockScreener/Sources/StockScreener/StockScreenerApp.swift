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

        Window("Alerts & Email", id: "alerts") {
            AlertsView()
                .environmentObject(vm)
                .frame(minWidth: 680, minHeight: 600)
        }
        .keyboardShortcut("2", modifiers: [.command, .shift])
    }
}
