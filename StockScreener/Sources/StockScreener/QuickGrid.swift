import SwiftUI
import WebKit
import AppKit

/// "Quick": pictures of today's gainers' charts in a 2×2 / 3×3 grid that turns its own pages.
/// Every hour (and on Refresh) it opens each gainer's Chart 1 / Chart 2 (TradingView) — and optionally its delivery
/// chart — in a hidden window, waits for them to draw, takes a picture and closes them again (one page at a time,
/// so memory stays low). Each tile rotates through the stock's pictures; pages of tiles rotate too.
@MainActor final class QuickCenter: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = QuickCenter()

    struct Tile: Identifiable { let id: String; var change: Double; var images: [Int: NSImage] = [:] }   // 0 Chart 1, 1 Chart 2, 2 Delivery
    @Published private(set) var tiles: [Tile] = []
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var updatedAt: Date?

    private var window: NSWindow?
    private var web: WKWebView?
    private var webAccount = -1
    private var lw: LWChartHolder?
    private var loaded: CheckedContinuation<Void, Never>?
    private var loadToken = 0
    private var job: Task<Void, Never>?
    private var hourly: Timer?

    var maxStocks: Int { let v = UserDefaults.standard.integer(forKey: "quick.max"); return v > 0 ? v : 18 }
    var renderWait: Double { let v = UserDefaults.standard.double(forKey: "quick.wait"); return v > 0 ? v : 7 }
    var charts: [Int] {
        var c: [Int] = []
        if UserDefaults.standard.object(forKey: "quick.c1") as? Bool ?? true { c.append(0) }
        if UserDefaults.standard.object(forKey: "quick.c2") as? Bool ?? true { c.append(1) }
        if UserDefaults.standard.object(forKey: "quick.deliv") as? Bool ?? true { c.append(2) }
        return c
    }

    /// Starts now and then every hour while the Quick window is open.
    func begin(_ vm: ScreenerViewModel) {
        refresh(vm)
        hourly?.invalidate()
        hourly = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(vm) }
        }
    }

    func end() {
        hourly?.invalidate(); hourly = nil
        job?.cancel(); job = nil
        finishLoad()
        teardown()
        running = false; progress = ""
    }

    func refresh(_ vm: ScreenerViewModel) {
        guard !running else { return }
        let day = vm.currentGainerDay
        var seen = Set<String>()
        let list = Array(vm.gainers(on: day).filter { seen.insert($0.symbol).inserted }.prefix(maxStocks))
        guard !list.isEmpty else { progress = "No gainers on \(day) with the current Daily Gainers settings."; return }
        // keep pictures of stocks still in the list; new stocks start empty
        let old = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        tiles = list.map { g in var t = old[g.symbol] ?? Tile(id: g.symbol, change: g.change); t.change = g.change; return t }
        running = true
        let want = charts
        job = Task { @MainActor in
            for (k, g) in list.enumerated() {
                for c in want {
                    if Task.isCancelled { break }
                    progress = "\(k + 1)/\(list.count) \(g.symbol) · \(c == 2 ? "Delivery" : "Chart \(c + 1)")"
                    if let img = await capture(vm, g.symbol, chart: c), let i = tiles.firstIndex(where: { $0.id == g.symbol }) {
                        tiles[i].images[c] = img
                    }
                }
            }
            teardown()
            updatedAt = Date(); running = false; progress = ""
            MemoryRelief.giveBack()
        }
    }

    // MARK: Taking the pictures

    private func host() -> NSView {
        if let w = window, let v = w.contentView { return v }
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0.01
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
        window = w
        return w.contentView!
    }

    private func teardown() {
        if let v = web { v.stopLoading(); v.removeFromSuperview(); v.navigationDelegate = nil }
        web = nil; webAccount = -1
        lw?.view.removeFromSuperview(); lw = nil
        window?.orderOut(nil); window?.close(); window = nil
    }

    private func capture(_ vm: ScreenerViewModel, _ sym: String, chart c: Int) async -> NSImage? {
        let root = host()
        if c == 2 {
            guard let s = DeliveryCenter.shared.book.series[sym] else { return nil }
            if lw == nil { let h = LWChartHolder(); h.view.frame = root.bounds; root.addSubview(h.view); lw = h }
            let d = UserDefaults.standard
            let signal = DeliveryMetric(rawValue: d.string(forKey: "deliv.metric") ?? "") ?? .value
            let metric = DeliveryChartBasis.metric(signal: signal, basis: d.string(forKey: DeliveryChartBasis.key) ?? "")
            let layers = ChartLayer.decode(d.string(forKey: "viewer.delivLayers") ?? "")
            let length = d.object(forKey: "deliv.length") as? Int ?? 300
            let full = d.object(forKey: "deliv.full") as? Bool ?? true
            let rises = d.object(forKey: "deliv.onlyRises") as? Bool ?? true
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let candles = CandleCache.shared.candles(sym) ?? DeliveryMiniChart.candles(vm.priceBook.series(for: sym), nse: s)
            let data = LWChartData.make(symbol: sym, series: s, candles: candles, metric: metric, length: max(2, length),
                                        full: full, onlyRises: rises, range: "6M", dark: dark,
                                        calendar: DeliveryCenter.shared.calendar, layers: layers,
                                        events: LWChartData.eventMarkers(sym, layers: layers),
                                        deals: LWChartData.dealBars(sym, layers: layers))
            lw?.show(data)
            try? await Task.sleep(nanoseconds: 2_500_000_000)     // first time the chart page itself loads
            guard let v = lw?.view else { return nil }
            return await snap(v)
        }
        guard let url = vm.chartURL(sym, column: min(c, max(0, vm.chartCount - 1))) else { return nil }
        let acct = TVAccounts.account(forChart: c)
        if web == nil || webAccount != acct {
            if let v = web { v.stopLoading(); v.removeFromSuperview() }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = TVAccounts.store(acct)
            TVPopupBlocker.install(config)
            let v = WKWebView(frame: root.bounds, configuration: config)
            v.customUserAgent = WebHolder.userAgent
            v.navigationDelegate = self
            root.addSubview(v)
            web = v; webAccount = acct
        }
        guard let v = web else { return nil }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            loaded = k
            loadToken += 1
            let token = loadToken
            v.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in     // give up waiting
                guard let self, self.loadToken == token else { return }
                self.finishLoad()
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(renderWait * 1_000_000_000))      // TradingView draws after "loaded"
        return await snap(v)
    }

    private func finishLoad() { loaded?.resume(); loaded = nil }
    nonisolated func webView(_ w: WKWebView, didFinish n: WKNavigation!) { Task { @MainActor in self.finishLoad() } }
    nonisolated func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { Task { @MainActor in self.finishLoad() } }
    nonisolated func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { Task { @MainActor in self.finishLoad() } }

    /// A picture of the page, scaled down to ~900 px wide (keeps memory small).
    private func snap(_ v: WKWebView) async -> NSImage? {
        let img: NSImage? = await withCheckedContinuation { k in
            v.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in k.resume(returning: image) }
        }
        guard let img, img.size.width > 0 else { return nil }
        let w: CGFloat = 900, h = img.size.height * w / img.size.width
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}

