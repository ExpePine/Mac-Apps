import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Watchlists: stocks you copied from the Filter / Data tables (or pasted), with their returns.
struct WatchlistView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var sortOrder = [KeyPathComparator(\WatchRow.sinceAddedSort, order: .reverse)]
    @State private var selection = Set<UUID>()
    @State private var pasteText = ""
    @State private var showPaste = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            if let li = vm.currentWatchlistIndex {
                detail(li)
            } else {
                Text("No watchlists").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Watchlists")
        .onAppear {
            if vm.watchlists.contains(where: { !$0.items.isEmpty }) && needsPrices { vm.fetchWatchPrices() }
        }
        .sheet(isPresented: $showPaste) { pasteSheet }
    }

    private var needsPrices: Bool {
        let syms = vm.watchlists.flatMap { $0.items.map(\.symbol) }
        return syms.contains { vm.priceBook.series(for: $0) == nil } || vm.priceBook.series(for: ScreenerViewModel.benchmarkSymbol) == nil
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { vm.currentWatchlistIndex.map { vm.watchlists[$0].id } },
                                    set: { vm.selectedWatchlistID = $0 })) {
                ForEach(vm.watchlists) { list in
                    HStack {
                        if renaming == list.id {
                            TextField("Name", text: $newName, onCommit: { rename(list.id) })
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Label(list.name, systemImage: "star")
                            Spacer()
                            Text("\(list.items.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(list.id)
                    .contextMenu {
                        Button("Rename") { newName = list.name; renaming = list.id }
                        Button("Delete", role: .destructive) { delete(list.id) }
                            .disabled(vm.watchlists.count <= 1)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { vm.newWatchlist(named: "") } label: { Image(systemName: "plus") }
                    .help("New watchlist")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    // MARK: Detail

    private func detail(_ li: Int) -> some View {
        let list = vm.watchlists[li]
        let rows = list.items.map { WatchRow(item: $0, r: vm.watchReturns($0)) }.sorted(using: sortOrder)
        let returns = rows.compactMap(\.r.sinceAdded)
        let alphas = rows.compactMap { row in row.r.sinceAdded.flatMap { s in row.r.benchmark.map { s - $0 } } }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(list.name).font(.title2.bold())
                Spacer()
                if vm.isFetchingWatch { ProgressView().controlSize(.small); Text("Updating prices…").font(.caption) }
                Button { vm.fetchWatchPrices() } label: { Label("Refresh prices", systemImage: "arrow.clockwise") }
                    .disabled(vm.isFetchingWatch || list.items.isEmpty)
                Button { pasteText = ""; showPaste = true } label: { Label("Add symbols…", systemImage: "plus") }
                Menu {
                    Button("Copy symbols (one per line)") { copy(list.items.map(\.symbol).joined(separator: "\n")) }
                    Button("Copy for TradingView (NSE:SYMBOL, …)") { copy(list.items.map { "NSE:" + $0.symbol }.joined(separator: ",")) }
                    Button("Copy table (tab-separated)") { copy(tsv(rows)) }
                    Button("Export CSV…") { exportCSV(rows, name: list.name) }
                } label: { Label("Copy / Export", systemImage: "square.and.arrow.up") }
                .fixedSize()
            }
            .padding(10)

            summary(returns: returns, alphas: alphas, rows: rows)
                .padding(.horizontal, 10).padding(.bottom, 8)
            if let e = vm.watchError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Symbol", value: \.symbol) { row in SymbolWithDots(symbol: row.symbol, bold: false) }
                    .width(min: 80, ideal: 110)
                TableColumn("Added", value: \.item.addedAt) { row in
                    Text(row.item.addedAt.formatted(date: .abbreviated, time: .omitted))
                        .help(row.item.priceSource.isEmpty ? "No added price yet" : "Added price from \(row.item.priceSource)")
                }
                .width(85)
                TableColumn("Added ₹", value: \.addedSort) { row in num(row.item.addedPrice, decimals: 2) }.width(75)
                TableColumn("Now ₹", value: \.nowSort) { row in
                    num(row.r.now, decimals: 2).help(row.r.nowDay.map { "Yahoo close \($0)" } ?? "Not fetched yet")
                }
                .width(75)
                TableColumn("Return", value: \.sinceAddedSort) { row in pct(row.r.sinceAdded, bold: true) }.width(70)
                TableColumn("vs Nifty", value: \.alphaSort) { row in
                    pct(row.r.sinceAdded.flatMap { s in row.r.benchmark.map { s - $0 } })
                        .help(row.r.benchmark.map { String(format: "Nifty 50 over the same days: %+.2f%%", $0) } ?? "Nifty not fetched")
                }
                .width(70)
                TableColumn("1D", value: \.d1Sort) { row in pct(row.r.day1) }.width(58)
                TableColumn("5D", value: \.d5Sort) { row in pct(row.r.day5) }.width(58)
                TableColumn("1M", value: \.m1Sort) { row in pct(row.r.month1) }.width(58)
                TableColumn("Best / from best", value: \.peakSort) { row in
                    HStack(spacing: 4) { pct(row.r.maxSinceAdded); Text("/").foregroundStyle(.secondary); pct(row.r.fromPeak) }
                }
                .width(120)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Remove \(ids.count) from list", role: .destructive) { remove(ids, from: li) }
                Button("Open chart") {
                    if let id = ids.first, let it = list.items.first(where: { $0.id == id }) {
                        vm.openChart(it.symbol, queue: rows.map(\.symbol), openWindow: openWindow)
                    }
                }
                .disabled(ids.count != 1)
                Button("Screenshots…") {
                    if let id = ids.first, let it = list.items.first(where: { $0.id == id }) { vm.shotSymbol = it.symbol; openWindow(id: "shots") }
                }
                .disabled(ids.count != 1)
                Button("Copy symbols") { copy(list.items.filter { ids.contains($0.id) }.map(\.symbol).joined(separator: "\n")) }
            }
            .onDeleteCommand { remove(selection, from: li) }

            if let id = selection.first, selection.count == 1, let ii = list.items.firstIndex(where: { $0.id == id }) {
                Divider()
                HStack {
                    Image(systemName: "note.text").foregroundStyle(.secondary)
                    TextField("Note for \(list.items[ii].symbol)", text: Binding(
                        get: { vm.watchlists[li].items.indices.contains(ii) ? vm.watchlists[li].items[ii].note : "" },
                        set: { if vm.watchlists[li].items.indices.contains(ii) { vm.watchlists[li].items[ii].note = $0 } }))
                        .textFieldStyle(.plain)
                }
                .padding(8)
            }
            Text("Returns use Yahoo daily closes (unofficial source). Return = from the price when added to the latest close. Not financial advice.")
                .font(.caption2).foregroundStyle(.secondary).padding(6)
        }
    }

    private func summary(returns: [Double], alphas: [Double], rows: [WatchRow]) -> some View {
        let avg = returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
        let sorted = returns.sorted()
        let median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        let winners = returns.filter { $0 > 0 }.count
        let best = rows.filter { $0.r.sinceAdded != nil }.max { ($0.r.sinceAdded ?? 0) < ($1.r.sinceAdded ?? 0) }
        let worst = rows.filter { $0.r.sinceAdded != nil }.min { ($0.r.sinceAdded ?? 0) < ($1.r.sinceAdded ?? 0) }
        let avgAlpha = alphas.isEmpty ? nil : alphas.reduce(0, +) / Double(alphas.count)
        return HStack(spacing: 22) {
            stat("Average return", avg.map { String(format: "%+.2f%%", $0) } ?? "—", color: (avg ?? 0) >= 0 ? .green : .red,
                 note: "equal weight, \(returns.count) stocks")
            stat("Median", median.map { String(format: "%+.2f%%", $0) } ?? "—", color: (median ?? 0) >= 0 ? .green : .red)
            stat("Winners", returns.isEmpty ? "—" : "\(winners) / \(returns.count)", color: .primary)
            stat("vs Nifty (avg)", avgAlpha.map { String(format: "%+.2f pts", $0) } ?? "—", color: (avgAlpha ?? 0) >= 0 ? .green : .red,
                 note: "each stock vs Nifty 50 over its own dates")
            stat("Best", best.map { "\($0.symbol) " + String(format: "%+.1f%%", $0.r.sinceAdded ?? 0) } ?? "—", color: .green)
            stat("Worst", worst.map { "\($0.symbol) " + String(format: "%+.1f%%", $0.r.sinceAdded ?? 0) } ?? "—", color: .red)
        }
    }

    private func stat(_ title: String, _ value: String, color: Color, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func num(_ v: Double?, decimals: Int) -> some View {
        Text(v.map { String(format: "%.\(decimals)f", $0) } ?? "—").monospacedDigit()
            .foregroundStyle(v == nil ? .secondary : .primary)
    }

    private func pct(_ v: Double?, bold: Bool = false) -> some View {
        Text(v.map { String(format: "%+.2f%%", $0) } ?? "—")
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(v == nil ? Color.secondary : (v! >= 0 ? Color.green : Color.red))
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add symbols").font(.headline)
            Text("Paste symbols separated by commas, spaces or new lines (TCS, INFY or NSE:TCS).")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $pasteText).font(.system(.body, design: .monospaced)).frame(height: 160)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { showPaste = false }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let syms = pasteText.components(separatedBy: CharacterSet(charactersIn: ",; \n\t")).filter { !$0.isEmpty }
                    vm.addSymbols(syms)
                    showPaste = false
                    vm.fetchWatchPrices()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 420)
    }

    // MARK: Helpers

    private func rename(_ id: UUID) {
        if let i = vm.watchlists.firstIndex(where: { $0.id == id }), !newName.trimmingCharacters(in: .whitespaces).isEmpty {
            vm.watchlists[i].name = newName.trimmingCharacters(in: .whitespaces)
        }
        renaming = nil
    }

    private func delete(_ id: UUID) {
        guard vm.watchlists.count > 1 else { return }
        vm.watchlists.removeAll { $0.id == id }
        vm.selectedWatchlistID = vm.watchlists.first?.id
    }

    private func remove(_ ids: Set<UUID>, from li: Int) {
        guard vm.watchlists.indices.contains(li) else { return }
        vm.watchlists[li].items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }

    private func tsv(_ rows: [WatchRow], sep: String = "\t") -> String {
        let header = ["Symbol", "Added", "Added price", "Now", "Return %", "vs Nifty pts", "1D %", "5D %", "1M %", "Best %", "From best %", "Note"]
        let lines = rows.map { r in
            [r.symbol, r.item.addedDay, f(r.item.addedPrice), f(r.r.now), f(r.r.sinceAdded),
             f(r.r.sinceAdded.flatMap { s in r.r.benchmark.map { s - $0 } }), f(r.r.day1), f(r.r.day5), f(r.r.month1),
             f(r.r.maxSinceAdded), f(r.r.fromPeak), r.item.note.replacingOccurrences(of: sep, with: " ")].joined(separator: sep)
        }
        return ([header.joined(separator: sep)] + lines).joined(separator: "\n")
    }

    private func exportCSV(_ rows: [WatchRow], name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = name + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = tsv(rows, sep: ",")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// One table row with sortable keys (missing values sort last).
struct WatchRow: Identifiable {
    let item: WatchItem
    let r: WatchReturns
    var id: UUID { item.id }
    var symbol: String { item.symbol }
    private static let missing = -Double.greatestFiniteMagnitude
    var addedSort: Double { item.addedPrice ?? Self.missing }
    var nowSort: Double { r.now ?? Self.missing }
    var sinceAddedSort: Double { r.sinceAdded ?? Self.missing }
    var alphaSort: Double { r.sinceAdded.flatMap { s in r.benchmark.map { s - $0 } } ?? Self.missing }
    var d1Sort: Double { r.day1 ?? Self.missing }
    var d5Sort: Double { r.day5 ?? Self.missing }
    var m1Sort: Double { r.month1 ?? Self.missing }
    var peakSort: Double { r.maxSinceAdded ?? Self.missing }
}
