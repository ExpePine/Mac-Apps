import AppKit

/// "Free memory": drops caches the app can rebuild on demand.
@MainActor enum MemoryRelief {
    static func run(_ vm: ScreenerViewModel) {
        vm.clearTimelineCache()
        NotificationCenter.default.post(name: ReelPool.freeMemory, object: nil)
        let mbOpen = NSApp.windows.contains { $0.isVisible && ($0.title.hasPrefix("Multibaggers") || $0.title.hasPrefix("F ")) }
        if !mbOpen { MultibaggerCenter.shared.unload() }
        URLCache.shared.removeAllCachedResponses()
    }
}
