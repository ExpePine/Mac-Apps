import SwiftUI
import AppKit

// MARK: - Alert Tracker
//
// Every stock a shortlist alert fires on (e.g. D_Trigger → MS > 99 or DS > 99) is added here with the day and
// price, and then followed: % change since (Yahoo, live while NSE is open), best gain since, and the Filter
// columns you pick — value when it was added → value now. Watch conditions (e.g. count = 5) light the stock up
// and post one alert in the Alerts window the day they become true.

struct TrackedStock: Codable, Identifiable, Equatable {
    var id = UUID()
    var symbol: String
    var source: String                 // which alert added it (or "Added by hand")
    var day: String                    // yyyy-MM-dd
    var price: Double?                 // close on that day
    var snapshot: [String: String] = [:]   // column → text when added
    var archived = false
    var notes = ""
}

struct TrackerWatch: Codable, Identifiable, Equatable {
    var id = UUID()
    var column = "count"
    var op = "="
    var value = 5.0
    var text: String { "\(column) \(op) \(CombiEngine.fmt(value))" }
    func passes(_ v: Double?) -> Bool { ShortlistCond(column: column, op: op, value: value).passes(v) }
}

enum TrackerStore {
    private static var url: URL { AppFolders.base.appendingPathComponent("tracker.json") }
    struct File: Codable { var stocks: [TrackedStock] = []; var watches: [TrackerWatch] = [TrackerWatch()]; var columns: [String] = [] }
    static func load() -> File {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return File() }
        return f
    }
    static func save(_ f: File) { if let d = try? JSONEncoder().encode(f) { try? d.write(to: url, options: .atomic) } }
}

@MainActor final class TrackerCenter: ObservableObject {
    static let shared = TrackerCenter()
    static let watchRuleID = UUID(uuidString: "7AC0E3B2-1D4F-4C8A-9E21-3F5B6A7C8D90")!
    @Published var file = TrackerStore.load() { didSet { TrackerStore.save(file) } }
    var autoAdd: Bool { UserDefaults.standard.object(forKey: "tracker.auto") as? Bool ?? true }

    var active: [TrackedStock] { file.stocks.filter { !$0.archived } }

    /// Adds the stocks an alert just fired on (once per symbol while it is being tracked).
    func add(_ symbols: [String], source: String, vm: ScreenerViewModel) {
        let day = HistoryStore.dayKey(vm.dataDay(of: vm.table))
        let tracked = Set(active.map(\.symbol))
        let cols = columns(vm)
        var new: [TrackedStock] = []
        for s in symbols.map({ $0.uppercased() }) where !tracked.contains(s) && !new.contains(where: { $0.symbol == s }) {
            let row = vm.row(for: s)
            var snap: [String: String] = [:]
            for c in cols { if let i = vm.table.index(of: c), let row { snap[c] = row.text(i) } }
            new.append(TrackedStock(symbol: s, source: source, day: day, price: price(s, on: day, vm: vm), snapshot: snap))
        }
        if !new.isEmpty { file.stocks.insert(contentsOf: new, at: 0) }
    }

    func price(_ s: String, on day: String, vm: ScreenerViewModel) -> Double? {
        if let ser = vm.priceBook.series(for: s), let i = ser.index(onOrBefore: day) { return ser.closes[i] }
        if let row = vm.row(for: s), let c = vm.table.index(of: vm.closeColumnName) { return row.number(c) }
        return nil
    }

    /// Columns shown in the tracker (default: the watch columns + a few from the Filter).
    func columns(_ vm: ScreenerViewModel) -> [String] {
        if !file.columns.isEmpty { return file.columns.filter { vm.table.index(of: $0) != nil } }
        var out = file.watches.map(\.column)
        for h in vm.filterColumnIndices.map({ vm.headers[$0] }) where h != vm.headers[vm.labelIndex ?? 0] && out.count < 8 && !out.contains(h) { out.append(h) }
        return out.filter { vm.table.index(of: $0) != nil }
    }

