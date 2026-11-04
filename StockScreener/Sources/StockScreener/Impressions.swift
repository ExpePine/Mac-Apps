import SwiftUI
import AppKit
import Charts

// MARK: - Recording: every chart you look at, and for how long

/// One look at one stock's chart. Time counts only while the app is in front; one look is capped at 10 minutes
/// (a chart left open while you walk away shouldn't count as hours).
struct ChartImpression: Codable, Identifiable {
    var id = UUID()
    let symbol: String
    let start: Date
    let seconds: Double
    let place: String            // Chart viewer · Chart Reel · Gainer Charts · Peek
    let day: String              // yyyy-MM-dd (India)
}

@MainActor final class ImpressionStore: ObservableObject {
    static let shared = ImpressionStore()
    @Published private(set) var views: [ChartImpression] = []
    private var open: [String: (symbol: String, start: Date)] = [:]
    private var paused: [String: String] = [:]       // place → symbol, while the app is in the background
    private var saveWork: DispatchWorkItem?
    static let cap: Double = 600
    static let minSeconds: Double = 1

    private static var url: URL { AppFolders.base.appendingPathComponent("chart_impressions.json") }
    static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private init() {
        if let d = try? Data(contentsOf: Self.url), let v = try? JSONDecoder().decode([ChartImpression].self, from: d) { views = v }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseAll() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAll() }
        }
    }

    /// `symbol` is now on screen in `place` (ends whatever that place showed before).
    func begin(_ symbol: String, place: String) {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        if open[place]?.symbol == s { return }
        end(place)
        guard !s.isEmpty else { return }
        if NSApp.isActive { open[place] = (s, Date()) } else { paused[place] = s }
    }

    func end(_ place: String) {
        paused[place] = nil
        guard let o = open.removeValue(forKey: place) else { return }
        let secs = min(Self.cap, Date().timeIntervalSince(o.start))
        guard secs >= Self.minSeconds else { return }
        views.append(ChartImpression(symbol: o.symbol, start: o.start, seconds: secs, place: place, day: Self.dayFormat.string(from: o.start)))
        scheduleSave()
    }

    private func pauseAll() {
        for (place, o) in open { end(place); paused[place] = o.symbol }
    }
    private func resumeAll() {
        for (place, s) in paused { open[place] = (s, Date()) }
        paused = [:]
    }

    func clear() { views = []; scheduleSave() }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }
    func flush() {
        if let d = try? JSONEncoder().encode(views) { try? d.write(to: Self.url, options: .atomic) }
    }
}

// MARK: - Report

struct ImpressionReport {
    struct Stock: Identifiable {
        let symbol: String
        var views = 0, seconds = 0.0
        var days = Set<String>()
        var first = "", last = ""
        var places = Set<String>()
        var dayMove: Double?          // average % change on the days you looked
        var gainerDays = 0, loserDays = 0
        var fwd5: Double?, fwd22: Double? // after the first look
        var id: String { symbol }
        var avg: Double { views == 0 ? 0 : seconds / Double(views) }
    }
    struct Period: Identifiable {
        let key: String               // day or month
        var views = 0, seconds = 0.0
        var stocks = Set<String>()
        var marketGainers = 0, gainersSeen = 0, gainersSeenBefore = 0
        var marketLosers = 0, losersSeen = 0
        var seenFwd5: [Double] = []   // next-5-day returns of what you looked at
        var allFwd5: [Double] = []    // … of every stock (base)
        var id: String { key }
        var coverage: Double? { marketGainers == 0 ? nil : Double(gainersSeen) / Double(marketGainers) * 100 }
        var anticipation: Double? { marketGainers == 0 ? nil : Double(gainersSeenBefore) / Double(marketGainers) * 100 }
        var edge: Double? {
            guard let a = WatchSummary.mean(seenFwd5), let b = WatchSummary.mean(allFwd5) else { return nil }
            return a - b
        }
    }
    struct Bucket: Identifiable {
        let id: String; let order: Int
        var n = 0; var fwd: [Double] = []
        var avg: Double? { WatchSummary.mean(fwd) }
        var up: Double? { fwd.isEmpty ? nil : Double(fwd.filter { $0 > 0 }.count) / Double(fwd.count) * 100 }
    }

