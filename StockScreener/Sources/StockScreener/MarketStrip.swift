import SwiftUI
import Charts

// MARK: - Global markets strip (Daily Gainers)
//
// Crude, gold, the dollar, US / Asian indices, India VIX … from Yahoo's chart endpoint (unofficial), refreshed
// every minute while Daily Gainers is open. The list is editable (any Yahoo ticker).

struct MarketItem: Codable, Identifiable, Hashable {
    var id: String { ticker }
    var name: String
    var ticker: String          // Yahoo ticker, e.g. BZ=F, GC=F, ^GSPC, INR=X
    var unit = ""               // shown after the price ("$", "₹", "%")
}

enum MarketList {
    static let key = "markets.items"
    static let defaults: [MarketItem] = [
        MarketItem(name: "Brent crude", ticker: "BZ=F", unit: "$"),
        MarketItem(name: "WTI crude", ticker: "CL=F", unit: "$"),
        MarketItem(name: "Gold", ticker: "GC=F", unit: "$"),
        MarketItem(name: "Silver", ticker: "SI=F", unit: "$"),
        MarketItem(name: "USD / INR", ticker: "INR=X", unit: "₹"),
        MarketItem(name: "Dollar index", ticker: "DX-Y.NYB"),
        MarketItem(name: "US 10Y yield", ticker: "^TNX", unit: "%"),
        MarketItem(name: "S&P 500", ticker: "^GSPC"),
        MarketItem(name: "Dow Jones", ticker: "^DJI"),
        MarketItem(name: "Nasdaq", ticker: "^IXIC"),
        MarketItem(name: "NYSE Composite", ticker: "^NYA"),
        MarketItem(name: "India VIX", ticker: "^INDIAVIX"),
        MarketItem(name: "Bank Nifty", ticker: "^NSEBANK"),
        MarketItem(name: "Nikkei 225", ticker: "^N225"),
        MarketItem(name: "Hang Seng", ticker: "^HSI"),
        MarketItem(name: "Natural gas", ticker: "NG=F", unit: "$"),
        MarketItem(name: "Copper", ticker: "HG=F", unit: "$"),
        MarketItem(name: "Bitcoin", ticker: "BTC-USD", unit: "$"),
    ]
    static var items: [MarketItem] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([MarketItem].self, from: d), !l.isEmpty else { return defaults }
            return l
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

@MainActor final class MarketCenter: ObservableObject {
    static let shared = MarketCenter()
    @Published private(set) var data: [String: IntradaySeries] = [:]
    @Published private(set) var failed: Set<String> = []
    @Published private(set) var updatedAt: Date?
    private var busy = false

    func refresh(_ items: [MarketItem]) async {
        guard !busy else { return }
        busy = true
        let results = await withTaskGroup(of: (String, IntradaySeries?).self) { g -> [(String, IntradaySeries?)] in
            for it in items { g.addTask { (it.ticker, try? await YahooClient.intraday(it.ticker, interval: "5m")) } }
            var out: [(String, IntradaySeries?)] = []
            for await r in g { out.append(r) }
            return out
        }
        var d = data, f = Set<String>()
        for (t, s) in results { if let s, !s.closes.isEmpty { d[t] = s } else { f.insert(t) } }
        data = d; failed = f; updatedAt = Date(); busy = false
    }
}

struct MarketStrip: View {
    @ObservedObject private var mc = MarketCenter.shared
    @AppStorage(MarketList.key) private var itemsData = Data()
    @AppStorage("markets.show") private var show = true
    @State private var editing = false

    private var items: [MarketItem] { _ = itemsData; return MarketList.items }

    var body: some View {
        HStack(spacing: 6) {
            Button { show.toggle() } label: { Image(systemName: show ? "globe.asia.australia.fill" : "globe.asia.australia") }
                .buttonStyle(.borderless).help(show ? "Hide the global markets strip" : "Show global markets")
            if show {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(items) { chip($0) } }
                }
                Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless)
                    .help("Choose the markets shown (any Yahoo ticker)")
                    .popover(isPresented: $editing, arrowEdge: .bottom) { MarketListEditor() }
            } else {
                Text("Global markets").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .task(id: itemsData) {
            while !Task.isCancelled {
                if show { await mc.refresh(items) }
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)          // every minute while open
            }
        }
    }

    private func chip(_ it: MarketItem) -> some View {
        let s = mc.data[it.ticker]
        let ch = s?.change
        let up = (ch ?? 0) >= 0
        let color: Color = ch == nil ? .secondary : (up ? .green : .red)
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(it.name).font(.caption2.bold()).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(s?.last.map { price($0, it) } ?? (mc.failed.contains(it.ticker) ? "n/a" : "…")).font(.caption.monospacedDigit().bold())
                    if let ch { Text(String(format: "%+.2f%%", ch)).font(.caption2.monospacedDigit().bold()).foregroundStyle(color) }
                }
            }
            if let s, s.closes.count > 2 {
                Chart {
                    ForEach(Array(s.closes.enumerated()), id: \.offset) { p in
                        LineMark(x: .value("t", p.offset), y: .value("v", p.element)).foregroundStyle(color)
                    }
                    if let pc = s.previousClose { RuleMark(y: .value("prev", pc)).foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2])) }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(width: 46, height: 22)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(ch == nil ? 0.06 : 0.1)))
        .help(tip(it, s))
    }

    private func price(_ v: Double, _ it: MarketItem) -> String {
        let f = v >= 1000 ? "%.0f" : (v >= 10 ? "%.2f" : "%.3f")
        let n = String(format: f, v)
        switch it.unit {
        case "$": return "$" + n
        case "₹": return "₹" + n
        case "%": return n + "%"
        default: return n
        }
    }

    private func tip(_ it: MarketItem, _ s: IntradaySeries?) -> String {
        var t = "\(it.name) (\(it.ticker))"
        if let s, let last = s.times.last {
            t += "\nLast: \(last.formatted(date: .abbreviated, time: .shortened))"
            if let p = s.previousClose { t += "\nPrevious close: \(String(format: "%.2f", p))" }
            if Date().timeIntervalSince(last) > 3600 { t += "\nMarket closed now — showing its last session" }
        } else if mc.failed.contains(it.ticker) { t += "\nYahoo returned nothing for this ticker" }
        return t + "\nSource: Yahoo Finance (may be delayed)"
    }
}

/// Edit the strip: name + Yahoo ticker, reorder, add, remove, reset.
struct MarketListEditor: View {
    @State private var rows: [MarketItem] = MarketList.items
    @State private var name = ""
    @State private var ticker = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Global markets").font(.headline)
            Text("Any Yahoo Finance ticker: futures end in =F (BZ=F), indices start with ^ (^GSPC), currencies end in =X (INR=X).")
                .font(.caption).foregroundStyle(.secondary).frame(width: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(rows) { r in
                    HStack {
                        Text(r.name); Spacer(); Text(r.ticker).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button { rows.removeAll { $0 == r } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(width: 380, height: 300)
            HStack {
                TextField("Name", text: $name).frame(width: 140)
                TextField("Ticker", text: $ticker).frame(width: 110)
                Button("Add") {
                    let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()
                    guard !t.isEmpty, !rows.contains(where: { $0.ticker == t }) else { return }
                    rows.append(MarketItem(name: name.isEmpty ? t : name, ticker: t)); name = ""; ticker = ""
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Reset") { rows = MarketList.defaults }
                Spacer()
                Button("Save") { MarketList.items = rows }.keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(12)
    }
}
