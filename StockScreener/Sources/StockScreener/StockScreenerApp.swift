import SwiftUI

@main
struct StockScreenerApp: App {
    @StateObject private var vm = ScreenerViewModel()

    var body: some Scene {
        WindowGroup("Stock Screener") {
            ContentView()
                .environmentObject(vm)
                .frame(minWidth: 960, minHeight: 560)
        }
    }
}
