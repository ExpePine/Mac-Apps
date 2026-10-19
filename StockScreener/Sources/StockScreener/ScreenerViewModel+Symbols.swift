import Foundation

extension ScreenerViewModel {

    /// Hidden sheet symbols removed, manual symbols added — so every screen sees the same list.
    func withManualSymbols(_ t: SheetTable) -> SheetTable {
        let label = t.index(of: settings.labelColumn) ?? (t.headers.isEmpty ? nil : 0)
        let sector: Int? = {
            if !settings.sectorColumn.isEmpty, let i = t.index(of: settings.sectorColumn) { return i }
            for n in ["sector", "industry", "sector name", "industry name"] { if let i = t.headers.firstIndex(where: { $0.lowercased() == n }) { return i } }
            return t.headers.firstIndex { $0.lowercased().contains("sector") }
        }()
        let name: Int? = {
            if !settings.companyNameColumn.isEmpty, let i = t.index(of: settings.companyNameColumn) { return i }
            return t.headers.firstIndex { ["company", "company name", "name of company", "companyname", "name"].contains($0.lowercased()) }
        }()
        return symbolBook.apply(to: t, label: label, sector: sector, name: name)
    }

    /// Sheet symbols (before hiding), for the Symbols window.
    var sheetSymbols: [String] {
        guard let label = labelIndex else { return [] }
        let manual = Set(symbolBook.manual.map(\.symbol))
        var out = Set(table.rows.map { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() })
        out.formUnion(symbolBook.hidden)
        out.subtract(manual)
        out.remove("")
        return out.sorted()
    }

    /// Industry names used in the sheet (so manual symbols fit the Sectors screen).
    var knownIndustries: [String] {
        guard let sc = sectorColumnIndex else { return [] }
        return Array(Set(table.rows.map { $0.text(sc).trimmingCharacters(in: .whitespaces) }).subtracting([""])).sorted()
    }

    private func saveSymbols() {
        symbolBook.save()
        setTableKeepingRaw()            // re-apply to every screen
    }

    /// Adds symbols (comma / space / newline separated). Checks Yahoo, fetches a year of prices,
    /// and fills in company name and industry where it can.
    func addManualSymbols(_ text: String) {
        let wanted = text.components(separatedBy: CharacterSet(charactersIn: ",; \n\t")).map(SymbolBook.clean).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return }
        let inSheet = Set(sheetSymbols)
        var added: [String] = [], unhidden: [String] = [], skipped: [String] = []
        for s in Array(NSOrderedSet(array: wanted)) as! [String] {
            if symbolBook.hidden.contains(s) { symbolBook.hidden.removeAll { $0 == s }; unhidden.append(s); continue }
            if inSheet.contains(s) || symbolBook.manual.contains(where: { $0.symbol == s }) { skipped.append(s); continue }
            symbolBook.manual.append(ManualSymbol(symbol: s))
            added.append(s)
        }
        saveSymbols()
        var parts: [String] = []
        if !added.isEmpty { parts.append("Added \(added.joined(separator: ", "))") }
        if !unhidden.isEmpty { parts.append("restored \(unhidden.joined(separator: ", ")) from the sheet") }
        if !skipped.isEmpty { parts.append("already in the app: \(skipped.joined(separator: ", "))") }
        symbolStatus = parts.joined(separator: " · ")
        if !added.isEmpty { checkManualSymbols(added) }
    }

    /// Yahoo check + prices + name / industry for the given (or all unchecked) manual symbols.
    func checkManualSymbols(_ symbols: [String]? = nil) {
        let list = symbols ?? symbolBook.manual.filter { $0.foundOnYahoo != true }.map(\.symbol)
        guard !list.isEmpty, !isCheckingSymbols else { return }
        isCheckingSymbols = true
        let industries = knownIndustries
        Task { [weak self] in
            guard let self else { return }
            let (book, failed) = await YahooClient.fetchAll(list, range: "1y") { _, _ in }
            var merged = self.priceBook
            for (k, v) in book.series { merged.series[k] = merged.series[k].map { $0.merged(with: v) } ?? v }
            self.priceBook = merged
            PriceStore.save(merged)
            for sym in list {
                guard let i = self.symbolBook.manual.firstIndex(where: { $0.symbol == sym }) else { continue }
                let ok = !failed.contains(sym) && merged.series(for: sym) != nil
                self.symbolBook.manual[i].foundOnYahoo = ok
                self.symbolBook.manual[i].lastPrice = merged.series(for: sym)?.closes.last
                if ok, let p = await YahooClient.profile(sym) {
                    if self.symbolBook.manual[i].name.isEmpty { self.symbolBook.manual[i].name = p.name }
                    self.symbolBook.manual[i].yahooIndustry = [p.sector, p.industry].filter { !$0.isEmpty }.joined(separator: " · ")
                    if self.symbolBook.manual[i].industry.isEmpty {
                        self.symbolBook.manual[i].industry = Self.matchIndustry(p.industry, p.sector, in: industries)
                    }
                }
            }
            self.isCheckingSymbols = false
            let bad = list.filter { s in self.symbolBook.manual.first { $0.symbol == s }?.foundOnYahoo == false }
            self.symbolStatus = bad.isEmpty ? "Checked \(list.count) symbol\(list.count == 1 ? "" : "s") on Yahoo ✓"
                                            : "Not found on Yahoo (check the NSE symbol): \(bad.joined(separator: ", "))"
            self.saveSymbols()
        }
    }

    /// Picks the sheet's own industry name closest to Yahoo's wording (word overlap); else Yahoo's industry.
    static func matchIndustry(_ industry: String, _ sector: String, in known: [String]) -> String {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !["and", "the", "other", "others"].contains($0) })
        }
        let target = words(industry).union(words(sector))
        guard !target.isEmpty else { return "" }
        let best = known.map { ($0, Double(words($0).intersection(target).count) / Double(max(1, words($0).count))) }
            .max { $0.1 < $1.1 }
        if let b = best, b.1 >= 0.5 { return b.0 }
        return industry.isEmpty ? sector : industry
    }

    func updateManual(_ sym: String, _ edit: (inout ManualSymbol) -> Void) {
        guard let i = symbolBook.manual.firstIndex(where: { $0.symbol == sym }) else { return }
        edit(&symbolBook.manual[i])
        saveSymbols()
    }

    func removeManual(_ symbols: Set<String>) {
        symbolBook.manual.removeAll { symbols.contains($0.symbol) }
        saveSymbols()
    }

    func hideSymbols(_ symbols: [String]) {
        let clean = symbols.map(SymbolBook.clean).filter { !$0.isEmpty }
        symbolBook.manual.removeAll { clean.contains($0.symbol) }
        for s in clean where !symbolBook.hidden.contains(s) { symbolBook.hidden.append(s) }
        symbolBook.hidden.sort()
        saveSymbols()
    }

    func unhideSymbols(_ symbols: Set<String>) {
        symbolBook.hidden.removeAll { symbols.contains($0) }
        saveSymbols()
    }
}
