import SwiftUI
import AppKit

/// Launch with `--screenshots` to render the main screens with SAMPLE data to PNG files and quit.
/// Used by CI to produce README screenshots. Your real journal is never read or written.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains("--screenshots") else { return }
        Task { @MainActor in
            await ScreenshotRunner.run()
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Sample data

enum DemoData {
    /// Deterministic pseudo-random walk so screenshots are stable between builds.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func candles(start: Double, drift: Double, vol: Double, seed: UInt64, days: Int = 400) -> [Candle] {
        var rng = LCG(state: seed)
        let cal = Calendar.ist
        let today = cal.startOfDay(for: Date())
        var dates: [Date] = []
        var d = cal.date(byAdding: .day, value: -days, to: today) ?? today
        while d <= today {
            let wd = cal.component(.weekday, from: d)
            if wd != 1 && wd != 7 { dates.append(d) }
            d = cal.date(byAdding: .day, value: 1, to: d) ?? today.addingTimeInterval(86_400)
        }
        var out: [Candle] = []
        var close = start
        for date in dates {
            let open = close * (1 + (rng.next() - 0.5) * vol * 0.6)
            close = max(1, open * (1 + drift + (rng.next() - 0.5) * vol * 2))
            let high = max(open, close) * (1 + rng.next() * vol * 0.7)
            let low = min(open, close) * (1 - rng.next() * vol * 0.7)
            out.append(Candle(date: date, open: open, high: high, low: low, close: close,
                              volume: 1_000_000 + rng.next() * 4_000_000))
        }
        return out
    }

    struct DemoSet {
        var data: AppData
        var series: [String: QuoteSeries]
        var featured: UUID
    }

    static func make() -> DemoSet {
        let cal = Calendar.ist
        func daysAgo(_ n: Int, _ hour: Int, _ minute: Int) -> Date {
            let base = cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: Date())) ?? Date()
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }

        let specs: [(String, String, SymbolStatus, Double, Double, Double, UInt64)] = [
            ("RELIANCE", "Reliance Industries Limited", .holding, 1240, 0.0011, 0.016, 11),
            ("HDFCBANK", "HDFC Bank Limited", .watching, 905, 0.0004, 0.013, 23),
            ("TMPV", "Tata Motors Passenger Vehicles Ltd", .watching, 470, -0.0007, 0.021, 37),
            ("BEL", "Bharat Electronics Limited", .holding, 285, 0.0016, 0.019, 41),
            ("INFY", "Infosys Limited", .exited, 1720, -0.0004, 0.015, 53)
        ]
        var data = AppData()
        var series: [String: QuoteSeries] = [:]
        var ids: [String: UUID] = [:]
        for (t, name, status, start, drift, vol, seed) in specs {
            let s = TrackedSymbol(ticker: t, displayName: name, status: status,
                                  addedAt: daysAgo(260, 10, 0), thesis: "", tags: [])
            data.symbols.append(s)
            ids[t] = s.id
            series[s.yahooSymbol] = QuoteSeries(symbol: s.yahooSymbol, name: name, currency: "INR",
                                                candles: candles(start: start, drift: drift, vol: vol, seed: seed))
        }
        if let i = data.symbols.firstIndex(where: { $0.ticker == "RELIANCE" }) {
            data.symbols[i].thesis = "Base building since Feb on the weekly. Adding on closes above the range high with volume; out below the 200-DMA."
            data.symbols[i].tags = ["base", "energy"]
        }

        func price(_ t: String, _ date: Date) -> Double? {
            let day = cal.startOfDay(for: date)
            return series[t + ".NS"]?.candles.first { $0.date >= day }?.close
        }

        let notes: [(String, Int, Int, Int, ChartTimeframe, Sentiment, String, [String])] = [
            ("RELIANCE", 230, 10, 40, .weekly, .bullish, "Weekly: higher lows since the Jan low, flag forming under resistance. Volume drying up on pullbacks — wait for a weekly close above the range.", ["flag", "volume"]),
            ("HDFCBANK", 214, 21, 15, .daily, .neutral, "Daily: stuck inside a 4-week range. RSI flat near 50. Nothing to do until it picks a side.", ["range"]),
            ("TMPV", 201, 9, 30, .daily, .bearish, "Lower highs on the daily after the gap-down. Below 50-DMA and 200-DMA. Avoid longs until it reclaims the 50.", ["lower-highs", "200dma"]),
            ("BEL", 188, 14, 5, .weekly, .bullish, "Breakout from a 6-month base on 2.5× average weekly volume. Strongest-looking chart on the list.", ["breakout", "volume"]),
            ("RELIANCE", 170, 11, 20, .daily, .bullish, "Closed above the range high with volume. Took a starter position.", ["breakout"]),
            ("INFY", 151, 20, 45, .daily, .bullish, "Bounce off the 200-DMA with a hammer. Small long, stop under the candle low.", ["200dma", "hammer"]),
            ("INFY", 128, 9, 50, .daily, .bearish, "Failed at the falling 50-DMA. Hammer setup didn't follow through — exited.", ["failed", "50dma"]),
            ("HDFCBANK", 112, 16, 0, .weekly, .bullish, "Weekly close above the range top. First higher high in months.", ["breakout"]),
            ("TMPV", 96, 12, 10, .daily, .bearish, "Rejected again at the 50-DMA. Pattern of lower highs intact.", ["lower-highs", "50dma"]),
            ("BEL", 82, 10, 25, .daily, .neutral, "Extended from the 20-DMA, pulling back on lower volume. Healthy so far.", ["pullback"]),
            ("RELIANCE", 61, 22, 5, .monthly, .bullish, "Monthly candle closing near the high. Trend intact; trailing stop to the 50-DMA.", ["trend"]),
            ("HDFCBANK", 44, 13, 35, .daily, .bearish, "Breakout failed back into the range. Watch the range low.", ["failed"]),
            ("BEL", 25, 15, 40, .daily, .bullish, "Second base forming above the first breakout level. Volume contraction.", ["base", "volume"]),
            ("TMPV", 12, 10, 15, .weekly, .neutral, "Selling slowing down near prior support. Not a buy yet — need a higher low.", ["support"]),
            ("RELIANCE", 4, 21, 30, .daily, .bullish, "Holding above the 20-DMA after a shakeout. Volume on up days > down days.", ["volume"])
        ]
        for (t, ago, h, m, tf, sent, text, tags) in notes {
            guard let id = ids[t] else { continue }
            let date = daysAgo(ago, h, m)
            data.observations.append(Observation(symbolID: id, date: date, timeframe: tf, sentiment: sent,
                                                 text: text, tags: tags, notedPrice: price(t, date),
                                                 createdAt: date, updatedAt: date))
        }

        let trades: [(String, TradeSide, Int, Double, String)] = [
            ("RELIANCE", .buy, 169, 20, "Starter on range breakout"),
            ("RELIANCE", .buy, 120, 15, "Added on retest"),
            ("BEL", .buy, 187, 100, "Base breakout"),
            ("INFY", .buy, 150, 10, "200-DMA bounce"),
            ("INFY", .sell, 127, 10, "Setup failed")
        ]
        for (t, side, ago, qty, note) in trades {
            guard let id = ids[t] else { continue }
            let date = daysAgo(ago, 10, 5)
            data.trades.append(Trade(symbolID: id, side: side, date: date, quantity: qty,
                                     price: price(t, date) ?? 100, note: note))
        }

        data.analyses.append(SavedAnalysis(kind: .patterns, symbolID: nil, text: """
        ## Recurring setups
        - **Base breakouts on volume** — BEL, RELIANCE, HDFCBANK. You mention volume in 6 of 15 notes.
        - **Moving-average tests** — 50/200-DMA bounces and rejections on INFY and TMPV.

        ## What worked
        - Weekly-chart breakouts with volume: 3 of 4 moved your way over 20 sessions.
        - Bearish "lower highs below the 50-DMA" calls on TMPV: 2 of 2 worked.

        ## What didn't
        - Daily hammer at the 200-DMA (INFY) failed within 20 sessions.

        ## Algo rule drafts
        1. Weekly close > 26-week high **and** weekly volume > 2× 20-week average → long; stop below the base low.
        2. Daily close < 50-DMA **and** three lower highs → no new longs.

        _Sample analysis generated for the screenshot — your own will come from Groq._
        """, model: AppSettings.defaultModel, createdAt: daysAgo(1, 20, 10)))

        data.chat = [
            ChatMessage(role: .user, content: "Where were my bearish calls wrong?", date: daysAgo(0, 9, 30)),
            ChatMessage(role: .assistant, content: """
            Of your **4 bearish notes**, one didn't work:
            - **HDFCBANK, \(Fmt.day.string(from: daysAgo(44, 13, 35)))** — you called the failed breakout, but price recovered within 20 sessions.

            The TMPV "lower highs below the 50-DMA" notes both played out. The INFY exit note was right to step aside.
            """, date: daysAgo(0, 9, 31))
        ]
        return DemoSet(data: data, series: series, featured: ids["RELIANCE"] ?? UUID())
    }
}

