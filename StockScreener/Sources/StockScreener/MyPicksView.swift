import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// All picks from Daily Gainers (green = my pick, orange = OK), with how each has done since.
struct MyPicksView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var grade: PickGrade? = nil          // nil = both
    @State private var period = 0                       // 0 all, 7, 30, 90 days
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\PickRow.day, order: .reverse)]

    private var rows: [PickRow] {
        let cutoff = period == 0 ? "" : HistoryStore.dayKey(Calendar.current.date(byAdding: .day, value: -period, to: Date()) ?? Date())
        let q = search.trimmingCharacters(in: .whitespaces)
        return vm.picks
            .filter { grade == nil || $0.grade == grade }
            .filter { $0.day >= cutoff }
            .filter { q.isEmpty || $0.symbol.localizedCaseInsensitiveContains(q) || $0.sector.localizedCaseInsensitiveContains(q) }
            .map { PickRow(pick: $0, r: vm.pickReturns($0)) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let list = rows
        VStack(spacing: 0) {
            header(list)
            Divider()
            if vm.picks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "star.square.on.square").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("No picks yet").font(.title3)
                    Text("In Daily Gainers, click the P on a stock (grey → green = my pick → orange = OK), or select rows and press My pick / OK.")
                        .foregroundStyle(.secondary)
                    Button("Open Daily Gainers") { openWindow(id: "gainers") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(list)
            }
        }
        .navigationTitle("My Picks")
        .onAppear {
            if vm.picks.contains(where: { vm.priceBook.series(for: $0.symbol)?.lastDay ?? "" < (vm.priceBook.series(for: ScreenerViewModel.benchmarkSymbol)?.lastDay ?? "") }) {
                vm.refreshPickPrices()
            }
        }
    }

    private func header(_ list: [PickRow]) -> some View {
        let picks = list.filter { $0.pick.grade == .pick }.compactMap(\.r.sinceAdded)
        let oks = list.filter { $0.pick.grade == .ok }.compactMap(\.r.sinceAdded)
        func avg(_ v: [Double]) -> String { v.isEmpty ? "—" : String(format: "%+.1f%%", v.reduce(0, +) / Double(v.count)) }
        func win(_ v: [Double]) -> String { v.isEmpty ? "—" : String(format: "%.0f%% up", Double(v.filter { $0 > 0 }.count) / Double(v.count) * 100) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 22) {
                stat("My picks (green)", "\(list.filter { $0.pick.grade == .pick }.count)", .green, note: "avg \(avg(picks)) · \(win(picks))")
                stat("OK (orange)", "\(list.filter { $0.pick.grade == .ok }.count)", .orange, note: "avg \(avg(oks)) · \(win(oks))")
                let ex = list.compactMap { r in r.r.sinceAdded.flatMap { s in r.r.benchmark.map { s - $0 } } }
                stat("vs Nifty", ex.isEmpty ? "—" : String(format: "%+.1f pts", ex.reduce(0, +) / Double(ex.count)), .blue, note: "avg, same dates")
                Spacer()
                if vm.isFetchingWatch { ProgressView().controlSize(.small) }
                Button { vm.refreshPickPrices() } label: { Label("Update prices", systemImage: "arrow.clockwise") }.disabled(vm.isFetchingWatch)
            }
            HStack(spacing: 10) {
                Picker("", selection: $grade) {
                    Text("All").tag(PickGrade?.none)
                    Text("My picks").tag(PickGrade?.some(.pick))
                    Text("OK").tag(PickGrade?.some(.ok))
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Picker("", selection: $period) {
                    Text("All time").tag(0); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                }
                .labelsHidden().frame(width: 110)
                TextField("Search symbol or sector", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                Spacer()
                Menu("Copy / Export") {
                    Button("Copy symbols") { copy(list.map(\.pick.symbol).joined(separator: "\n")) }
                    Button("Copy for TradingView") { copy(list.map { "NSE:" + $0.pick.symbol }.joined(separator: ",")) }
                    Button("Export CSV…") { export(list) }
                    Divider()
                    ForEach(vm.watchlists) { w in
                        Button("Add \(selection.isEmpty ? "all" : "selected") to “\(w.name)”") {
                            let syms = (selection.isEmpty ? list : list.filter { selection.contains($0.id) }).map(\.pick.symbol)
                            vm.addSymbols(syms, listID: w.id)
                        }
                    }
                }
                .fixedSize()
            }
        }
        .padding(12)
    }

    private func table(_ list: [PickRow]) -> some View {
        VStack(spacing: 0) {
            Table(list, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("P", value: \.gradeOrder) { r in
                    Button {
                        if let i = vm.picks.firstIndex(where: { $0.id == r.pick.id }) {
                            vm.picks[i].grade = vm.picks[i].grade == .pick ? .ok : .pick
                        }
                    } label: {
                        Text("P").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(r.pick.grade == .pick ? Color.green : Color.orange))
                    }
                    .buttonStyle(.plain)
                    .help("Click to switch between my pick (green) and OK (orange)")
                }
                .width(30)
                TableColumn("Day", value: \.day) { Text($0.pick.day).monospacedDigit() }.width(85)
                TableColumn("Symbol", value: \.symbol) { SymbolWithDots(symbol: $0.pick.symbol, bold: false) }.width(min: 110, ideal: 130)
                TableColumn("That day", value: \.changeSort) { r in
                    Text(r.pick.change.map { String(format: "%+.1f%%", $0) } ?? "—").monospacedDigit().foregroundStyle(.green)
                }
                .width(65)
                TableColumn("Entry → Now", value: \.nowSort) { r in
                    Text("\(r.pick.close.map { String(format: "%.2f", $0) } ?? "—") → \(r.r.now.map { String(format: "%.2f", $0) } ?? "—")")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(130)
                TableColumn("Since", value: \.retSort) { r in pct(r.r.sinceAdded, bold: true) }.width(65)
                TableColumn("Best", value: \.bestSort) { r in pct(r.r.maxSinceAdded) }.width(60)
                TableColumn("vs Nifty", value: \.alphaSort) { r in pct(r.r.sinceAdded.flatMap { s in r.r.benchmark.map { s - $0 } }) }.width(65)
                TableColumn("Sector", value: \.sector) { Text($0.pick.sector).foregroundStyle(.secondary).lineLimit(1) }.width(min: 80, ideal: 130)
                TableColumn("Why / note") { r in
                    TextField(r.pick.why.isEmpty ? "Add a note" : r.pick.why, text: Binding(
                        get: { vm.picks.first { $0.id == r.pick.id }?.note ?? "" },
                        set: { v in if let i = vm.picks.firstIndex(where: { $0.id == r.pick.id }) { vm.picks[i].note = v } }))
                        .textFieldStyle(.plain)
                        .help(r.pick.why.isEmpty ? "Your note" : "News reason at the time: \(r.pick.why)")
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Open chart") {
                    if let id = ids.first, let p = vm.picks.first(where: { $0.id == id }) {
                        vm.openChart(p.symbol, queue: list.map(\.pick.symbol), openWindow: openWindow)
                    }
                }
                .disabled(ids.count != 1)
                Button("Mark as my pick (green)") { setGrade(ids, .pick) }
                Button("Mark as OK (orange)") { setGrade(ids, .ok) }
                Divider()
                Button("Remove \(ids.count) pick\(ids.count == 1 ? "" : "s")", role: .destructive) { vm.picks.removeAll { ids.contains($0.id) } }
            }
            .onDeleteCommand { vm.picks.removeAll { selection.contains($0.id) } }
            Divider()
            HStack {
                Text("\(list.count) shown · entry = Yahoo close on the pick day · returns to the latest close. Remove with ⌫ or right-click. Not financial advice.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(6)
        }
    }

    private func setGrade(_ ids: Set<UUID>, _ g: PickGrade) {
        for i in vm.picks.indices where ids.contains(vm.picks[i].id) { vm.picks[i].grade = g }
    }

    private func stat(_ title: String, _ value: String, _ color: Color, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(color)
            if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func pct(_ v: Double?, bold: Bool = false) -> some View {
        Text(v.map { String(format: "%+.1f%%", $0) } ?? "—").monospacedDigit().fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(v == nil ? Color.secondary : (v! >= 0 ? Color.green : Color.red))
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func export(_ list: [PickRow]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "My picks.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = ["Day,Symbol,Grade,That day %,Entry,Now,Since %,Best %,vs Nifty pts,Sector,Why,Note"] + list.map { r in
            [r.pick.day, r.pick.symbol, r.pick.grade.rawValue, f(r.pick.change), f(r.pick.close), f(r.r.now), f(r.r.sinceAdded),
             f(r.r.maxSinceAdded), f(r.r.sinceAdded.flatMap { s in r.r.benchmark.map { s - $0 } }), q(r.pick.sector), q(r.pick.why), q(r.pick.note)]
                .joined(separator: ",")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

struct PickRow: Identifiable {
    let pick: Pick
    let r: WatchReturns
    var id: UUID { pick.id }
    private static let missing = -Double.greatestFiniteMagnitude
    var day: String { pick.day }
    var symbol: String { pick.symbol }
    var sector: String { pick.sector }
    var gradeOrder: Int { pick.grade == .pick ? 0 : 1 }
    var changeSort: Double { pick.change ?? Self.missing }
    var nowSort: Double { r.now ?? Self.missing }
    var retSort: Double { r.sinceAdded ?? Self.missing }
    var bestSort: Double { r.maxSinceAdded ?? Self.missing }
    var alphaSort: Double { r.sinceAdded.flatMap { s in r.benchmark.map { s - $0 } } ?? Self.missing }
}
