import AppKit
import SwiftUI
import WebKit
import Darwin

/// Keeping memory low the way macOS apps are expected to:
///  • "Free memory" (Data Storage) drops caches the app can rebuild on demand;
///  • the same happens by itself when macOS reports memory pressure (DispatchSource memory-pressure events),
///    and after the app has been in the background for 3 minutes (only the lighter caches);
///  • a live readout of what the app holds, so it's visible rather than guessed.
@MainActor enum MemoryRelief {

    private static var pressure: DispatchSourceMemoryPressure?
    private static var backgroundWork: DispatchWorkItem?
    static var lastRun: (Date, Double, Double)?        // when, MB before, MB after

    static func run(_ vm: ScreenerViewModel, deep: Bool = true) {
        let before = footprintMB()
        vm.clearTimelineCache()
        NotificationCenter.default.post(name: ReelPool.freeMemory, object: nil)
        if deep {
            let mbOpen = NSApp.windows.contains { $0.isVisible && ($0.title.hasPrefix("Multibaggers") || $0.title.hasPrefix("F ")) }
            if !mbOpen { MultibaggerCenter.shared.unload() }
        }
        URLCache.shared.removeAllCachedResponses()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { lastRun = (Date(), before, footprintMB()) }
    }

    /// Call once at launch.
    static func install(_ vm: ScreenerViewModel) {
        guard pressure == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak vm] in Task { @MainActor in if let vm { run(vm, deep: true) } } }
        src.resume()
        pressure = src
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak vm] _ in
            Task { @MainActor in
                backgroundWork?.cancel()
                let w = DispatchWorkItem { [weak vm] in
                    Task { @MainActor in if let vm, !NSApp.isActive { run(vm, deep: false) } }
                }
                backgroundWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: w)
            }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in backgroundWork?.cancel() }
        }
    }

    /// The app's own memory as Activity Monitor's "Memory" column counts it (physical footprint), MB.
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// Live memory readout (Data Storage window).
struct MemoryPanel: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var dc = DeliveryCenter.shared
    @ObservedObject private var mb = MultibaggerCenter.shared
    @State private var mbNow = MemoryRelief.footprintMB()
    @State private var tick = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private func points(_ b: PriceBook) -> Int { b.series.values.reduce(0) { $0 + $1.closes.count } }

    var body: some View {
        let _ = tick
        let pricePts = points(vm.priceBook), mbPts = points(mb.book)
        let delPts = dc.book.series.values.reduce(0) { $0 + $1.qty.count }
        // rough sizes: a price day ≈ 5 numbers + a date ≈ 56 B; a delivery day ≈ 3 numbers + a date ≈ 40 B
        let priceMB = Double(pricePts) * 56 / 1_048_576, mbMB = Double(mbPts) * 56 / 1_048_576, delMB = Double(delPts) * 40 / 1_048_576
        let cells = vm.table.rows.count * max(1, vm.table.headers.count)
        let tableMB = Double(cells) * 26 / 1_048_576
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Memory now").font(.headline)
                Text(String(format: "%.0f MB", mbNow)).font(.title3.bold().monospacedDigit())
                Spacer()
                Button("Free memory") { MemoryRelief.run(vm) }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                row("Yahoo prices (2 years)", "\(vm.priceBook.series.count) stocks · \(pricePts.formatted()) days", priceMB)
                row("NSE delivery history", "\(dc.book.series.count) stocks · \(dc.storedDays.count) days", delMB)
                row("5-year multibagger prices", mb.book.series.isEmpty ? "not loaded" : "\(mb.book.series.count) stocks · \(mbPts.formatted()) days", mbMB)
                row("The sheet (today)", "\(vm.table.rows.count) rows × \(vm.table.headers.count) columns", tableMB * 2)
                row("Past days kept for the timeline", "\(vm.timelineCache.count) of 3", tableMB * Double(vm.timelineCache.count))
                row("Web pages open (TradingView, charts)", "\(PageCounter.pages.allObjects.count) — each also runs as its own “Web Content” process in Activity Monitor", nil)
            }
            .font(.caption)
            if let r = MemoryRelief.lastRun {
                Text(String(format: "Last freed %@: %.0f → %.0f MB", r.0.formatted(date: .omitted, time: .shortened), r.1, r.2)).font(.caption2).foregroundStyle(.secondary)
            }
            Text("Sizes are estimates. macOS also frees caches by itself when memory runs short (the app listens for that), and after 3 minutes in the background.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .padding(.horizontal, 12)
        .onReceive(timer) { _ in mbNow = MemoryRelief.footprintMB(); tick &+= 1 }
    }

    @ViewBuilder private func row(_ name: String, _ what: String, _ mb: Double?) -> some View {
        GridRow {
            Text(name).fontWeight(.medium)
            Text(what).foregroundStyle(.secondary)
            Text(mb.map { String(format: "~%.0f MB", $0) } ?? "").monospacedDigit()
        }
    }
}

/// Every web page the app has open (TradingView pages, delivery / news charts) — weakly held, for counting.
enum PageCounter {
    static let pages = NSHashTable<WKWebView>.weakObjects()
    static func track(_ v: WKWebView) { pages.add(v) }
}