// MARK: - Runner

@MainActor
enum ScreenshotRunner {
    static func run() async {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("NSEObservations/screens", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let demo = DemoData.make()
        for (sym, s) in demo.series {
            await MarketDataService.shared.inject(sym, series: s)
        }
        let store = Store(fileURL: dir.appendingPathComponent("sample.json"), seed: demo.data)
        let settings = AppSettings()
        settings.hasKey = true
        let directory = SymbolDirectory()

        func env<V: View>(_ v: V) -> AnyView {
            AnyView(v.environmentObject(store).environmentObject(settings).environmentObject(directory))
        }

        let main = CGSize(width: 1360, height: 900)
        await snap(env(ContentView(initialSelection: .timeline)), size: main, name: "1-timeline", dir: dir)
        await snap(env(ContentView(initialSelection: .symbol(demo.featured))), size: CGSize(width: 1360, height: 1180),
                   name: "2-symbol", dir: dir)
        await snap(env(ContentView(initialSelection: .symbol(demo.featured))), size: CGSize(width: 1360, height: 1180),
                   name: "3-symbol-dark", dir: dir, dark: true)
        await snap(env(ContentView(initialSelection: .patterns)), size: main, name: "4-patterns", dir: dir)
        await snap(env(ContentView(initialSelection: .chat)), size: main, name: "5-chat", dir: dir)
        await snap(env(SymbolEditor(existing: nil, initialQuery: "tata")), size: CGSize(width: 520, height: 640),
                   name: "6-add-symbol", dir: dir)
        print("SCREENSHOTS_DIR=\(dir.path)")
    }

    private static func snap<V: View>(_ view: V, size: CGSize, name: String, dir: URL, dark: Bool = false) async {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrame(NSRect(origin: NSPoint(x: 40, y: 40), size: size), display: true)
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // let .task loaders and layout finish
        host.layoutSubtreeIfNeeded()
        host.display()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        window.orderOut(nil)
        window.close()
    }
}
