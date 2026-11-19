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
        giveBack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { lastRun = (Date(), before, footprintMB()) }
    }

    /// Hands memory the app has already freed back to macOS. Big background jobs (delivery columns, live prices,
    /// market totals) allocate and free hundreds of MB; malloc keeps those pages for reuse, and Activity Monitor
    /// counts them until they're returned.
    nonisolated static func giveBack() { _ = malloc_zone_pressure_relief(nil, 0) }

    /// The 5-year multibagger prices (~150 MB) are only needed by the Multibaggers / F windows, the Reel's
    /// Multibaggers source and "centre on the multibagger move" — drop them a couple of minutes after none is in use.
    static func unloadUnusedHistory() {
        let mb = MultibaggerCenter.shared
        guard !mb.book.series.isEmpty else { return }
        let titles = NSApp.windows.filter { $0.isVisible }.map(\.title)
        let mbWindow = titles.contains { $0.hasPrefix("Multibaggers") || $0.hasPrefix("F ") }
        let d = UserDefaults.standard
        let reelMB = titles.contains { $0.hasPrefix("Chart Reel") } && d.string(forKey: "reel.source") == ReelSource.multibaggers.rawValue
        let centreMB = ChartContext.allCases.contains { ChartCentre.kind($0) == .mb }
        if mbWindow || reelMB || centreMB { idleSince = nil; return }
        if let t = idleSince, Date().timeIntervalSince(t) > 120 { mb.unload(); idleSince = nil; giveBack() }
        else if idleSince == nil { idleSince = Date() }
    }
    private static var idleSince: Date?
    private static var timer: Timer?

    /// Call once at launch.
    /// How many TradingView pages may stay alive at once (each is its own ~200–400 MB "Web Content" process).
    /// Default: 4 on Macs with ≤ 8 GB RAM, 8 otherwise. Pages on screen are never closed.
    static var tvBudget: Int {
        let v = UserDefaults.standard.integer(forKey: "tv.maxPages")
        return v > 0 ? v : (ProcessInfo.processInfo.physicalMemory <= UInt64(9) << 30 ? 4 : 8)
    }

    /// TradingView pages' own memory (their "Web Content" processes, the in.tradingview.com row in Activity Monitor).
    /// TradingView's page grows the longer it stays open; a reload resets it.
    static var tvLimitMB: Double {
        let v = UserDefaults.standard.double(forKey: "tv.memLimitMB")
        return v > 0 ? v : (ProcessInfo.processInfo.physicalMemory <= UInt64(9) << 30 ? 1200 : 2500)
    }
    static var tvPages: [WKWebView] { PageCounter.pages.allObjects.filter { ($0.url?.host ?? "").contains("tradingview") } }

    /// Sum of the distinct web processes behind the TradingView pages (MB), and how many processes.
    static func tvMemory() -> (mb: Double, processes: Int) {
        var pids = Set<pid_t>()
        let sel = NSSelectorFromString("_webProcessIdentifier")
        for v in tvPages where v.responds(to: sel) {
            if let n = v.value(forKey: "_webProcessIdentifier") as? NSNumber, n.int32Value > 0 { pids.insert(n.int32Value) }
        }
        return (pids.reduce(0) { $0 + (processMB($1) ?? 0) }, pids.count)
    }

    nonisolated static func processMB(_ pid: pid_t) -> Double? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : nil
    }

    static var lastTVReload: Date?

    /// Over the TradingView memory limit: close pages that aren't on screen; if still over and you're not using the
    /// app (another app in front), reload the remaining TradingView pages — that resets their memory.
    static func guardTradingView(force: Bool = false) {
        guard force || tvMemory().mb > tvLimitMB else { return }
        NotificationCenter.default.post(name: ReelPool.freeMemory, object: nil)
        guard force || !NSApp.isActive else { return }
        if !force, let t = lastTVReload, Date().timeIntervalSince(t) < 600 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard force || tvMemory().mb > tvLimitMB else { return }
            tvPages.forEach { $0.reload() }
            lastTVReload = Date()
        }
    }

    static func install(_ vm: ScreenerViewModel) {
        guard pressure == nil else { return }
        URLCache.shared.memoryCapacity = 4 * 1_048_576            // web data is cached on disk; keep only a little in RAM
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                unloadUnusedHistory(); giveBack()
                // over the page budget → close pages that aren't on screen (preloaded / other accounts / old Reel pages)
                if PageCounter.pages.allObjects.count > tvBudget { NotificationCenter.default.post(name: ReelPool.freeMemory, object: nil) }
                guardTradingView()
            }
        }
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
        // rough sizes: a price day ≈ 5 numbers + a date ≈ 56 B; a delivery day ≈ 3 numbers + a date + 2 flags ≈ 42 B
        let priceMB = Double(pricePts) * 56 / 1_048_576, mbMB = Double(mbPts) * 56 / 1_048_576, delMB = Double(delPts) * 42 / 1_048_576
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
                row("NSE delivery history", "\(dc.book.series.count) stocks · \(dc.book.days.count) days in memory (\(dc.storedDays.count) on disk)", delMB)
                row("5-year multibagger prices", mb.book.series.isEmpty ? "not loaded" : "\(mb.book.series.count) stocks · \(mbPts.formatted()) days", mbMB)
                row("The sheet (today)", "\(vm.table.rows.count) rows × \(vm.table.headers.count) columns", tableMB * 2)
                row("Past days kept for the timeline", "\(vm.timelineCache.count) of 3", tableMB * Double(vm.timelineCache.count))
                row("Web pages open (TradingView, charts)", "\(PageCounter.pages.allObjects.count) — each also runs as its own “Web Content” process in Activity Monitor (the in.tradingview.com row)", nil)
            }
            let tv = MemoryRelief.tvMemory()
            HStack(spacing: 6) {
                Text(String(format: "TradingView pages: %.0f MB", tv.mb)).font(.caption.bold().monospacedDigit())
                    .foregroundStyle(tv.mb > MemoryRelief.tvLimitMB ? Color.orange : Color.primary)
                Text("(\(MemoryRelief.tvPages.count) pages, \(tv.processes) processes) · limit").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { MemoryRelief.tvLimitMB }, set: { UserDefaults.standard.set($0, forKey: "tv.memLimitMB"); tick &+= 1 })) {
                    ForEach([800.0, 1000, 1200, 1500, 2000, 2500, 4000], id: \.self) { Text(String(format: "%.1f GB", $0 / 1024)).tag($0) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
                Button("Reload them now") { MemoryRelief.guardTradingView(force: true) }.controlSize(.small)
                    .help("TradingView's page keeps growing while it's open; reloading resets it (the charts redraw in a few seconds)")
            }
            Text("Over the limit: pages off screen are closed at once; the rest are reloaded when you switch to another app (at most every 10 min).")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Keep at most").font(.caption)
                Picker("", selection: Binding(get: { MemoryRelief.tvBudget }, set: { UserDefaults.standard.set($0, forKey: "tv.maxPages"); tick &+= 1
                    if PageCounter.pages.allObjects.count > $0 { NotificationCenter.default.post(name: ReelPool.freeMemory, object: nil) } })) {
                    ForEach([2, 3, 4, 6, 8, 12], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
                Text("TradingView pages alive (on-screen pages are always kept). Fewer = less RAM, a little more reloading.")
                    .font(.caption2).foregroundStyle(.secondary)
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
