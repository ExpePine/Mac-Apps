import AppKit

extension ScreenerViewModel {

    func pickGrade(_ symbol: String, day: String) -> PickGrade? {
        picks.first { $0.symbol == symbol.uppercased() && $0.day == day }?.grade
    }

    func pickColor(_ symbol: String, day: String) -> NSColor {
        switch pickGrade(symbol, day: day) {
        case .pick?: return .systemGreen
        case .ok?: return .systemOrange
        case nil: return .quaternaryLabelColor
        }
    }

    /// Sets (or clears, with nil) the pick for a gainer on a day.
    func setPick(_ g: GainerRow, day: String, grade: PickGrade?) {
        let sym = g.symbol.uppercased()
        if let i = picks.firstIndex(where: { $0.symbol == sym && $0.day == day }) {
            if let grade { picks[i].grade = grade } else { picks.remove(at: i) }
            return
        }
        guard let grade else { return }
        let sector = sectorColumnIndex.map { g.row.text($0) } ?? ""
        picks.append(Pick(symbol: sym, day: day, grade: grade, change: g.change, close: g.close,
                          sector: sector, why: reason(sym, day: day) ?? ""))
    }

    /// Grey → green (my pick) → orange (OK) → grey.
    func cyclePick(_ g: GainerRow, day: String) {
        switch pickGrade(g.symbol, day: day) {
        case nil: setPick(g, day: day, grade: .pick)
        case .pick?: setPick(g, day: day, grade: .ok)
        case .ok?: setPick(g, day: day, grade: nil)
        }
    }

    /// Returns since the pick (entry = that day's close), using Yahoo closes.
    func pickReturns(_ p: Pick) -> WatchReturns {
        WatchReturns.compute(WatchItem(symbol: p.symbol, addedDay: p.day, addedPrice: p.close),
                             series: priceBook.series(for: p.symbol), benchmark: priceBook.series(for: Self.benchmarkSymbol))
    }

    /// Tops up Yahoo prices for picked stocks (and the Nifty).
    func refreshPickPrices() {
        guard !isFetchingWatch else { return }
        let symbols = Array(Set(picks.map(\.symbol))) + [Self.benchmarkSymbol]
        isFetchingWatch = true
        Task { [weak self] in
            let (book, _) = await YahooClient.fetchAll(symbols, range: "1y") { _, _ in }
            guard let self else { return }
            var merged = self.priceBook
            for (k, v) in book.series { merged.series[k] = merged.series[k].map { $0.merged(with: v) } ?? v }
            self.priceBook = merged
            PriceStore.save(merged)
            for i in self.picks.indices where self.picks[i].close == nil {
                if let s = merged.series(for: self.picks[i].symbol), let j = s.index(onOrBefore: self.picks[i].day) {
                    self.picks[i].close = s.closes[j]
                }
            }
            self.isFetchingWatch = false
        }
    }
}
