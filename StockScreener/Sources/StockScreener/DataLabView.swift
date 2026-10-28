import SwiftUI
import Charts

// MARK: - Data Lab: downloads + runs

@MainActor final class DataLabCenter: ObservableObject {
    static let shared = DataLabCenter()
    @Published private(set) var busy = false
    @Published var status: String?
    @Published private(set) var progress: (Int, Int) = (0, 0)
    @Published private(set) var result: LabResult? = DataLabCenter.loadResult()
    @Published private(set) var log: [LabPrediction] = DataLabCenter.loadLog()

    static let universes = ["My Filter stocks", "Sheet stocks", "Today's gainers"]
    static var universe: String { UserDefaults.standard.string(forKey: "lab.universe") ?? universes[0] }
    static var with1m: Bool { UserDefaults.standard.object(forKey: "lab.1m") as? Bool ?? true }
    static var max1m: Int { let v = UserDefaults.standard.integer(forKey: "lab.max1m"); return v > 0 ? v : 300 }
    static let index = "^NSEI"

    private static var resultURL: URL { AppFolders.folder("datalab").appendingPathComponent("tomorrow.json.lzfse") }
    private static var logURL: URL { AppFolders.folder("datalab").appendingPathComponent("prediction_log.json.lzfse") }

    private static func loadZ<T: Decodable>(_ u: URL, _ t: T.Type) -> T? {
        guard let d = try? Data(contentsOf: u), let raw = try? (d as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: raw)
    }
    private static func saveZ<T: Encodable>(_ v: T, _ u: URL) {
        guard let raw = try? JSONEncoder().encode(v), let c = try? (raw as NSData).compressed(using: .lzfse) as Data else { return }
        try? c.write(to: u, options: .atomic)
    }
    private static func loadResult() -> LabResult? { loadZ(resultURL, LabResult.self) }
    private static func loadLog() -> [LabPrediction] { loadZ(logURL, [LabPrediction].self) ?? [] }

    func symbols(_ vm: ScreenerViewModel) -> [String] {
        guard let l = vm.labelIndex else { return [] }
        func sym(_ r: SheetRow) -> String { r.text(l).trimmingCharacters(in: .whitespaces).uppercased() }
        switch Self.universe {
        case "Sheet stocks": return vm.allSymbols.map { $0.uppercased() }
        case "Today's gainers": return vm.gainers(on: vm.currentGainerDay).map(\.symbol)
        default: return vm.filterRows.map(sym)
        }
    }

    /// Downloads / tops up 5-minute (and 1-minute) OHLCV for the universe + NIFTY.
    func update(_ vm: ScreenerViewModel) {
        guard !busy else { return }
        let list = Array(Set(symbols(vm).filter { !$0.isEmpty })).sorted()
        guard !list.isEmpty else { status = "No stocks in “\(Self.universe)” — pick another universe."; return }
        let with1m = Self.with1m
        let oneMin = Set(list.prefix(Self.max1m))
        busy = true
        let all = [Self.index] + list
        progress = (0, all.count)
        Task {
            var done = 0, failed = 0, i = 0
            while i < all.count {
                let batch = Array(all[i..<min(i + 6, all.count)]); i += batch.count
                let ok = await withTaskGroup(of: Bool.self) { g -> Int in
                    for s in batch {
                        g.addTask {
                            var good = false
                            let old5 = LabFiles.load(s, "5m")
                            let fresh5 = old5?.t.last.map { Date().timeIntervalSince1970 - Double($0) < 4 * 86_400 } ?? false
                            if let got = try? await YahooClient.ohlcv(s, interval: "5m", range: fresh5 ? "5d" : "60d") {
                                var b = old5 ?? OHLCV(); b.merge(got); b.keepLast(calendarDays: 900); LabFiles.save(s, "5m", b); good = true
                            }
                            if with1m && (oneMin.contains(s) || s == DataLabCenter.index) {
                                let old1 = LabFiles.load(s, "1m")
                                let fresh1 = old1?.t.last.map { Date().timeIntervalSince1970 - Double($0) < 4 * 86_400 } ?? false
                                if let got = try? await YahooClient.ohlcv(s, interval: "1m", range: fresh1 ? "5d" : "7d") {
                                    var b = old1 ?? OHLCV(); b.merge(got); b.keepLast(calendarDays: 120); LabFiles.save(s, "1m", b)
                                }
                            }
                            return good
                        }
                    }
                    var n = 0
                    for await r in g where r { n += 1 }
                    return n
                }
                done += batch.count; failed += batch.count - ok
                progress = (done, all.count)
                status = "Downloading candles \(done)/\(all.count)…"
            }
            busy = false
            status = failed > all.count / 3 ? "\(failed) of \(all.count) failed on Yahoo (rate limit?) — try again later." : "Candles up to date for \(all.count - failed) symbols."
            UserDefaults.standard.set(AlertSchedule.today(), forKey: "lab.updated")
        }
    }

