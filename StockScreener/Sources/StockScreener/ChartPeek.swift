import SwiftUI
import AppKit
import WebKit

/// Quick look at a stock's chart from the Filter table: a small floating window near the mouse that closes by
/// itself after a few seconds (paused while the mouse is over it). Double right-click = Chart 1,
/// double left-click = Chart 2 (settings in the Filter toolbar's eye menu).
@MainActor final class ChartPeek: NSObject, NSWindowDelegate {
    static let shared = ChartPeek()
    private let pool = ReelPool()
    private var panel: NSPanel?
    private var timer: Timer?
    private var shownAt = Date()
    private var readyAt: Date?
    private var title = ""
    private var preloadWork: DispatchWorkItem?

    static var seconds: Double { let v = UserDefaults.standard.double(forKey: "peek.seconds"); return UserDefaults.standard.object(forKey: "peek.seconds") == nil ? 3 : v }
    static var size: String { UserDefaults.standard.string(forKey: "peek.size") ?? "Medium" }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "peek.enabled") as? Bool ?? true }
    static var preloadOn: Bool { UserDefaults.standard.object(forKey: "peek.preload") as? Bool ?? true }
    static let sizes: [(String, CGSize)] = [("Small", CGSize(width: 480, height: 300)), ("Medium", CGSize(width: 720, height: 450)),
                                            ("Large", CGSize(width: 1000, height: 620)), ("Extra large", CGSize(width: 1300, height: 820))]

    private static func frameSize() -> CGSize {
        if size == "Custom" {
            let w = UserDefaults.standard.double(forKey: "peek.w"), h = UserDefaults.standard.double(forKey: "peek.h")
            if w > 200, h > 150 { return CGSize(width: w, height: h) }
        }
        return sizes.first { $0.0 == size }?.1 ?? sizes[1].1
    }

    /// Loads both charts of the selected stock in the background, so a peek opens instantly.
    func preload(_ symbol: String, vm: ScreenerViewModel) {
        guard Self.enabled, Self.preloadOn else { return }
        preloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var urls: [(URL, Int, String?)] = []
            for c in 0..<min(2, vm.chartCount) { if let u = vm.chartURL(symbol, column: c) { urls.append((u, c, nil)) } }
            self.pool.preload(urls, keep: 6)
        }
        preloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func show(_ symbol: String, chart: Int, vm: ScreenerViewModel) {
        let c = min(chart, max(0, vm.chartCount - 1))
        guard let url = vm.chartURL(symbol, column: c) else { NSSound.beep(); return }
        let web = pool.view(for: url, slot: chart)
        let size = Self.frameSize()
        // near the mouse, kept on screen
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: m.x + 18, y: m.y - size.height / 2)
        if origin.x + size.width > vis.maxX { origin.x = m.x - 18 - size.width }
        origin.x = max(vis.minX, min(origin.x, vis.maxX - size.width))
        origin.y = max(vis.minY, min(origin.y, vis.maxY - size.height))
        let frame = NSRect(origin: origin, size: size)

        let p: NSPanel
        if let existing = panel { p = existing; p.setFrame(frame, display: true) } else {
            p = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.delegate = self
            panel = p
        }
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: box.leadingAnchor), web.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                                     web.topAnchor.constraint(equalTo: box.topAnchor), web.bottomAnchor.constraint(equalTo: box.bottomAnchor)])
        p.contentView = box
        title = "\(symbol) · Chart \(chart + 1)"
        p.title = title
        p.orderFrontRegardless()
        shownAt = Date()
        readyAt = web.isLoading ? nil : Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak web] _ in
            Task { @MainActor in self?.tick(web) }
        }
    }

    /// Counts down only once the chart has loaded (max 12 s of loading), and pauses while the mouse is over it.
    private func tick(_ web: WKWebView?) {
        guard let p = panel, p.isVisible else { timer?.invalidate(); return }
        let secs = Self.seconds
        if readyAt == nil, !(web?.isLoading ?? false) || Date().timeIntervalSince(shownAt) > 12 { readyAt = Date() }
        guard let r = readyAt else { p.title = "\(title) · loading…"; return }
        if secs <= 0 { p.title = title; return }                                   // "until closed"
        if NSMouseInRect(NSEvent.mouseLocation, p.frame, false) { readyAt = Date(); p.title = "\(title) · paused"; return }
        let left = secs - Date().timeIntervalSince(r)
        if left <= 0 { close() } else { p.title = "\(title) · \(Int(left.rounded(.up)))s" }
    }

    func close() {
        timer?.invalidate()
        panel?.orderOut(nil)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let p = panel else { return }
        UserDefaults.standard.set(p.frame.width, forKey: "peek.w")
        UserDefaults.standard.set(p.frame.height, forKey: "peek.h")
        UserDefaults.standard.set("Custom", forKey: "peek.size")
    }

    func windowWillClose(_ notification: Notification) { timer?.invalidate() }
}

/// Filter toolbar menu: peek on / off, how long, how big, what double left-click does.
struct PeekMenu: View {
    @AppStorage("peek.enabled") private var enabled = true
    @AppStorage("peek.seconds") private var seconds = 3.0
    @AppStorage("peek.size") private var size = "Medium"
    @AppStorage("peek.preload") private var preload = true
    @AppStorage("peek.leftOpensViewer") private var leftOpensViewer = false

    var body: some View {
        Menu {
            Toggle("Quick chart on double-click (right = Chart 1, left = Chart 2)", isOn: $enabled)
            Picker("Show for", selection: $seconds) {
                ForEach([2.0, 3, 5, 8, 10, 15, 30], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                Text("Until I close it").tag(0.0)
            }
            Picker("Size", selection: $size) {
                ForEach(ChartPeek.sizes, id: \.0) { s in Text("\(s.0) (\(Int(s.1.width))×\(Int(s.1.height)))").tag(s.0) }
                Text("Custom (resize the window once)").tag("Custom")
            }
            Divider()
            Toggle("Double left-click opens the Chart viewer instead", isOn: $leftOpensViewer)
            Toggle("Preload both charts of the selected row (faster)", isOn: $preload)
            Divider()
            Text("The countdown starts when the chart has loaded and pauses while the mouse is over it.")
        } label: {
            Label("Quick chart", systemImage: "eye")
        }
        .help("Double right-click a row = Chart 1, double left-click = Chart 2, shown for a few seconds — choose time and size here")
    }
}
