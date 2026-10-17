import SwiftUI

@main
struct StockScreenerApp: App {
    @StateObject private var vm = ScreenerViewModel()

    var body: some Scene {
        WindowGroup("Data", id: "data") {
            ContentView()
                .environmentObject(vm)
                .frame(minWidth: 960, minHeight: 560)
        }

        Window("Active Filter", id: "active-filter") {
            ActiveFilterView()
                .environmentObject(vm)
                .frame(minWidth: 900, minHeight: 520)
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])

        Window("Alerts & Email", id: "alerts") {
            AlertsView()
                .environmentObject(vm)
                .frame(minWidth: 640, minHeight: 560)
        }
        .keyboardShortcut("2", modifiers: [.command, .shift])
    }
}