    /// Builds samples from stored candles and runs the tomorrow's-candle models.
    func run(_ vm: ScreenerViewModel) {
        guard !busy else { return }
        let list = Array(Set(symbols(vm).filter { !$0.isEmpty }))
        guard !list.isEmpty else { status = "No stocks in “\(Self.universe)”."; return }
        busy = true
        status = "Building features from stored candles…"
        let oldLog = log
        Task {
            let res = await Task.detached(priority: .userInitiated) { () -> LabResult in
                let market = LabBuild.marketReturns(LabFiles.load(DataLabCenter.index, "5m"))
                var all: [LabSample] = []
                for s in list {
                    guard let m5 = LabFiles.load(s, "5m") else { continue }
                    all += LabBuild.samples(s, m5: m5, m1: LabFiles.load(s, "1m"), market: market)
                }
                return LabEngine.run(all) { msg in Task { @MainActor in DataLabCenter.shared.status = msg } }
            }.value
            busy = false
            if res.predictions.isEmpty {
                status = "Not enough candles yet — needs at least 8 days of 5-minute data for a few dozen stocks. Press Update candles first."
                return
            }
            result = res
            Self.saveZ(res, Self.resultURL)
            // keep a log of what was predicted, to check against what happened
            var lg = oldLog.filter { $0.asOf != res.asOf }
            lg += res.predictions
            let days = Array(Set(lg.map(\.asOf))).sorted().suffix(60)
            lg = lg.filter { days.contains($0.asOf) }
            log = lg
            Self.saveZ(lg, Self.logURL)
            status = "Predicted \(res.predictions.count) stocks for the day after \(res.asOf)."
        }
    }

    /// Past predictions whose next day is now in the stored candles: (direction hits, total, average |close error|).
    func trackRecord() -> (hit: Int, n: Int, mae: Double, inBand: Int) {
        var hit = 0, n = 0, inBand = 0, err = 0.0
        var cache: [String: [OHLCV.Day]] = [:]
        for p in log {
            let days = cache[p.sym] ?? (LabFiles.load(p.sym, "5m")?.days() ?? [])
            cache[p.sym] = days
            guard let i = days.firstIndex(where: { $0.day == p.asOf }), i + 1 < days.count, days[i].c > 0 else { continue }
            let actual = Double(days[i + 1].c / days[i].c - 1)
            n += 1
            if (p.pUp >= 0.5) == (actual > 0) { hit += 1 }
            err += abs(actual - p.point[3])
            if abs(actual - p.point[3]) <= p.band[3] { inBand += 1 }
        }
        return (hit, n, n > 0 ? err / Double(n) : 0, inBand)
    }
}

// MARK: - Window

