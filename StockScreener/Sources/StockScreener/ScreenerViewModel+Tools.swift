import AppKit
import SwiftUI

// Screenshots (S column) and watchlists.
extension ScreenerViewModel {

    // MARK: S column

    /// Grey: no screenshot · Orange: has screenshots · Green: newest is under 7 days old.
    func sColor(_ row: SheetRow) -> NSColor {
        guard let newest = shotIndex[ScreenshotStore.safe(rowKey(row))] else {
            return NSColor.quaternaryLabelColor
        }
        return Date().timeIntervalSince(newest) < 7 * 86_400 ? .systemGreen : .systemOrange
    }

    func refreshShotIndex() {
        shotIndex = ScreenshotStore.index()
    }

    // MARK: Watchlists

    var currentWatchlistIndex: Int? {
        if let id = selectedWatchlistID, let i = watchlists.firstIndex(where: { $0.id == id }) { return i }
        return watchlists.isEmpty ? nil : 0
    }

    /// The sheet's own close-price column, if there is one (used when Yahoo has no price yet).
    var sheetCloseColumn: Int? {
        let names = headers.enumerated().filter { _, h in
            let w = FeatureClassifier.words(h)
            return w.contains("close") && !w.contains("prev") && !w.contains("prevclose")
        }
        let sample = table.rows.prefix(50)
        return names.first(where: { pair in sample.contains { r in r.number(pair.offset) != nil } })?.offset
    }

    /// Adds stocks (rows of the Data / Filter table) to a watchlist. Already-listed symbols are skipped.
    @discardableResult
    func addToWatchlist(_ rows: [SheetRow], listID: UUID? = nil) -> Int {
        let close = sheetCloseColumn
        let day = HistoryStore.dayKey(dataDay(of: table))
        let entries: [(String, Double?, String)] = rows.map { row in
            let sym = rowKey(row).uppercased()
            if let y = priceBook.series(for: sym), let i = y.index(onOrBefore: day) { return (sym, y.closes[i], "Yahoo close \(y.days[i])") }
            if let c = close, let v = row.number(c) { return (sym, v, headers[c]) }
            return (sym, nil, "")
        }
        return addSymbols(entries, listID: listID, day: day)
    }

    /// Adds plain symbols (pasted text). Prices come from Yahoo when available.
    @discardableResult
    func addSymbols(_ symbols: [String], listID: UUID? = nil) -> Int {
        let day = HistoryStore.dayKey(Date())
        let byName = Dictionary(table.rows.map { (rowKey($0).uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let close = sheetCloseColumn
        let entries: [(String, Double?, String)] = symbols.map { raw in
            let sym = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                .replacingOccurrences(of: "NSE:", with: "")
            if let y = priceBook.series(for: sym), let last = y.closes.last { return (sym, last, "Yahoo close \(y.lastDay ?? "")") }
            if let row = byName[sym], let c = close, let v = row.number(c) { return (sym, v, headers[c]) }
            return (sym, nil, "")
        }
        return addSymbols(entries, listID: listID, day: day)
    }

    private func addSymbols(_ entries: [(String, Double?, String)], listID: UUID?, day: String) -> Int {
        guard let li = listID.flatMap({ id in watchlists.firstIndex { $0.id == id } }) ?? currentWatchlistIndex else { return 0 }
        var list = watchlists[li]
        let existing = Set(list.items.map { $0.symbol.uppercased() })
        var added = 0
        var seen = existing
        for (sym, price, source) in entries where !sym.isEmpty && !seen.contains(sym) {
            seen.insert(sym)
            list.items.append(WatchItem(symbol: sym, addedDay: day, addedPrice: price, priceSource: source))
            added += 1
        }
        watchlists[li] = list
        if added > 0 { selectedWatchlistID = list.id }
        return added
    }

    func newWatchlist(named name: String) {
        let list = Watchlist(name: name.isEmpty ? "Watchlist \(watchlists.count + 1)" : name)
        watchlists.append(list)
        selectedWatchlistID = list.id
    }

    /// Daily closes for every watchlist symbol + the Nifty 50 index (^NSEI); merged into the cached prices.
    func fetchWatchPrices() {
        guard !isFetchingWatch else { return }
        let symbols = Array(Set(watchlists.flatMap { $0.items.map(\.symbol) })) + [Self.benchmarkSymbol]
        isFetchingWatch = true
        watchError = nil
        Task { [weak self] in
            let (book, failed) = await YahooClient.fetchAll(symbols, range: "2y") { _, _ in }
            guard let self else { return }
            var merged = self.priceBook
            for (k, v) in book.series { merged.series[k] = v }
            if merged.fetchedAt < book.fetchedAt && self.priceBook.series.isEmpty { merged.fetchedAt = book.fetchedAt }
            self.priceBook = merged
            PriceStore.save(merged)
            // Fill missing "added" prices now that Yahoo has them
            for li in self.watchlists.indices {
                for ii in self.watchlists[li].items.indices where self.watchlists[li].items[ii].addedPrice == nil {
                    let it = self.watchlists[li].items[ii]
                    if let s = merged.series(for: it.symbol), let i = s.index(onOrBefore: it.addedDay) {
                        self.watchlists[li].items[ii].addedPrice = s.closes[i]
                        self.watchlists[li].items[ii].priceSource = "Yahoo close \(s.days[i])"
                    }
                }
            }
            self.isFetchingWatch = false
            let missing = failed.filter { $0 != Self.benchmarkSymbol }
            if !missing.isEmpty {
                self.watchError = "Yahoo returned no prices for: \(missing.prefix(12).joined(separator: ", "))\(missing.count > 12 ? "…" : "")"
            }
        }
    }

    static let benchmarkSymbol = "^NSEI"

    func watchReturns(_ item: WatchItem) -> WatchReturns {
        WatchReturns.compute(item, series: priceBook.series(for: item.symbol), benchmark: priceBook.series(for: Self.benchmarkSymbol))
    }

    /// Right-click menu for a stock row (Data and Filter tables).
    func rowMenu(_ row: SheetRow, selection: [SheetRow], openWindow: OpenWindowAction) -> [(String, () -> Void)] {
        let sym = rowKey(row)
        let targets = selection.contains(where: { $0.id == row.id }) && selection.count > 1 ? selection : [row]
        var items: [(String, () -> Void)] = []
        for list in watchlists {
            let title = targets.count > 1 ? "Add \(targets.count) stocks to “\(list.name)”" : "Add \(sym) to “\(list.name)”"
            items.append((title, { [weak self] in self?.addToWatchlist(targets, listID: list.id) }))
        }
        items.append(("-", {}))
        items.append(("Screenshots of \(sym)…", { [weak self] in
            self?.shotSymbol = sym
            openWindow(id: "shots")
        }))
        items.append(("Copy \(targets.count > 1 ? "\(targets.count) symbols" : sym)", { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(targets.map { self.rowKey($0) }.joined(separator: "\n"), forType: .string)
        }))
        return items
    }
}