    /// Watch conditions met by a tracked stock today.
    func hits(_ t: TrackedStock, vm: ScreenerViewModel) -> [TrackerWatch] {
        guard let row = vm.row(for: t.symbol) else { return [] }
        return file.watches.filter { w in vm.table.index(of: w.column).map { w.passes(row.number($0)) } ?? false }
    }

    /// In-app alert + Alerts-window entries when a watch condition becomes true for a tracked stock.
    func watchAlerts(vm: ScreenerViewModel) -> [InAppAlert] {
        guard let prev = vm.previousDayRows() else { return [] }
        var out: [InAppAlert] = []
        for w in file.watches {
            guard let i = vm.table.index(of: w.column) else { continue }
            let rows: [SheetRow] = active.compactMap { t in
                guard let r = vm.row(for: t.symbol), w.passes(r.number(i)) else { return nil }
                if let old = prev.rows[t.symbol], w.passes(old.number(i)) { return nil }        // was already true
                return r
            }
            guard !rows.isEmpty else { continue }
            var rule = BuyTrigger(isEnabled: true, name: "Tracker: \(w.text)")
            rule.id = Self.watchRuleID
            rule.filter = FilterGroup(mode: .all, conditions: [FilterCondition(column: w.column, op: RuleOperator(rawValue: w.op) ?? .equals, value: CombiEngine.fmt(w.value))])
            vm.recordAlertEvents(rule: rule, rows: rows, kind: .alert)
            out.append(InAppAlert(triggerID: w.id, name: "Tracker: \(w.text) (became true)", stocks: rows.map { vm.rowKey($0) }))
        }
        return out
    }
}

extension ScreenerViewModel {
    /// Today's row for a symbol.
    func row(for symbol: String) -> SheetRow? {
        guard let label = labelIndex else { return nil }
        let s = symbol.uppercased()
        return table.rows.first { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() == s }
    }
}

// MARK: - Window