    var views = 0, seconds = 0.0
    var stocks: [Stock] = []
    var periods: [Period] = []
    var buckets: [Bucket] = []
    // view-day mix vs the market
    var lookedPairs = 0, lookedGainers = 0, lookedLosers = 0
    var marketGainerShare: Double?, marketLoserShare: Double?
    var spearman: Double?             // time spent vs next-5-day return, per stock-day
    var spearmanN = 0

    static func build(_ all: [ChartImpression], book: PriceBook, threshold: Double, monthly: Bool) -> ImpressionReport {
        var r = ImpressionReport()
        r.views = all.count
        r.seconds = all.reduce(0) { $0 + $1.seconds }
        let series = book.series.filter { !$0.key.hasPrefix("^") }

        func move(_ s: String, _ d: String) -> Double? { book.series(for: s)?.dailyChange(on: d) }
        func fwd(_ s: PriceSeries?, _ d: String, _ k: Int) -> Double? {
            guard let s, let i = s.index(onOrBefore: d), i + k < s.closes.count, s.closes[i] > 0 else { return nil }
            return (s.closes[i + k] / s.closes[i] - 1) * 100
        }

        // per stock
        var by: [String: Stock] = [:]
        for v in all {
            var st = by[v.symbol] ?? Stock(symbol: v.symbol)
            st.views += 1; st.seconds += v.seconds; st.days.insert(v.day); st.places.insert(v.place)
            if st.first.isEmpty || v.day < st.first { st.first = v.day }
            if v.day > st.last { st.last = v.day }
            by[v.symbol] = st
        }
        for (k, var st) in by {
            let moves = st.days.compactMap { move(k, $0) }
            st.dayMove = WatchSummary.mean(moves)
            st.gainerDays = moves.filter { $0 >= threshold }.count
            st.loserDays = moves.filter { $0 <= -threshold }.count
            let s = book.series(for: k)
            st.fwd5 = fwd(s, st.first, 5); st.fwd22 = fwd(s, st.first, 22)
            by[k] = st
        }
        r.stocks = by.values.sorted { $0.seconds > $1.seconds }

        // stock-days: time spent and what happened next
        var pairTime: [String: Double] = [:]          // "SYM|day"
        for v in all { pairTime[v.symbol + "|" + v.day, default: 0] += v.seconds }
        var xs: [Double] = [], ys: [Double] = []
        var bk: [Bucket] = [Bucket(id: "under 10 s", order: 0), Bucket(id: "10 s – 1 min", order: 1), Bucket(id: "1 – 5 min", order: 2), Bucket(id: "over 5 min", order: 3)]
        for (key, t) in pairTime {
            let p = key.split(separator: "|").map(String.init)
            guard p.count == 2 else { continue }
            r.lookedPairs += 1
            if let m = move(p[0], p[1]) { if m >= threshold { r.lookedGainers += 1 } else if m <= -threshold { r.lookedLosers += 1 } }
            let k = t < 10 ? 0 : t < 60 ? 1 : t < 300 ? 2 : 3
            bk[k].n += 1
            if let f = fwd(book.series(for: p[0]), p[1], 5) { bk[k].fwd.append(f); xs.append(t); ys.append(f) }
        }
        r.buckets = bk
        r.spearmanN = xs.count
        r.spearman = xs.count >= 8 ? Self.spearman(xs, ys) : nil

        // market per day
        let days = Set(all.map(\.day))
        var dayStats: [String: (g: Set<String>, l: Set<String>, total: Int, fwd: [Double])] = [:]
        for d in days {
            var g = Set<String>(), l = Set<String>(), total = 0, f: [Double] = []
            for (sym, s) in series {
                guard let m = s.dailyChange(on: d) else { continue }
                total += 1
                if m >= threshold { g.insert(sym) } else if m <= -threshold { l.insert(sym) }
                if let x = fwd(s, d, 5) { f.append(x) }
            }
            dayStats[d] = (g, l, total, f)
        }
        let totals = dayStats.values.reduce((0, 0, 0)) { ($0.0 + $1.g.count, $0.1 + $1.l.count, $0.2 + $1.total) }
        if totals.2 > 0 { r.marketGainerShare = Double(totals.0) / Double(totals.2) * 100; r.marketLoserShare = Double(totals.1) / Double(totals.2) * 100 }

        // periods (day or month)
        let viewedOn = Dictionary(grouping: all, by: \.day).mapValues { Set($0.map(\.symbol)) }
        let sortedDays = days.sorted()
        var per: [String: Period] = [:]
        for v in all {
            let key = monthly ? String(v.day.prefix(7)) : v.day
            var p = per[key] ?? Period(key: key)
            p.views += 1; p.seconds += v.seconds; p.stocks.insert(v.symbol)
            per[key] = p
        }
        for (i, d) in sortedDays.enumerated() {
            guard let ds = dayStats[d] else { continue }
            let key = monthly ? String(d.prefix(7)) : d
            var p = per[key] ?? Period(key: key)
            let seen = viewedOn[d] ?? []
            // looked at in the 5 days you used the app before this day
            let before = sortedDays[max(0, i - 5)..<i].reduce(into: Set<String>()) { $0.formUnion(viewedOn[$1] ?? []) }
            p.marketGainers += ds.g.count
            p.gainersSeen += ds.g.intersection(seen).count
            p.gainersSeenBefore += ds.g.intersection(before).count
            p.marketLosers += ds.l.count
            p.losersSeen += ds.l.intersection(seen).count
            p.seenFwd5 += seen.compactMap { fwd(book.series(for: $0), d, 5) }
            p.allFwd5 += ds.fwd
            per[key] = p
        }
        r.periods = per.values.sorted { $0.key > $1.key }
        return r
    }

