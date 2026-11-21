import SwiftUI
import WebKit
import AppKit

/// "Quick": pictures of today's gainers' charts in a 2×2 / 3×3 grid that turns its own pages.
/// Every hour (and on Refresh) it opens each gainer's Chart 1 / Chart 2 (TradingView) — and optionally its delivery
/// chart — in pages hidden BEHIND the grid of the Quick window (a page in an off-screen window doesn't draw its chart),
/// waits until the chart shows prices, takes a picture, and moves on. Chart 1, Chart 2 and Delivery run side by side,
/// optionally with more than one page each.
@MainActor final class QuickCenter: NSObject, ObservableObject {
    static let shared = QuickCenter()

    struct Tile: Identifiable { let id: String; var change: Double; var images: [Int: NSImage] = [:] }   // 0 Chart 1, 1 Chart 2, 2 Delivery
    @Published private(set) var tiles: [Tile] = []
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var updatedAt: Date?
    @Published private(set) var lastRun = ""

    /// The view (inside the Quick window, under the grid) that hosts the pages while pictures are taken.
    weak var host: NSView?
    private var pages: [WKWebView] = []
    private var lw: LWChartHolder?
    private var job: Task<Void, Never>?
    private var hourly: Timer?
    private var done = 0, total = 0

    var maxStocks: Int { let v = UserDefaults.standard.integer(forKey: "quick.max"); return v > 0 ? v : 18 }
    var maxWait: Double { let v = UserDefaults.standard.double(forKey: "quick.maxWait"); return v > 0 ? v : 15 }
    var parallel: Int { let v = UserDefaults.standard.integer(forKey: "quick.parallel"); return min(3, max(1, v == 0 ? 1 : v)) }
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
        teardown()
        running = false; progress = ""
    }

    func stop() { job?.cancel() }

    func refresh(_ vm: ScreenerViewModel) {
        guard !running else { return }
        guard host?.window != nil else { progress = "Open the Quick window to take pictures."; return }
        let day = vm.currentGainerDay
        var seen = Set<String>()
        let list = Array(vm.gainers(on: day).filter { seen.insert($0.symbol).inserted }.prefix(maxStocks))
        guard !list.isEmpty else { progress = "No gainers on \(day) with the current Daily Gainers settings."; return }
        let old = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        tiles = list.map { g in var t = old[g.symbol] ?? Tile(id: g.symbol, change: g.change); t.change = g.change; return t }
        running = true
        let syms = list.map(\.symbol)
        let want = charts
        let par = parallel
        done = 0; total = syms.count * want.count
        let started = Date()
        job = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for c in want {
                    let lanes = c == 2 ? 1 : par
                    for lane in 0..<lanes {
                        let mine = syms.enumerated().filter { $0.offset % lanes == lane }.map(\.element)
                        group.addTask { @MainActor in await self.worker(vm, chart: c, symbols: mine) }
                    }
                }
            }
            teardown()
            let secs = Int(Date().timeIntervalSince(started))
            lastRun = "\(done) pictures in \(secs / 60)m \(secs % 60)s"
            updatedAt = Date(); running = false; progress = ""
            MemoryRelief.giveBack()
        }
    }

    private func worker(_ vm: ScreenerViewModel, chart c: Int, symbols: [String]) async {
        for sym in symbols {
            if Task.isCancelled { return }
            let img = c == 2 ? await deliveryPicture(vm, sym) : await tvPicture(vm, sym, chart: c)
            done += 1
            progress = "\(done)/\(total) · \(sym) \(c == 2 ? "Delivery" : "Chart \(c + 1)")"
            if let img, let i = tiles.firstIndex(where: { $0.id == sym }) { tiles[i].images[c] = img }
        }
    }

    // MARK: Taking the pictures

    private func teardown() {
        for v in pages { v.stopLoading(); v.removeFromSuperview() }
        pages = []; owned = [:]
        lw?.view.removeFromSuperview(); lw = nil
    }

    private func newPage(account: Int) -> WKWebView? {
        guard let root = host else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = TVAccounts.store(account)
        TVPopupBlocker.install(config)
        let v = WKWebView(frame: root.bounds, configuration: config)
        v.autoresizingMask = [.width, .height]
        v.customUserAgent = WebHolder.userAgent
        root.addSubview(v)
        pages.append(v)
        return v
    }

    /// True once TradingView's legend shows prices (O 123.4 H 125 L …) instead of "O∅ H∅ L∅".
    private static let readyJS = """
    (() => { const t = document.body ? document.body.innerText : '';
      return /O\\s*[0-9][0-9,.]*\\s*H\\s*[0-9][0-9,.]*\\s*L\\s*[0-9]/.test(t); })()
    """

    private func tvPicture(_ vm: ScreenerViewModel, _ sym: String, chart c: Int) async -> NSImage? {
        guard let url = vm.chartURL(sym, column: min(c, max(0, vm.chartCount - 1))) else { return nil }
        guard let v = pageFor(sym: sym, chart: c) else { return nil }
        v.load(URLRequest(url: url))
        let deadline = Date().addingTimeInterval(maxWait)
        var ready = false
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        while Date() < deadline && !Task.isCancelled {
            if (try? await v.evaluateJavaScript(Self.readyJS)) as? Bool == true { ready = true; break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        try? await Task.sleep(nanoseconds: ready ? 900_000_000 : 0)    // let the candles finish drawing
        return await snap(v)
    }

    /// Which page a symbol's chart is loaded in: workers own pages by (chart, lane).
    private var owned: [String: WKWebView] = [:]
    private func pageFor(sym: String, chart c: Int) -> WKWebView? {
        let lanes = parallel
        let lane = (tiles.firstIndex(where: { $0.id == sym }) ?? 0) % lanes
        let key = "\(c)-\(lane)"
        if let v = owned[key], v.superview != nil { return v }
        let v = newPage(account: TVAccounts.account(forChart: c))
        owned[key] = v
        return v
    }

    private func deliveryPicture(_ vm: ScreenerViewModel, _ sym: String) async -> NSImage? {
        guard let root = host, let s = DeliveryCenter.shared.book.series[sym] else { return nil }
        if lw == nil {
            let h = LWChartHolder(); h.view.frame = root.bounds; h.view.autoresizingMask = [.width, .height]; root.addSubview(h.view); lw = h
            for _ in 0..<40 {      // wait for the chart page (up to ~10 s)
                if (try? await h.view.evaluateJavaScript("typeof window.setData === 'function'")) as? Bool == true { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard let lw else { return nil }
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
        lw.show(data)
        try? await Task.sleep(nanoseconds: 700_000_000)
        return await snap(lw.view)
    }

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

/// The spot under the grid where Quick's pages live while it takes pictures (they must be in a visible window to draw).
struct QuickCaptureHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        QuickCenter.shared.host = v
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { QuickCenter.shared.host = v }
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
    @AppStorage("quick.parallel") private var parallel = 1
    @State private var page = 0
    @State private var phase = 0
    @State private var pageTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var tileTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var perPage: Int { grid * grid }
    private var pages: Int { max(1, Int((Double(q.tiles.count) / Double(perPage)).rounded(.up))) }

    var body: some View {
        ZStack {
            // the pages being photographed sit here (same size as the window), hidden under the grid
            QuickCaptureHost().allowsHitTesting(false)
            main.background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear { retime(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { q.begin(vm) } }
        .onDisappear { q.end() }
    }

    private var main: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Picker("", selection: $grid) { Text("2 × 2").tag(2); Text("3 × 3").tag(3) }.pickerStyle(.segmented).fixedSize()
                Toggle("Chart 1", isOn: $c1); Toggle("Chart 2", isOn: $c2); Toggle("Delivery", isOn: $deliv)
                Picker("Stocks", selection: $maxStocks) { ForEach([4, 9, 12, 18, 27, 36], id: \.self) { Text("\($0)").tag($0) } }.fixedSize()
                Picker("Page every", selection: $pageSec) { Text("off").tag(0); ForEach([10, 20, 30, 60], id: \.self) { Text("\($0) s").tag($0) } }.fixedSize()
                Picker("Chart every", selection: $tileSec) { Text("off").tag(0); ForEach([4, 6, 10, 15], id: \.self) { Text("\($0) s").tag($0) } }.fixedSize()
                Picker("Pages at once", selection: $parallel) { ForEach(1...3, id: \.self) { Text("\($0)").tag($0) } }.fixedSize()
                    .help("TradingView pages loaded side by side for each chart. 2–3 is faster but uses more memory.")
                Spacer()
                if q.running {
                    ProgressView().controlSize(.small); Text(q.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Stop") { q.stop() }
                } else {
                    if let t = q.updatedAt { Text("updated \(t.formatted(date: .omitted, time: .shortened)) · \(q.lastRun) · every hour").font(.caption).foregroundStyle(.secondary) }
                    else if !q.progress.isEmpty { Text(q.progress).font(.caption).foregroundStyle(.secondary) }
                    Button("Refresh") { q.refresh(vm) }
                }
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
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture { vm.openChart(t.id, queue: q.tiles.map(\.id), context: .gainers, openWindow: openWindow) }
            .help("Click to open \(t.id) in the chart viewer")
        }
    }
}
