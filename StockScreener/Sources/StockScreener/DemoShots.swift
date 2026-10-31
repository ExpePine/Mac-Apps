import SwiftUI
import AppKit

// MARK: - Demo data + screenshots (for the feature slides)
//
// Run:  StockScreener --demo-screenshots /path/to/folder
// Fills the app with made-up stocks (fictional symbols, random-walk prices and delivery), opens each main screen
// in its own window, saves a PNG of it into the folder, then quits. Only used on the build machine — never on
// a normal launch.

enum DemoShots {
    static var outputFolder: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-screenshots"), i + 1 < a.count else { return nil }
        return URL(fileURLWithPath: a[i + 1], isDirectory: true)
    }
    static var active: Bool { outputFolder != nil }
    private static var started = false

    // MARK: Data

    struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    static let symbols = ["ZENTRAX", "KORVIA", "MERIDO", "SOLVANTA", "TERRANOVA", "QUILLON", "VIRESCO", "BRAVIK", "CORVUSIN", "DELTRIX",
                          "ELARION", "FALCORP", "GALVENT", "HELIXA", "IONARC", "JUNIPRA", "KESTRELX", "LUMORA", "MAGNIXA", "NOVARIS",
                          "ORBITEX", "PRAXILO", "QUANTOR", "RIVORA", "SAPHIRA", "TORRIXA", "ULTRAVO", "VANTIXA", "WESSELO", "XENORA"]
    static let sectors = ["Industrial Products", "Pharmaceuticals", "Auto Components", "IT Services", "Chemicals", "Capital Goods", "Textiles", "Finance"]

    static func weekdays(count: Int) -> [String] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        var d = Date(), out: [String] = []
        while out.count < count {
            let wd = cal.component(.weekday, from: d)
            if wd != 1 && wd != 7 { out.append(f.string(from: d)) }
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        return out.reversed()
    }

    @MainActor static func load(into vm: ScreenerViewModel) {
        var r = LCG(s: 42)
        let days = weekdays(count: 340)
        var book = PriceBook(); book.fetchedAt = Date()
        var deliveryByDay: [String: [DeliveryRow]] = [:]
        var lastChange: [String: Double] = [:]
        for (k, sym) in symbols.enumerated() {
            var p = 80 + r.next() * 900
            var s = PriceSeries(days: [], closes: [], opens: [], highs: [], lows: [])
            let baseQty = 20_000 + r.next() * 400_000
            for (i, d) in days.enumerated() {
                var ret = (r.next() - 0.48) * 0.04
                if i == days.count - 1 && k < 7 { ret = 0.05 + r.next() * 0.08 }         // today's gainers
                let o = p * (1 + (r.next() - 0.5) * 0.01)
                p = max(5, p * (1 + ret))
                let h = max(o, p) * (1 + r.next() * 0.015), l = min(o, p) * (1 - r.next() * 0.015)
                s.days.append(d); s.closes.append(p); s.opens!.append(o); s.highs!.append(h); s.lows!.append(l)
                let spike = r.next() < 0.02 || (i > days.count - 15 && k % 5 == 0 && r.next() < 0.3) ? 3 + r.next() * 4 : 1
                let dq = baseQty * (0.6 + r.next() * 0.8) * spike
                deliveryByDay[d, default: []].append(DeliveryRow(symbol: sym, series: "EQ", close: p, tradedQty: dq * 2, delivQty: dq, delivPer: 30 + r.next() * 40))
            }
            lastChange[sym] = (s.closes[s.closes.count - 1] / s.closes[s.closes.count - 2] - 1) * 100
            book.series[sym] = s
        }
        for idx in [ScreenerViewModel.benchmarkSymbol, ScreenerViewModel.sensexSymbol] {
            var p = idx == ScreenerViewModel.benchmarkSymbol ? 24_000.0 : 79_000.0
            var s = PriceSeries(days: [], closes: [])
            for d in days { p *= 1 + (r.next() - 0.48) * 0.012; s.days.append(d); s.closes.append(p) }
            book.series[idx] = s
        }
        for (d, rows) in deliveryByDay { try? DeliveryFiles.save(rows, day: d) }
        vm.priceBook = book

        let headers = ["Symbol", "Company", "Sector", "Close", "change%", "D_Trigger", "count", "compact", "MS", "DS", "Long_Green"]
        var rows: [SheetRow] = []
        for (i, sym) in symbols.enumerated() {
            let s = book.series[sym]!
            let trig = r.next() < 0.6 ? String(Int(r.next() * 40)) : ""
            let cells = [sym, sym.capitalized + " Ltd", sectors[i % sectors.count], String(format: "%.2f", s.closes.last!),
                         String(format: "%.2f", lastChange[sym] ?? 0), trig, String(Int(r.next() * 9)), r.next() < 0.4 ? "1" : "0",
                         String(format: "%.1f", r.next() * 100), String(format: "%.1f", r.next() * 100), r.next() < 0.5 ? "1" : "0"]
            rows.append(SheetRow(id: i, cells: cells, numbers: cells.map { NumberParser.parse($0) }))
        }
        vm.settings.labelColumn = "Symbol"
        vm.settings.triggerColumn = "D_Trigger"
        vm.applyDemoTable(SheetTable(headers: headers, rows: rows))
        DeliveryCenter.shared.reload()

        // a few alerts that "fired"
        let rule = UUID()
        vm.alertEvents = symbols.prefix(8).enumerated().map { i, s in
            AlertEvent(date: Date().addingTimeInterval(-Double(i) * 86_400), kind: .alert, ruleID: rule, ruleName: "D_Trigger → MS = 100",
                       stock: s, dataDay: days[days.count - 1 - i], values: ["MS: 100", "D_Trigger: \(i)"], conditions: "MS = 100")
        }
        // a multibagger note for the floating F box
        let e = MBEvent(symbol: "ZENTRAX", month: String(days[days.count - 60].prefix(7)), gain: 42, peakGain: 55,
                        baseDay: days[days.count - 62], startDay: days[days.count - 61], crossDay: days[days.count - 50],
                        peakDay: days[days.count - 45], endDay: days[days.count - 40])
        MBNoteStore.shared.set("count>5 + compact + D_TRIGGER wait, delivery spike before breakout", for: e)
        MBNoteFocus.shared.set(e)
    }

    // MARK: Screens

    static let screens: [(String, String)] = [
        ("01-filter", "Smart Filter"), ("02-gainers", "Daily Gainers"), ("03-delivery", "Delivery Signals"),
        ("04-studies", "Delivery Studies"), ("05-sectors", "Sector Rotation"), ("06-alerts", "Alerts Log"),
        ("07-notes", "Notes Autocomplete"), ("08-settings", "One Settings"), ("09-storage", "Data Storage"), ("10-import", "Data Import"),
    ]

    @MainActor static func view(_ id: String, _ vm: ScreenerViewModel) -> AnyView {
        switch id {
        case "01-filter": return AnyView(FilterView().environmentObject(vm))
        case "02-gainers": return AnyView(GainersView().environmentObject(vm))
        case "03-delivery": return AnyView(DeliveryView().environmentObject(vm))
        case "04-studies": return AnyView(PerformanceView().environmentObject(vm))
        case "05-sectors": return AnyView(SectorsView().environmentObject(vm))
        case "06-alerts": return AnyView(AlertsBrowserView().environmentObject(vm))
        case "07-notes": return AnyView(MBNoteView().environmentObject(vm))
        case "08-settings": return AnyView(SettingsHubView().environmentObject(vm))
        case "09-storage": return AnyView(StorageView())
        default: return AnyView(ImportView().environmentObject(vm))
        }
    }

    @MainActor static func run(_ vm: ScreenerViewModel) async {
        guard let out = outputFolder, !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        d.set(false, forKey: "live.enabled")
        d.set(2, forKey: "perfMode")
        d.set(true, forKey: "hub.indicators"); d.set(true, forKey: "hub.peek"); d.set(true, forKey: "hub.alerts")
        load(into: vm)
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        var log = ""
        for (id, title) in screens {
            let size = id == "07-notes" ? NSSize(width: 460, height: 260) : NSSize(width: 1440, height: 860)
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = title
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view(id, vm).frame(width: size.width, height: size.height))
            w.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: out.appendingPathComponent("\(id).png"))
                    log += "\(id)\t\(title)\tok\n"
                } else { log += "\(id)\t\(title)\tno png\n" }
            } else { log += "\(id)\t\(title)\tno view\n" }
            w.orderOut(nil)
        }
        try? log.write(to: out.appendingPathComponent("shots.tsv"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