struct QuickGridView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var q = QuickCenter.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("quick.grid") private var grid = 2
    @AppStorage("quick.pageSec") private var pageSec = 20
    @AppStorage("quick.tileSec") private var tileSec = 6
    @AppStorage("quick.c1") private var c1 = true
    @AppStorage("quick.c2") private var c2 = true
    @AppStorage("quick.deliv") private var deliv = true
    @AppStorage("quick.max") private var maxStocks = 18
    @State private var page = 0
    @State private var phase = 0
    @State private var pageTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var tileTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var perPage: Int { grid * grid }
    private var pages: Int { max(1, Int((Double(q.tiles.count) / Double(perPage)).rounded(.up))) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Picker("", selection: $grid) { Text("2 × 2").tag(2); Text("3 × 3").tag(3) }.pickerStyle(.segmented).fixedSize()
                Toggle("Chart 1", isOn: $c1); Toggle("Chart 2", isOn: $c2); Toggle("Delivery", isOn: $deliv)
                Picker("Stocks", selection: $maxStocks) { ForEach([4, 9, 12, 18, 27, 36], id: \.self) { Text("\($0)").tag($0) } }.fixedSize()
                Picker("Page every", selection: $pageSec) { Text("off").tag(0); ForEach([10, 20, 30, 60], id: \.self) { Text("\($0) s").tag($0) } }.fixedSize()
                Picker("Chart every", selection: $tileSec) { Text("off").tag(0); ForEach([4, 6, 10, 15], id: \.self) { Text("\($0) s").tag($0) } }.fixedSize()
                Spacer()
                if q.running { ProgressView().controlSize(.small); Text(q.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                else if let t = q.updatedAt { Text("updated \(t.formatted(date: .omitted, time: .shortened)) · every hour").font(.caption).foregroundStyle(.secondary) }
                Button("Refresh") { q.refresh(vm) }.disabled(q.running)
                Button { page = (page - 1 + pages) % pages } label: { Image(systemName: "chevron.left") }
                Text("\(page + 1)/\(pages)").monospacedDigit().font(.caption)
                Button { page = (page + 1) % pages } label: { Image(systemName: "chevron.right") }
            }
            .toggleStyle(.checkbox).controlSize(.small)
            let start = min(page * perPage, max(0, q.tiles.count - 1))
            let shown = Array(q.tiles.dropFirst(start).prefix(perPage))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: grid), spacing: 6) {
                ForEach(shown) { t in tile(t) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .onAppear { q.begin(vm); retime() }
        .onDisappear { q.end() }
        .onChange(of: pageSec) { _ in retime() }
        .onChange(of: tileSec) { _ in retime() }
        .onReceive(pageTimer) { _ in if pageSec > 0 && pages > 1 { page = (page + 1) % pages } }
        .onReceive(tileTimer) { _ in if tileSec > 0 { phase &+= 1 } }
    }

    private func retime() {
        pageTimer = Timer.publish(every: TimeInterval(max(1, pageSec)), on: .main, in: .common).autoconnect()
        tileTimer = Timer.publish(every: TimeInterval(max(1, tileSec)), on: .main, in: .common).autoconnect()
    }

    @ViewBuilder private func tile(_ t: QuickCenter.Tile) -> some View {
        let keys = [0, 1, 2].filter { t.images[$0] != nil }
        let k = keys.isEmpty ? nil : keys[phase % keys.count]
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(t.id).font(.callout.bold())
                Text(String(format: "%+.2f%%", t.change)).font(.caption.monospacedDigit()).foregroundStyle(t.change >= 0 ? .green : .red)
                Spacer()
                if let k { Text(k == 2 ? "Delivery" : "Chart \(k + 1)").font(.caption2).foregroundStyle(.secondary) }
            }
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.08))
                if let k, let img = t.images[k] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(1280 / 760, contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture { vm.openChart(t.id, queue: q.tiles.map(\.id), context: .gainers, openWindow: openWindow) }
            .help("Click to open \(t.id) in the chart viewer")
        }
    }
}