struct DataLabView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var lab = DataLabCenter.shared
    @AppStorage("lab.universe") private var universe = DataLabCenter.universes[0]
    @AppStorage("lab.1m") private var with1m = true
    @AppStorage("lab.tab") private var tab = 0
    @State private var selection: String?
    @State private var sort = "P(up)"
    @State private var record: (hit: Int, n: Int, mae: Double, inBand: Int)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                Text("Tomorrow's candle").tag(0)
                Text("How good is it?").tag(1)
                Text("Data").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 420).padding(8)
            Divider()
            switch tab {
            case 0: tomorrow
            case 1: scoreboard
            default: dataTab
            }
        }
        .navigationTitle("Data Lab")
        .task { record = lab.trackRecord() }
        .onChange(of: lab.log.count) { _ in record = lab.trackRecord() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "flask").foregroundStyle(.purple)
            Text("Data Lab").font(.headline)
            Picker("", selection: $universe) { ForEach(DataLabCenter.universes, id: \.self) { Text($0).tag($0) } }
                .labelsHidden().fixedSize()
                .help("Which stocks get candles and predictions")
            Text("\(lab.symbols(vm).count) stocks").font(.caption).foregroundStyle(.secondary)
            Toggle("1-minute too", isOn: $with1m).toggleStyle(.checkbox)
                .help("Also keep 1-minute candles (first \(DataLabCenter.max1m) stocks) — adds last-15-minute and choppiness features")
            Spacer()
            if lab.busy { ProgressView().controlSize(.small) }
            if let s = lab.status { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Button { lab.update(vm) } label: { Label("Update candles", systemImage: "arrow.down.circle") }.disabled(lab.busy)
            Button { lab.run(vm) } label: { Label("Predict tomorrow", systemImage: "wand.and.stars") }
                .buttonStyle(.borderedProminent).disabled(lab.busy)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Tomorrow's candle

    private func pct(_ v: Double) -> String { String(format: "%+.2f%%", v * 100) }

    private var sorted: [LabPrediction] {
        let p = lab.result?.predictions ?? []
        switch sort {
        case "Close ↑": return p.sorted { $0.point[3] > $1.point[3] }
        case "Close ↓": return p.sorted { $0.point[3] < $1.point[3] }
        case "Gap ↑": return p.sorted { $0.point[0] > $1.point[0] }
        case "A → Z": return p.sorted { $0.sym < $1.sym }
        default: return p.sorted { $0.pUp > $1.pUp }
        }
    }

    private var tomorrow: some View {
        Group {
            if let r = lab.result, !r.predictions.isEmpty {
                HSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            Text("After \(r.asOf) · \(r.predictions.count) stocks").font(.caption.bold())
                            Spacer()
                            Picker("Sort", selection: $sort) { ForEach(["P(up)", "Close ↑", "Close ↓", "Gap ↑", "A → Z"], id: \.self) { Text($0).tag($0) } }
                                .labelsHidden().fixedSize().controlSize(.small)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        Table(sorted, selection: $selection) {
                            TableColumn("Symbol") { p in SymbolWithDots(symbol: p.sym) }.width(min: 100, ideal: 120)
                            TableColumn("P(up)") { p in Text(String(format: "%.0f%%", p.pUp * 100)).monospacedDigit().foregroundStyle(p.pUp >= 0.5 ? .green : .red) }.width(50)
                            TableColumn("Open") { p in Text(pct(p.point[0])).monospacedDigit() }.width(62)
                            TableColumn("High") { p in Text(pct(p.point[1])).monospacedDigit() }.width(62)
                            TableColumn("Low") { p in Text(pct(p.point[2])).monospacedDigit() }.width(62)
                            TableColumn("Close") { p in Text(pct(p.point[3])).monospacedDigit().foregroundStyle(p.point[3] >= 0 ? .green : .red) }.width(62)
                            TableColumn("Close 80% band") { p in Text("\(pct(p.point[3] - p.band[3])) … \(pct(p.point[3] + p.band[3]))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }.width(min: 120, ideal: 140)
                        }
                    }
                    .frame(minWidth: 560)
                    detail(r)
                        .frame(minWidth: 380, idealWidth: 460)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "candlestick.chart").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Tomorrow's candle").font(.title2.bold())
                    Text("1. Update candles — downloads 5-minute (and 1-minute) candles from Yahoo for the stocks above, stored compressed.\n2. Predict tomorrow — learns from every stock-day how the next day's open, high, low and close followed, scores itself on the last days it hasn't seen, then predicts the day after the latest candles.")
                        .multilineTextAlignment(.leading).foregroundStyle(.secondary).frame(maxWidth: 620)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func detail(_ r: LabResult) -> some View {
        if let id = selection, let p = r.predictions.first(where: { $0.sym == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(p.sym).font(.title3.bold())
                        Text("close \(String(format: "%.2f", p.close)) on \(p.asOf)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Chart") { vm.openChart(p.sym, openWindow: openWindow) }.controlSize(.small)
                    }
                    CandleWithTomorrow(pred: p).frame(height: 240)
                    Text("Predicted next day: open \(pct(p.point[0])) · high \(pct(p.point[1])) · low \(pct(p.point[2])) · close \(pct(p.point[3])) (80% band ± \(String(format: "%.2f", p.band[3] * 100))%) · P(close up) \(String(format: "%.0f%%", p.pUp * 100))")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    GroupBox("What pushed the close prediction (ridge model)") {
                        VStack(alignment: .leading, spacing: 2) { ForEach(p.drivers, id: \.self) { Text($0).font(.caption.monospaced()) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Most similar past stock-days (analogs)") {
                        VStack(alignment: .leading, spacing: 2) { ForEach(p.analogs, id: \.self) { Text($0).font(.caption.monospaced()) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        } else {
            Text("Select a stock to see its candles with tomorrow's predicted candle.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Scoreboard

    private var scoreboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = lab.result?.score, !s.rows.isEmpty {
                    Text("Walk-forward test: for each of the last \(s.testDays.count) days (\(s.testDays.first ?? "") → \(s.testDays.last ?? "")), every model was re-fitted on earlier days only and asked to predict the next day — \(s.nTest) stock-days in all.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Average error").font(.caption.bold()).gridColumnAlignment(.leading)
                            ForEach(LabScore.models, id: \.self) { Text($0).font(.caption.bold()) }
                            Text("Ensemble vs naive").font(.caption.bold())
                            Text("80% band held").font(.caption.bold())
                        }
                        Divider()
                        ForEach(s.rows, id: \.target) { row in
                            GridRow {
                                Text(row.target).gridColumnAlignment(.leading)
                                ForEach(0..<row.mae.count, id: \.self) { i in
                                    Text(String(format: "%.2f%%", row.mae[i] * 100)).monospacedDigit()
                                        .foregroundStyle(i > 0 && row.mae[i] < row.mae[0] ? Color.green : Color.primary)
                                }
                                let skill = row.mae[0] > 0 ? (1 - row.mae[4] / row.mae[0]) * 100 : 0
                                Text(String(format: "%+.1f%%", skill)).monospacedDigit().foregroundStyle(skill > 0 ? .green : .red)
                                Text(String(format: "%.0f%%", row.coverage * 100)).monospacedDigit()
                            }
                        }
                    }
                    .font(.callout)
                    GroupBox("Direction of the close") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Right \(String(format: "%.1f", s.dirHit * 100))% of the time · always guessing the more common direction: \(String(format: "%.1f", s.dirBase * 100))%")
                            Text("Brier score \(String(format: "%.4f", s.brier)) vs \(String(format: "%.4f", s.brierBase)) for the plain up-rate (lower is better)")
                                .foregroundStyle(s.brier < s.brierBase ? .green : .orange)
                        }
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let r = record, r.n > 0 {
                        GroupBox("Track record of saved predictions") {
                            Text("\(r.n) predictions now have their next day: direction right \(r.hit) (\(String(format: "%.0f", Double(r.hit) / Double(r.n) * 100))%), close inside the 80% band \(r.inBand) (\(String(format: "%.0f", Double(r.inBand) / Double(r.n) * 100))%), average close error \(String(format: "%.2f", r.mae * 100))%.")
                                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("How to read this: a model only helps where it beats Naive (green). Next-day direction for single stocks is close to a coin toss in most published research, so expect hit rates near 50% and use the bands (high / low range) more than the direction. These scores come from a short history (Yahoo keeps ~60 days of 5-minute data) and get more reliable as the app stores more days.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Run “Predict tomorrow” first.").foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    // MARK: Data

    private var dataTab: some View {
        let s5 = LabFiles.symbols("5m").count, s1 = LabFiles.symbols("1m").count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Stored candles").font(.headline)
            Text("5-minute OHLCV: \(s5) symbols · 1-minute OHLCV: \(s1) symbols · compressed with LZFSE in Application Support/StockScreener/datalab.")
            Text("Yahoo keeps about 60 days of 5-minute and about a month of 1-minute candles; each update adds the new days to what's stored, so the history (and the model) grows over time. 1-minute candles are limited to the first \(DataLabCenter.max1m) stocks of the universe to keep the size down.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { openWindow(id: "storage") } label: { Label("See everything the app stores…", systemImage: "internaldrive") }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Last ~25 daily candles from the stored 5-minute bars, plus tomorrow's predicted candle and its 80% band.
struct CandleWithTomorrow: View {
    let pred: LabPrediction
    @State private var days: [OHLCV.Day] = []

    private struct C: Identifiable { let id: Int; let label: String; let o, h, l, c: Double; let next: Bool }

    var body: some View {
        let cs = candles
        Chart {
            ForEach(cs) { c in
                RuleMark(x: .value("Day", c.label), yStart: .value("Low", c.l), yEnd: .value("High", c.h))
                    .foregroundStyle(c.next ? Color.purple.opacity(0.7) : (c.c >= c.o ? Color.green : Color.red))
                RectangleMark(x: .value("Day", c.label), yStart: .value("Open", min(c.o, c.c)), yEnd: .value("Close", max(c.o, c.c) + (abs(c.c - c.o) < 1e-9 ? 0.0001 * c.c : 0)), width: 6)
                    .foregroundStyle(c.next ? Color.purple.opacity(0.55) : (c.c >= c.o ? Color.green : Color.red))
            }
            if let last = cs.last, last.next {
                let base = Double(pred.close)
                RectangleMark(x: .value("Day", last.label),
                              yStart: .value("Band low", base * (1 + pred.point[3] - pred.band[3])),
                              yEnd: .value("Band high", base * (1 + pred.point[3] + pred.band[3])), width: 18)
                    .foregroundStyle(Color.purple.opacity(0.12))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .task(id: pred.sym) { days = LabFiles.load(pred.sym, "5m")?.days() ?? [] }
    }

    private var candles: [C] {
        var out: [C] = []
        let upto = days.filter { $0.day <= pred.asOf }.suffix(25)
        for (i, d) in upto.enumerated() { out.append(C(id: i, label: String(d.day.suffix(5)), o: Double(d.o), h: Double(d.h), l: Double(d.l), c: Double(d.c), next: false)) }
        let b = Double(pred.close)
        out.append(C(id: out.count, label: "Next", o: b * (1 + pred.point[0]), h: b * (1 + max(pred.point[1], pred.point[0], pred.point[3])),
                     l: b * (1 + min(pred.point[2], pred.point[0], pred.point[3])), c: b * (1 + pred.point[3]), next: true))
        return out
    }
}