struct TrackerView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var tc = TrackerCenter.shared
    @ObservedObject private var live = LiveQuotes.shared
    @AppStorage("tracker.auto") private var autoAdd = true
    @AppStorage("tracker.showArchived") private var showArchived = false
    @AppStorage("tracker.sort") private var sort = "Newest"
    @AppStorage("tracker.onlyHits") private var onlyHits = false
    @State private var adding = ""
    @State private var showColumns = false

    private struct Line: Identifiable {
        var id: UUID { t.id }
        let t: TrackedStock
        let now: Double?
        let change: Double?
        let best: Double?
        let days: Int
        let hits: [TrackerWatch]
    }

    private var lines: [Line] {
        _ = live.tick
        let today = HistoryStore.dayKey(vm.dataDay(of: vm.table))
        var out: [Line] = tc.file.stocks.filter { showArchived || !$0.archived }.map { t in
            let ser = vm.priceBook.series(for: t.symbol)
            let now = ser?.closes.last ?? tc.price(t.symbol, on: today, vm: vm)
            let change = (t.price ?? 0) > 0 ? now.map { ($0 / t.price! - 1) * 100 } : nil
            var best: Double? = nil, days = 0
            if let ser, let i = ser.index(onOrBefore: t.day), let p = t.price, p > 0 {
                days = ser.closes.count - 1 - i
                if i + 1 < ser.closes.count { best = ((ser.closes[(i + 1)...].max() ?? p) / p - 1) * 100 }
            }
            return Line(t: t, now: now, change: change, best: best, days: days, hits: tc.hits(t, vm: vm))
        }
        if onlyHits { out = out.filter { !$0.hits.isEmpty } }
        switch sort {
        case "Change %": out.sort { ($0.change ?? -999) > ($1.change ?? -999) }
        case "Best gain": out.sort { ($0.best ?? -999) > ($1.best ?? -999) }
        case "A → Z": out.sort { $0.t.symbol < $1.t.symbol }
        case "Watch hits": out.sort { ($0.hits.count, $0.t.day) > ($1.hits.count, $1.t.day) }
        default: out.sort { $0.t.day > $1.t.day }
        }
        return out
    }

    var body: some View {
        let list = lines
        let cols = tc.columns(vm)
        VStack(spacing: 0) {
            header(list)
            Divider()
            watchBar
            Divider()
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "binoculars").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No tracked stocks yet").font(.title3.bold())
                    Text("Stocks join automatically when a shortlist alert fires (Alerts → Shortlist alerts…), or add one above.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section(header: headRow(cols)) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { k, l in
                                row(l, cols).background(!l.hits.isEmpty ? Color.green.opacity(0.14) : (k % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05)))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Alert Tracker")
        .task { await LiveQuotes.shared.keepLive(vm) }
        .popover(isPresented: $showColumns, arrowEdge: .top) { columnsPicker }
    }

    private func header(_ list: [Line]) -> some View {
        FlowLayout(spacing: 12, lineSpacing: 6) {
            Text("Alert Tracker").font(.title2.bold()).fixedSize()
            let act = tc.active
            Text("\(act.count) tracked · \(list.filter { !$0.hits.isEmpty }.count) meeting a watch").font(.caption).foregroundStyle(.secondary).fixedSize()
            Toggle("Add stocks when a shortlist alert fires", isOn: $autoAdd).toggleStyle(.checkbox).fixedSize()
            HStack(spacing: 4) {
                SymbolField(vm: vm, placeholder: "Add a stock…", text: $adding, onSubmit: addTyped).frame(width: 150)
                Button("Add") { addTyped() }.disabled(adding.isEmpty)
            }.fixedSize()
            Button { showColumns = true } label: { Label("Columns", systemImage: "rectangle.split.3x1") }.fixedSize()
            Picker("", selection: $sort) { ForEach(["Newest", "Change %", "Best gain", "Watch hits", "A → Z"], id: \.self) { Text($0).tag($0) } }
                .labelsHidden().fixedSize()
            Toggle("Only watch hits", isOn: $onlyHits).toggleStyle(.checkbox).fixedSize()
            Toggle("Show removed", isOn: $showArchived).toggleStyle(.checkbox).fixedSize()
            Button { openReel(list.map(\.t.symbol)) } label: { Label("Chart Reel 1 → 2", systemImage: "film.stack") }.disabled(list.isEmpty).fixedSize()
            Text(live.statusText).font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var watchBar: some View {
        HStack(spacing: 8) {
            Text("Watch:").font(.caption.bold())
            ForEach($tc.file.watches) { $w in
                HStack(spacing: 3) {
                    Picker("", selection: $w.column) { ForEach(vm.headers, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 110)
                    Picker("", selection: $w.op) { ForEach([">", "≥", "<", "≤", "="], id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
                    TextField("", value: $w.value, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                    Button { tc.file.watches.removeAll { $0.id == w.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.12)))
            }
            Button { tc.file.watches.append(TrackerWatch(column: vm.headers.first ?? "", op: ">", value: 0)) } label: { Label("Watch", systemImage: "plus") }
            Text("A stock that meets a watch is highlighted green, and the day it becomes true it's posted in Alerts.")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func headRow(_ cols: [String]) -> some View {
        HStack(spacing: 0) {
            Text("Stock").frame(width: 140, alignment: .leading)
            Text("Added").frame(width: 90, alignment: .leading)
            Text("Days").frame(width: 44, alignment: .trailing)
            Text("Price then").frame(width: 80, alignment: .trailing)
            Text("Now").frame(width: 80, alignment: .trailing)
            Text("Change").frame(width: 72, alignment: .trailing)
            Text("Best").frame(width: 66, alignment: .trailing)
            ForEach(cols, id: \.self) { c in Text(c).frame(width: 110, alignment: .trailing).lineLimit(1) }
            Text("From").frame(width: 200, alignment: .leading).padding(.leading, 12)
        }
        .font(.caption.bold())
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    private func row(_ l: Line, _ cols: [String]) -> some View {
        let r = vm.row(for: l.t.symbol)
        return HStack(spacing: 0) {
            SymbolWithDots(symbol: l.t.symbol).frame(width: 140, alignment: .leading).opacity(l.t.archived ? 0.5 : 1)
            Text(l.t.day).monospacedDigit().frame(width: 90, alignment: .leading)
            Text("\(l.days)").monospacedDigit().frame(width: 44, alignment: .trailing)
            Text(l.t.price.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(l.now.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(l.change.map { String(format: "%+.1f%%", $0) } ?? "—").monospacedDigit().bold()
                .foregroundStyle((l.change ?? 0) >= 0 ? Color.green : Color.red).frame(width: 72, alignment: .trailing)
            Text(l.best.map { String(format: "%+.1f%%", $0) } ?? "—").monospacedDigit().foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
            ForEach(cols, id: \.self) { c in
                let then = l.t.snapshot[c]
                let now = r.flatMap { row in vm.table.index(of: c).map { row.text($0) } }
                let hit = l.hits.contains { $0.column == c }
                HStack(spacing: 3) {
                    if let then, then != (now ?? "") { Text(then).foregroundStyle(.secondary); Text("→").foregroundStyle(.tertiary) }
                    Text(now ?? "—").bold(hit)
                }
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 4)
                .background(hit ? RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.3)) : nil)
                .frame(width: 110, alignment: .trailing)
            }
            Text(l.t.source).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 200, alignment: .leading).padding(.leading, 12)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { vm.openChart(l.t.symbol, queue: lines.map(\.t.symbol), openWindow: openWindow) }
        .contextMenu {
            Button("Open chart") { vm.openChart(l.t.symbol, queue: lines.map(\.t.symbol), openWindow: openWindow) }
            if l.t.archived {
                Button("Track again") { setArchived(l.t.id, false) }
            } else {
                Button("Stop tracking") { setArchived(l.t.id, true) }
            }
            Button("Delete", role: .destructive) { tc.file.stocks.removeAll { $0.id == l.t.id } }
        }
    }

    private var columnsPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Columns in the tracker").font(.headline)
            Text("Value when the stock was added → value now").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.headers, id: \.self) { h in
                        Toggle(h, isOn: Binding(get: { tc.columns(vm).contains(h) }, set: { on in
                            var c = tc.columns(vm); if on { if !c.contains(h) { c.append(h) } } else { c.removeAll { $0 == h } }
                            tc.file.columns = c
                        })).toggleStyle(.checkbox)
                    }
                }
            }
            .frame(width: 260, height: 360)
            Button("Use the Filter's columns") { tc.file.columns = vm.filterColumnIndices.map { vm.headers[$0] }.filter { $0 != vm.headers[vm.labelIndex ?? 0] } }
                .controlSize(.small)
        }
        .padding(12)
    }

    private func setArchived(_ id: UUID, _ v: Bool) {
        if let i = tc.file.stocks.firstIndex(where: { $0.id == id }) { tc.file.stocks[i].archived = v }
    }

    private func addTyped() {
        let s = adding.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return }
        tc.add([s], source: "Added by hand", vm: vm)
        adding = ""
    }

    private func openReel(_ symbols: [String]) {
        let d = UserDefaults.standard
        ScanCenter.shared.reel = symbols.map { ($0, "tracked", "") }
        d.set(ReelSource.scan.rawValue, forKey: "reel.source")
        d.set(ReelLayout.sequence.rawValue, forKey: "reel.layout")
        d.set(UUID().uuidString + "|", forKey: "reel.jump")
        openWindow(id: "reel")
    }
}