    /// Rank correlation (−1…1).
    static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        func ranks(_ v: [Double]) -> [Double] {
            let idx = v.indices.sorted { v[$0] < v[$1] }
            var r = [Double](repeating: 0, count: v.count)
            var k = 0
            while k < idx.count {
                var j = k
                while j + 1 < idx.count && v[idx[j + 1]] == v[idx[k]] { j += 1 }
                let avg = Double(k + j) / 2 + 1
                for m in k...j { r[idx[m]] = avg }
                k = j + 1
            }
            return r
        }
        let a = ranks(x), b = ranks(y), n = Double(x.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
        return da == 0 || db == 0 ? nil : num / (da * db).squareRoot()
    }
}

// MARK: - Window

struct ImpressionsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var store = ImpressionStore.shared
    @AppStorage("imp.range") private var range = "30 days"
    @AppStorage("imp.monthly") private var monthly = false
    @AppStorage("imp.place") private var place = "All"
    @AppStorage("imp.sort") private var sort = "Time"
    @State private var report: ImpressionReport?
    @State private var busy = false
    @State private var search = ""

    private static let places = ["All", "Chart viewer", "Chart Reel", "Gainer Charts", "Peek"]

    private var picked: [ChartImpression] {
        let today = ImpressionStore.dayFormat.string(from: Date())
        let cal = Calendar.current
        func daysAgo(_ n: Int) -> String { ImpressionStore.dayFormat.string(from: cal.date(byAdding: .day, value: -n, to: Date()) ?? Date()) }
        let from: String
        switch range {
        case "Today": from = today
        case "7 days": from = daysAgo(6)
        case "30 days": from = daysAgo(29)
        case "This month": from = String(today.prefix(7)) + "-01"
        case "90 days": from = daysAgo(89)
        default: from = ""
        }
        return store.views.filter { $0.day >= from && (place == "All" || $0.place == place) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 10, lineSpacing: 6) {
                Text("Chart impressions").font(.title2.bold())
                Picker("", selection: $range) { ForEach(["Today", "7 days", "30 days", "This month", "90 days", "All"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("", selection: $monthly) { Text("Daily").tag(false); Text("Monthly").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("Where", selection: $place) { ForEach(Self.places, id: \.self) { Text($0).tag($0) } }.fixedSize()
                if busy { ProgressView().controlSize(.small) }
                Menu {
                    Button("Export CSV…") { export() }
                    Divider()
                    Button("Clear all impressions…", role: .destructive) {
                        let a = NSAlert(); a.messageText = "Delete every recorded chart view?"; a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
                        if a.runModal() == .alertFirstButtonReturn { store.clear() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(10)
            Divider()
            if let r = report, r.views > 0 { content(r) }
            else if busy { ProgressView("Working it out…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                Text(store.views.isEmpty
                     ? "Nothing recorded yet. From now on every chart you open — Chart viewer, Chart Reel, Gainer Charts and chart peeks — is counted here with the time you spend on it."
                     : "No chart views in this period.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(range)|\(monthly)|\(place)|\(store.views.count / 5)|\(vm.priceBook.series.count)|\(vm.settings.gainersThreshold)") { await recompute() }
    }

    private func recompute() async {
        busy = true
        let v = picked, book = vm.priceBook, th = vm.settings.gainersThreshold, m = monthly
        report = await Task.detached(priority: .userInitiated) { ImpressionReport.build(v, book: book, threshold: th, monthly: m) }.value
        busy = false
    }

    // MARK: Content

    private func content(_ r: ImpressionReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FlowLayout(spacing: 24, lineSpacing: 8) {
                    tile("Charts viewed", "\(r.views)", .primary)
                    tile("Different stocks", "\(r.stocks.count)", .primary)
                    tile("Time on charts", Self.dur(r.seconds), .primary)
                    tile("Average look", Self.dur(r.views == 0 ? 0 : r.seconds / Double(r.views)), .primary)
                    if let top = r.stocks.max(by: { $0.views < $1.views }) { tile("Viewed most", "\(top.symbol) · \(top.views)×", .blue) }
                    if let long = r.stocks.first { tile("Most time on", "\(long.symbol) · \(Self.dur(long.seconds))", .blue) }
                }

                GroupBox(monthly ? "Per month" : "Per day") {
                    let ps = r.periods.sorted { $0.key < $1.key }
                    Chart(ps) { p in
                        BarMark(x: .value("When", label(p.key)), y: .value("Charts", p.views)).foregroundStyle(Color.blue.opacity(0.7))
                    }
                    .frame(height: 140)
                    Chart(ps) { p in
                        BarMark(x: .value("When", label(p.key)), y: .value("Minutes", p.seconds / 60)).foregroundStyle(Color.purple.opacity(0.6))
                    }
                    .frame(height: 100)
                    Text("Top: charts viewed · bottom: minutes spent").font(.caption2).foregroundStyle(.secondary)
                }

                correlations(r)
                periodTable(r)
                stockTable(r)

                Text("Time counts only while the app is in front, and one look is capped at 10 minutes. Gainer / loser = up / down at least \(CombiEngine.fmt(vm.settings.gainersThreshold))% on the day (your Daily Gainers level), from Yahoo daily closes (unofficial). Correlation is not cause. Not financial advice.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private func label(_ key: String) -> String { monthly ? MBEngine.monthTitle(key) : String(key.dropFirst(5)) }

    // MARK: Correlations

    private func correlations(_ r: ImpressionReport) -> some View {
        let lookedG = r.lookedPairs == 0 ? nil : Double(r.lookedGainers) / Double(r.lookedPairs) * 100
        let lookedL = r.lookedPairs == 0 ? nil : Double(r.lookedLosers) / Double(r.lookedPairs) * 100
        let totalG = r.periods.reduce(0) { $0 + $1.marketGainers }
        let seenG = r.periods.reduce(0) { $0 + $1.gainersSeen }
        let beforeG = r.periods.reduce(0) { $0 + $1.gainersSeenBefore }
        let totalL = r.periods.reduce(0) { $0 + $1.marketLosers }
        let seenL = r.periods.reduce(0) { $0 + $1.losersSeen }
        let seenF = r.periods.flatMap(\.seenFwd5), allF = r.periods.flatMap(\.allFwd5)
        let edge = WatchSummary.mean(seenF).flatMap { a in WatchSummary.mean(allF).map { a - $0 } }
        return GroupBox("Gainers, losers and what you look at") {
            VStack(alignment: .leading, spacing: 12) {
                FlowLayout(spacing: 24, lineSpacing: 8) {
                    tile("Stocks you looked at that were gainers that day", pct0(lookedG), .green,
                         "market: \(pct0(r.marketGainerShare)) of all stocks")
                    tile("… that were losers that day", pct0(lookedL), .red, "market: \(pct0(r.marketLoserShare))")
                    tile("Day's gainers you looked at", totalG == 0 ? "—" : "\(seenG) of \(totalG)", .green,
                         totalG == 0 ? nil : pct0(Double(seenG) / Double(totalG) * 100) + " coverage")
                    tile("Gainers you'd looked at in the 5 days before", totalG == 0 ? "—" : "\(beforeG) of \(totalG)", .blue,
                         "spotted before the move")
                    tile("Day's losers you looked at", totalL == 0 ? "—" : "\(seenL) of \(totalL)", .red)
                    tile("Next 5 days: your charts vs the market", edge.map { String(format: "%+.2f pts", $0) } ?? "—", (edge ?? 0) >= 0 ? .green : .red,
                         "yours \(pctS(WatchSummary.mean(seenF))) · all \(pctS(WatchSummary.mean(allF)))")
                }
                Divider()
                Text("Does more time on a chart mean a better pick?").font(.headline)
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 5) {
                    GridRow {
                        Text("Time on a stock that day").gridColumnAlignment(.leading); Text("Stock-days"); Text("Next 5 days (avg)"); Text("Went up")
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(r.buckets) { b in
                        GridRow {
                            Text(b.id).gridColumnAlignment(.leading)
                            Text("\(b.n)").monospacedDigit()
                            Text(pctS(b.avg)).foregroundStyle((b.avg ?? 0) >= 0 ? .green : .red).monospacedDigit()
                            Text(pct0(b.up)).monospacedDigit()
                        }
                    }
                }
                Text(spearmanText(r)).font(.callout).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private func spearmanText(_ r: ImpressionReport) -> String {
        guard let s = r.spearman else { return "Not enough stock-days with 5 days of prices after them yet for a correlation (need 8, have \(r.spearmanN))." }
        let strength = abs(s) < 0.1 ? "no real link" : abs(s) < 0.3 ? "a weak link" : abs(s) < 0.5 ? "a moderate link" : "a strong link"
        return String(format: "Rank correlation between time spent and the next 5 days' return: %+.2f over %d stock-days — %@%@.", s, r.spearmanN, strength,
                      abs(s) < 0.1 ? "" : (s > 0 ? " (more time → better afterwards)" : " (more time → worse afterwards)"))
    }

    // MARK: Tables

    private func periodTable(_ r: ImpressionReport) -> some View {
        GroupBox(monthly ? "Month by month" : "Day by day") {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text(monthly ? "Month" : "Day").gridColumnAlignment(.leading); Text("Charts"); Text("Stocks"); Text("Time")
                    Text("Market gainers"); Text("You saw"); Text("Seen before"); Text("Market losers"); Text("You saw"); Text("Your next 5d vs all")
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(r.periods) { p in
                    GridRow {
                        Text(monthly ? MBEngine.monthTitle(p.key) : p.key).gridColumnAlignment(.leading)
                        Text("\(p.views)"); Text("\(p.stocks.count)"); Text(Self.dur(p.seconds))
                        Text("\(p.marketGainers)")
                        Text("\(p.gainersSeen)" + (p.coverage.map { String(format: " (%.0f%%)", $0) } ?? "")).foregroundStyle(.green)
                        Text("\(p.gainersSeenBefore)").foregroundStyle(.blue)
                        Text("\(p.marketLosers)")
                        Text("\(p.losersSeen)").foregroundStyle(.red)
                        Text(p.edge.map { String(format: "%+.2f", $0) } ?? "—").foregroundStyle((p.edge ?? 0) >= 0 ? .green : .red)
                    }
                    .monospacedDigit()
                }
            }
            .padding(6)
        }
    }

    private func stockTable(_ r: ImpressionReport) -> some View {
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        var rows = r.stocks.filter { q.isEmpty || $0.symbol.contains(q) }
        switch sort {
        case "Views": rows.sort { $0.views > $1.views }
        case "Avg look": rows.sort { $0.avg > $1.avg }
        case "Day move": rows.sort { ($0.dayMove ?? -999) > ($1.dayMove ?? -999) }
        case "+22d": rows.sort { ($0.fwd22 ?? -999) > ($1.fwd22 ?? -999) }
        default: rows.sort { $0.seconds > $1.seconds }
        }
        return GroupBox {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Symbol").gridColumnAlignment(.leading); Text("Views"); Text("Time"); Text("Avg look"); Text("Days")
                    Text("Move on days viewed"); Text("Gainer / loser days"); Text("+5d after 1st look"); Text("+22d"); Text("First"); Text("Last")
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(rows.prefix(300)) { s in
                    GridRow {
                        HStack(spacing: 4) {
                            Text(s.symbol).fontWeight(.medium)
                            AddToWatchlistButton(symbol: s.symbol, source: "Impressions")
                        }
                        .gridColumnAlignment(.leading)
                        .onTapGesture(count: 2) { vm.openChart(s.symbol, queue: rows.map(\.symbol), openWindow: openWindow) }
                        Text("\(s.views)"); Text(Self.dur(s.seconds)); Text(Self.dur(s.avg)); Text("\(s.days.count)")
                        Text(pctS(s.dayMove)).foregroundStyle((s.dayMove ?? 0) >= 0 ? .green : .red)
                        Text("\(s.gainerDays) / \(s.loserDays)")
                        Text(pctS(s.fwd5)).foregroundStyle((s.fwd5 ?? 0) >= 0 ? .green : .red)
                        Text(pctS(s.fwd22)).foregroundStyle((s.fwd22 ?? 0) >= 0 ? .green : .red)
                        Text(s.first).foregroundStyle(.secondary); Text(s.last).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }
            .padding(6)
            if rows.count > 300 { Text("Showing the first 300 of \(rows.count).").font(.caption2).foregroundStyle(.secondary) }
        } label: {
            HStack {
                Text("By stock")
                Picker("Sort", selection: $sort) { ForEach(["Time", "Views", "Avg look", "Day move", "+22d"], id: \.self) { Text($0).tag($0) } }.fixedSize()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 120)
                Text("double-click a symbol for its chart").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func tile(_ t: String, _ v: String, _ c: Color, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 220, alignment: .leading)
            Text(v).font(.title3.bold().monospacedDigit()).foregroundStyle(c)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func pctS(_ v: Double?) -> String { v.map { String(format: "%+.2f%%", $0) } ?? "—" }
    private func pct0(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "—" }
    static func dur(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t >= 3600 { return String(format: "%dh %02dm", t / 3600, t % 3600 / 60) }
        if t >= 60 { return String(format: "%dm %02ds", t / 60, t % 60) }
        return "\(t)s"
    }

    private func export() {
        let p = NSSavePanel(); p.nameFieldStringValue = "chart-impressions.csv"; p.allowedContentTypes = [.commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url else { return }
        let iso = ISO8601DateFormatter()
        let lines = ["symbol,day,start,seconds,place"] + picked.map { "\($0.symbol),\($0.day),\(iso.string(from: $0.start)),\(Int($0.seconds)),\($0.place)" }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
