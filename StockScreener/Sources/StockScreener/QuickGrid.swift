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

    /// Views (in the Quick and Daily Gainers windows, under their content) that host the pages while pictures are taken.
    /// A page must sit in a visible window for TradingView to draw.
    private var hosts: [Weak] = []
    private struct Weak { weak var v: NSView? }
    var host: NSView? {
        let live = hosts.compactMap(\.v).filter { $0.window != nil }
        return live.first { $0.window!.isVisible && $0.window!.occlusionState.contains(.visible) } ?? live.first
    }
    func attach(_ v: NSView) {
        hosts.removeAll { $0.v == nil || $0.v === v }
        hosts.append(Weak(v: v))
    }
    /// A host left its window: stop when no window can show pages any more.
    func hostChanged() { if host == nil { end() } }
    @Published private(set) var fraction = 0.0       // 0…1 while pictures are taken (the Quick button fills blue)
    private var pages: [WKWebView] = []
    private var lw: LWChartHolder?
    private var job: Task<Void, Never>?
    private var hourly: Timer?
    private var done = 0, total = 0
    private var gen = 0
    private weak var vm: ScreenerViewModel?
    /// Set when Quick shows a list (e.g. the other stocks an F formula was true for) instead of today's gainers.
    @Published private(set) var listTitle: String?
    @Published private(set) var listDay: String?
    private var listSymbols: [String] = []

    func showList(title: String, day: String, symbols: [String]) {
        listTitle = title; listDay = day; listSymbols = symbols
        restart()
    }
    func backToGainers() { listTitle = nil; listDay = nil; listSymbols = []; restart() }
    private func restart() {
        job?.cancel(); job = nil; gen += 1
        teardown()
        running = false; progress = ""; tiles = []
        if let vm, host != nil { refresh(vm) }
    }

    var maxStocks: Int { let v = UserDefaults.standard.integer(forKey: "quick.max"); return v > 0 ? v : 18 }
    var maxWait: Double { let v = UserDefaults.standard.double(forKey: "quick.maxWait"); return v > 0 ? v : 20 }
    /// Extra wait after prices show, so indicators and drawings finish too.
    var settle: Double { UserDefaults.standard.object(forKey: "quick.settle") as? Double ?? 3 }
    var parallel: Int { let v = UserDefaults.standard.integer(forKey: "quick.parallel"); return min(3, max(1, v == 0 ? 1 : v)) }
    var charts: [Int] {
        var c: [Int] = []
        if UserDefaults.standard.object(forKey: "quick.c1") as? Bool ?? true { c.append(0) }
        if UserDefaults.standard.object(forKey: "quick.c2") as? Bool ?? true { c.append(1) }
        if UserDefaults.standard.object(forKey: "quick.deliv") as? Bool ?? true { c.append(2) }
        return c
    }

    /// Starts now (unless pictures are under an hour old) and then every hour while a hosting window is open.
    func begin(_ vm: ScreenerViewModel) {
        self.vm = vm
        if !running, updatedAt.map({ Date().timeIntervalSince($0) > 3300 }) ?? true { refresh(vm) }
        guard hourly == nil else { return }
        hourly = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(vm) }
        }
    }

    func end() {
        hourly?.invalidate(); hourly = nil
        job?.cancel(); job = nil; gen += 1
        teardown()
        running = false; progress = ""
    }

    func stop() { job?.cancel() }

    func refresh(_ vm: ScreenerViewModel) {
        guard !running else { return }
        guard host != nil else { progress = "Open Quick or Daily Gainers to take pictures."; return }
        self.vm = vm
        var list: [(symbol: String, change: Double)]
        if listTitle != nil, let from = listDay {
            // a list: change % = since that day
            list = listSymbols.prefix(36).map { s in
                let then = ScreenerViewModel.close(of: s, on: from, prices: vm.priceBook.series(for: s), nse: DeliveryCenter.shared.book.series[s])
                let now = ScreenerViewModel.close(of: s, on: "9999-12-31", prices: vm.priceBook.series(for: s), nse: DeliveryCenter.shared.book.series[s])
                let ch: Double = { if let a = then, let b = now, a > 0 { return (b / a - 1) * 100 }; return 0 }()
                return (s, ch)
            }
        } else {
            let day = vm.currentGainerDay
            var seen = Set<String>()
            list = vm.gainers(on: day).filter { seen.insert($0.symbol).inserted }.prefix(maxStocks).map { ($0.symbol, $0.change) }
            guard !list.isEmpty else { progress = "No gainers on \(day) with the current Daily Gainers settings."; return }
        }
        let old = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        tiles = list.map { g in var t = old[g.symbol] ?? Tile(id: g.symbol, change: g.change); t.change = g.change; return t }
        running = true
        let myGen = gen
        let syms = list.map(\.symbol)
        let want = charts
        let par = parallel
        done = 0; total = syms.count * want.count; fraction = 0
        let started = Date()
        job = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for c in want {
                    let lanes = c == 2 ? 1 : par
                    for lane in 0..<lanes {
                        let mine = syms.enumerated().filter { $0.offset % lanes == lane }.map(\.element)
                        group.addTask { @MainActor in await self.worker(vm, chart: c, symbols: mine, gen: myGen) }
                    }
                }
            }
            guard myGen == gen else { return }      // replaced by a newer run
            teardown()
            let secs = Int(Date().timeIntervalSince(started))
            lastRun = "\(done) pictures in \(secs / 60)m \(secs % 60)s"
            updatedAt = Date(); running = false; progress = ""; fraction = 1
            MemoryRelief.giveBack()
        }
    }

    private func worker(_ vm: ScreenerViewModel, chart c: Int, symbols: [String], gen g: Int) async {
        for sym in symbols {
            if Task.isCancelled || g != gen { return }
            let img = c == 2 ? await deliveryPicture(vm, sym) : await tvPicture(vm, sym, chart: c)
            guard g == gen else { return }
            done += 1
            fraction = total > 0 ? Double(done) / Double(total) : 1
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

    /// A 16:10 page that fits inside the host (pictures then fill the tiles without an empty lower half).
    static func frame(in root: NSView) -> NSRect {
        let b = root.bounds
        let w = max(640, min(b.width, b.height * 1.6)), h = w / 1.6
        return NSRect(x: 0, y: max(0, b.height - h), width: w, height: h)
    }

    func setImage(_ sym: String, chart c: Int, _ img: NSImage) {
        if let i = tiles.firstIndex(where: { $0.id == sym }) { tiles[i].images[c] = img }
    }

    static func newTVPage(account: Int, frame: NSRect) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = TVAccounts.store(account)
        TVPopupBlocker.install(config)
        let v = WKWebView(frame: frame, configuration: config)
        v.customUserAgent = WebHolder.userAgent
        return v
    }

    private func newPage(account: Int) -> WKWebView? {
        guard let root = host else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = TVAccounts.store(account)
        TVPopupBlocker.install(config)
        let v = WKWebView(frame: Self.frame(in: root), configuration: config)
        v.customUserAgent = WebHolder.userAgent
        root.addSubview(v)
        pages.append(v)
        return v
    }

    /// True once TradingView's legend shows prices (O 123.4 H 125 L …) instead of "O∅ H∅ L∅".
    static func pricesShown(_ v: WKWebView) async -> Bool { (try? await v.evaluateJavaScript(readyJS)) as? Bool == true }
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
            if await Self.pricesShown(v) { ready = true; break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        // let indicators / drawings finish (your "Wait after prices show" setting)
        if ready { try? await Task.sleep(nanoseconds: UInt64(max(0.3, settle) * 1_000_000_000)) }
        if Task.isCancelled { return nil }
        return await Self.snap(v)
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
        guard let root = host, DeliveryCenter.shared.book.series[sym] != nil else { return nil }
        if lw == nil {
            let h = LWChartHolder(); h.view.frame = Self.frame(in: root); root.addSubview(h.view); lw = h
            for _ in 0..<40 {      // wait for the chart page (up to ~10 s)
                if (try? await h.view.evaluateJavaScript("typeof window.setData === 'function'")) as? Bool == true { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard let lw, let data = Self.deliveryData(vm, sym) else { return nil }
        lw.show(data)
        try? await Task.sleep(nanoseconds: 900_000_000)
        return await Self.snap(lw.view)
    }

    /// The delivery chart as the chart viewer draws it (your Delivery settings), 6 months.
    static func deliveryData(_ vm: ScreenerViewModel, _ sym: String) -> LWChartData? {
        guard let s = DeliveryCenter.shared.book.series[sym] else { return nil }
        let d = UserDefaults.standard
        let signal = DeliveryMetric(rawValue: d.string(forKey: "deliv.metric") ?? "") ?? .value
        let metric = DeliveryChartBasis.metric(signal: signal, basis: d.string(forKey: DeliveryChartBasis.key) ?? "")
        let layers = ChartLayer.decode(d.string(forKey: "viewer.delivLayers") ?? "")
        let length = d.object(forKey: "deliv.length") as? Int ?? 300
        let full = d.object(forKey: "deliv.full") as? Bool ?? true
        let rises = d.object(forKey: "deliv.onlyRises") as? Bool ?? true
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let candles = CandleCache.shared.candles(sym) ?? DeliveryMiniChart.candles(vm.priceBook.series(for: sym), nse: s)
        return LWChartData.make(symbol: sym, series: s, candles: candles, metric: metric, length: max(2, length),
                                full: full, onlyRises: rises, range: "6M", dark: dark,
                                calendar: DeliveryCenter.shared.calendar, layers: layers,
                                events: LWChartData.eventMarkers(sym, layers: layers),
                                deals: LWChartData.dealBars(sym, layers: layers))
    }

    /// A picture of the page, scaled down to ~900 px wide (keeps memory small).
    static func snap(_ v: WKWebView) async -> NSImage? {
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

/// The spot under a window's content where Quick's pages live while it takes pictures (they must be in a visible window to draw).
struct QuickCaptureHost: NSViewRepresentable {
    final class HostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { QuickCenter.shared.attach(self) }
            else { DispatchQueue.main.async { QuickCenter.shared.hostChanged() } }
        }
    }
    func makeNSView(context: Context) -> NSView { HostView() }
    func updateNSView(_ v: NSView, context: Context) {}
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
    @AppStorage("quick.settle") private var settle = 3.0
    @AppStorage("quick.maxWait") private var maxWait = 20.0
    @AppStorage("quick.auto") private var auto = true
    @State private var page = 0
    @State private var phase = 0
    @State private var retake: Retake?
    @State private var pageTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var tileTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()
    struct Retake: Identifiable { let sym: String; let chart: Int; var id: String { sym + "\(chart)" } }

    private var perPage: Int { grid * grid }
    private var pages: Int { max(1, Int((Double(q.tiles.count) / Double(perPage)).rounded(.up))) }

    var body: some View {
        ZStack {
            // the pages being photographed sit here, hidden under the grid
            QuickCaptureHost().allowsHitTesting(false)
            main.background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear { retime(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { q.begin(vm) } }
        .sheet(item: $retake) { r in QuickRetakeView(symbol: r.sym, chart: r.chart).environmentObject(vm) }
    }

    private var main: some View {
        VStack(spacing: 6) {
            if let t = q.listTitle {
                HStack {
                    Image(systemName: "function").foregroundStyle(.purple)
                    Text(t).font(.callout.bold()).lineLimit(1)
                    Text("· % = change since \(q.listDay ?? "")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Back to gainers") { page = 0; q.backToGainers() }
                }
            }
            controls
            ProgressView(value: q.running ? q.fraction : (q.updatedAt == nil ? 0 : 1)).progressViewStyle(.linear).tint(.blue)
            GeometryReader { geo in
                let gap: CGFloat = 6
                let w = (geo.size.width - gap * CGFloat(grid - 1)) / CGFloat(grid)
                let h = (geo.size.height - gap * CGFloat(grid - 1)) / CGFloat(grid)
                let start = min(page * perPage, max(0, q.tiles.count - 1))
                let shown = Array(q.tiles.dropFirst(start).prefix(perPage))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: gap), count: grid), spacing: gap) {
                    ForEach(shown) { t in tile(t).frame(width: w, height: h) }
                }
            }
        }
        .padding(8)
        .onChange(of: q.listTitle) { _ in page = 0 }
        .onChange(of: pageSec) { _ in retime() }
        .onChange(of: tileSec) { _ in retime() }
        .onReceive(pageTimer) { _ in if pageSec > 0 && pages > 1 && retake == nil { page = (page + 1) % pages } }
        .onReceive(tileTimer) { _ in if tileSec > 0 && retake == nil { phase &+= 1 } }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $grid) { Text("2 × 2").tag(2); Text("3 × 3").tag(3) }.pickerStyle(.segmented).fixedSize()
            Toggle("Chart 1", isOn: $c1); Toggle("Chart 2", isOn: $c2); Toggle("Delivery", isOn: $deliv)
            Menu {
                Picker("Stocks", selection: $maxStocks) { ForEach([4, 9, 12, 18, 27, 36], id: \.self) { Text("\($0)").tag($0) } }
                Picker("Turn page every", selection: $pageSec) { Text("Off").tag(0); ForEach([10, 20, 30, 60], id: \.self) { Text("\($0) s").tag($0) } }
                Picker("Switch chart every", selection: $tileSec) { Text("Off").tag(0); ForEach([4, 6, 10, 15], id: \.self) { Text("\($0) s").tag($0) } }
                Divider()
                Picker("Wait after prices show", selection: $settle) { ForEach([1.0, 2.0, 3.0, 5.0, 8.0, 12.0], id: \.self) { Text("\(Int($0)) s").tag($0) } }
                Picker("Give up loading after", selection: $maxWait) { ForEach([10.0, 15.0, 20.0, 30.0, 45.0], id: \.self) { Text("\(Int($0)) s").tag($0) } }
                Picker("Pages at once (per chart)", selection: $parallel) { ForEach(1...3, id: \.self) { Text("\($0)").tag($0) } }
                Divider()
                Toggle("Refresh every hour while Daily Gainers or Quick is open", isOn: $auto)
            } label: { Label("Options", systemImage: "gearshape") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("How many stocks, rotation speed, how long to wait for each chart, pages loaded side by side, hourly refresh")
            Spacer()
            if q.running {
                Text(q.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Stop") { q.stop() }
            } else {
                if let t = q.updatedAt { Text("updated \(t.formatted(date: .omitted, time: .shortened)) · \(q.lastRun)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                else if !q.progress.isEmpty { Text(q.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Button("Refresh") { q.refresh(vm) }
            }
            Button { page = (page - 1 + pages) % pages } label: { Image(systemName: "chevron.left") }
            Text("\(page + 1)/\(pages)").monospacedDigit().font(.caption)
            Button { page = (page + 1) % pages } label: { Image(systemName: "chevron.right") }
        }
        .toggleStyle(.checkbox).controlSize(.small)
    }

    private func retime() {
        pageTimer = Timer.publish(every: TimeInterval(max(1, pageSec)), on: .main, in: .common).autoconnect()
        tileTimer = Timer.publish(every: TimeInterval(max(1, tileSec)), on: .main, in: .common).autoconnect()
    }

    @ViewBuilder private func tile(_ t: QuickCenter.Tile) -> some View {
        let keys = [0, 1, 2].filter { t.images[$0] != nil }
        let k = keys.isEmpty ? nil : keys[phase % keys.count]
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(t.id).font(.callout.bold())
                Text(String(format: "%+.2f%%", t.change)).font(.caption.monospacedDigit()).foregroundStyle(t.change >= 0 ? .green : .red)
                Spacer()
                if let k { Text(k == 2 ? "Delivery" : "Chart \(k + 1)").font(.caption2).foregroundStyle(.secondary) }
                Menu {
                    Button("Chart 1") { retake = Retake(sym: t.id, chart: 0) }
                    Button("Chart 2") { retake = Retake(sym: t.id, chart: 1) }
                    Button("Delivery") { retake = Retake(sym: t.id, chart: 2) }
                } label: { Image(systemName: "camera.rotate") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Take this picture again: opens the live chart so you can fix it (zoom, scroll, close a pop-up), then takes the picture after a delay")
            }
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.08))
                if let k, let img = t.images[k] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else if q.running {
                    ProgressView().controlSize(.small)
                } else {
                    Text("no picture").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { vm.openChart(t.id, queue: q.tiles.map(\.id), context: .gainers, openWindow: openWindow) }
            .help("Click to open \(t.id) in the chart viewer")
        }
    }
}

/// Retake one picture: the live chart, which you can fix by hand; the picture is taken when the countdown ends.
struct QuickRetakeView: View {
    let symbol: String
    let chart: Int
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("quick.retakeDelay") private var delay = 10
    @State private var web: WKWebView?
    @State private var lw: LWChartHolder?
    @State private var left = 0
    @State private var counting = false
    @State private var busy = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(symbol) · \(chart == 2 ? "Delivery" : "Chart \(chart + 1)")").font(.headline)
                Text("Fix the chart (zoom, scroll, close pop-ups) — the picture is taken when the countdown ends.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Delay", selection: $delay) { ForEach([5, 10, 20, 30, 60], id: \.self) { Text("\($0) s").tag($0) } }.fixedSize()
                    .onChange(of: delay) { _ in left = delay }
                if counting { Text("\(left) s").font(.title3.monospacedDigit()).foregroundStyle(.blue) }
                Button(counting ? "Pause" : "Start countdown") { counting.toggle(); if counting && left <= 0 { left = delay } }
                Button("Take now") { capture() }.keyboardShortcut(.defaultAction).disabled(busy)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            Group {
                if chart == 2, let lw { LWChartView(holder: lw) }
                else if let web { WebBox(view: web) }
                else { Text("No chart for \(symbol)").foregroundStyle(.secondary) }
            }
            .aspectRatio(1.6, contentMode: .fit)
        }
        .padding(10)
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear(perform: load)
        .onReceive(tick) { _ in
            guard counting, !busy else { return }
            left -= 1
            if left <= 0 { capture() }
        }
    }

    private func load() {
        left = delay; counting = true
        if chart == 2 {
            let h = LWChartHolder(); lw = h
            if let d = QuickCenter.deliveryData(vm, symbol) { h.show(d) }
        } else if let url = vm.chartURL(symbol, column: min(chart, max(0, vm.chartCount - 1))) {
            let v = QuickCenter.newTVPage(account: TVAccounts.account(forChart: chart), frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
            v.load(URLRequest(url: url))
            web = v
        }
    }

    private func capture() {
        guard !busy, let v = chart == 2 ? lw?.view : web else { return }
        busy = true; counting = false
        Task { @MainActor in
            if let img = await QuickCenter.snap(v) { QuickCenter.shared.setImage(symbol, chart: chart, img) }
            web?.stopLoading()
            dismiss()
        }
    }

    private struct WebBox: NSViewRepresentable {
        let view: WKWebView
        func makeNSView(context: Context) -> WKWebView { view }
        func updateNSView(_ v: WKWebView, context: Context) {}
    }
}

/// The Quick button for Daily Gainers: fills grey → blue as the pictures are taken.
struct QuickButton: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var q = QuickCenter.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("quick.auto") private var auto = true

    var body: some View {
        let f = q.running ? q.fraction : (q.updatedAt == nil ? 0 : 1)
        Button { openWindow(id: "quick") } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x3")
                Text(q.running ? "Quick \(Int(f * 100))%" : "Quick").monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(f >= 1 ? Color.white : Color.primary)
            .background(alignment: .leading) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.25))
                        Capsule().fill(Color.blue).frame(width: max(0, g.size.width * f))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .help(q.running ? "Taking pictures: \(q.progress)" : (q.updatedAt.map { "Pictures ready (\($0.formatted(date: .omitted, time: .shortened))) — click to see them" } ?? "Pictures of Chart 1, Chart 2 and the delivery chart of these gainers in a 2×2 or 3×3 grid — refreshed every hour"))
        .onAppear { if auto { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { q.begin(vm) } } }
    }
}
