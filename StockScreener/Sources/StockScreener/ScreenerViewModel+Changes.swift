import Foundation

extension ScreenerViewModel {

    /// Stored days older than the live data, newest first (what the Changes screen can compare with).
    var changeDayOptions: [String] {
        let live = HistoryStore.dayKey(dataDay(of: table))
        return historyDays.filter { $0 < live }.reversed()
    }

    /// "By stock" columns: the ones you picked, else the Filter screen's columns (without the stock name).
    var changeWatchColumnIndices: [Int] {
        let picked = settings.changeWatchColumns.compactMap { table.index(of: $0) }
        let cols = settings.changeWatchColumns.isEmpty ? filterColumnIndices : picked
        return cols.filter { $0 != labelIndex }
    }

    /// The close column for price alerts: D_close, else a column named like "close".
    var closeColumnName: String {
        if let i = table.index(of: "D_close") { return headers[i] }
        return headers.first { $0.lowercased().contains("close") } ?? headers.first ?? ""
    }

    /// Manual alerts (rules for one stock).
    var manualAlerts: [BuyTrigger] { settings.buyTriggers.filter { !$0.symbol.isEmpty } }

    /// Adds a one-stock alert, e.g. D_close > 1250 for TATAMOTORS.
    func addManualAlert(symbol: String, column: String, op: RuleOperator, value: String, email: Bool) {
        var rule = BuyTrigger(isEnabled: true, name: "\(symbol): \(column) \(op.rawValue) \(value)")
        rule.symbol = symbol
        rule.filter = FilterGroup(conditions: [FilterCondition(column: column, op: op, value: value)])
        rule.sendEmail = email
        rule.alertInApp = true
        settings.buyTriggers.append(rule)
    }

    /// A stored day's table with the delivery columns (DLVR / Safety / DQ_PRANK) as they were on that day.
    func withDeliveryValues(_ t: SheetTable, asOf day: String) -> SheetTable {
        let dc = DeliveryCenter.shared
        guard !dc.storedDays.isEmpty, let label = labelIndex else { return t }
        let names = ["DLVR", "Safety", "DQ_PRANK", "JUMP", "DELSMA", "STREAK", "DLVR (NSE)", "Safety (NSE)", "DQ_PRANK (NSE)", "JUMP (NSE)", "DELSMA (NSE)", "STREAK (NSE)"]
        let idx = names.compactMap { n in t.headers.firstIndex(of: n).map { (n, $0) } }
        guard !idx.isEmpty else { return t }
        let cols = DeliveryColumns.all(dc.book, asOf: day)
        let rows = t.rows.map { r -> SheetRow in
            var cells = r.cells, nums = r.numbers
            let c = cols[r.text(label).trimmingCharacters(in: .whitespaces).uppercased()]
            for (n, i) in idx where i < cells.count {
                let v: Double?
                if n.hasPrefix("DLVR") { v = c?.dlvr ?? 0 } else if n.hasPrefix("Safety") { v = c?.safety } else if n.hasPrefix("JUMP") { v = c?.jump } else if n.hasPrefix("DELSMA") { v = c?.delSma } else if n.hasPrefix("STREAK") { v = c?.streak.map(Double.init) } else { v = c?.pctRank }
                cells[i] = v.map { n.hasPrefix("DLVR") ? ($0 == 0 ? "0" : String(format: "%.2f", $0)) : (n.hasPrefix("Safety") || n.hasPrefix("STREAK") ? String(format: "%.0f", $0) : (n.hasPrefix("JUMP") ? String(format: "%.2f", $0) : String(format: "%.1f", $0))) } ?? ""
                nums[i] = v
            }
            return SheetRow(id: r.id, cells: cells, numbers: nums)
        }
        return SheetTable(headers: t.headers, rows: rows, originalHeaders: t.originalHeaders)
    }

    /// Recomputes every card: live data vs the chosen (or previous) stored day.
    func computeChanges() {
        guard hasData, let label = labelIndex else { changeStatus = "No data imported yet"; return }
        let options = changeDayOptions
        guard let day = changeCompareDay.flatMap({ d in options.contains(d) ? d : nil }) ?? options.first else {
            changeResults = [:]
            changeComparedDay = nil
            changeStatus = "No earlier day stored yet — the app saves one snapshot per trading day. Come back after the next update."
            return
        }
        isComputingChanges = true
        changeStatus = nil
        let current = table
        let cards = settings.changeCards.filter(\.isEnabled)
        let deliveryDay = day
        let group = settings.filterGroup
        let watch = Set(watchlists.flatMap { $0.items.map { $0.symbol.uppercased() } })
        let conds = settings.changeConditions.filter { current.index(of: $0.column) != nil }
        let watchCols = changeWatchColumnIndices + conds.compactMap { current.index(of: $0.column) }.filter { !changeWatchColumnIndices.contains($0) }
        let scopeName = settings.changeStockScope
        Task { [weak self] in
            guard let self, let loaded = await self.loadAlignedDay(day) else {
                self?.isComputingChanges = false
                self?.changeStatus = "Couldn't read the stored day \(day)"
                return
            }
            let previous = self.withDeliveryValues(loaded, asOf: deliveryDay)   // DLVR / Safety / DQ_PRANK as they were that day
            var issues: [String] = []
            let pNow = FilterCompiler.compile(group, table: current, issues: &issues)
            let pBefore = FilterCompiler.compile(group, table: previous, issues: &issues)
            let condPreds: [(String, Bool, RowPredicate?, RowPredicate?)] = conds.map { c in
                let fc = FilterCondition(column: c.column, op: c.op, value: c.value)
                return (c.label, c.became, FilterCompiler.compile(fc, table: current, issues: &issues), FilterCompiler.compile(fc, table: previous, issues: &issues))
            }
            let results = await Task.detached(priority: .userInitiated) { () -> ([UUID: ChangeResult], [StockChange], [String: [String]]) in
                let fNow = ChangeEngine.symbols(current, label: label, where: pNow)
                let fBefore = ChangeEngine.symbols(previous, label: label, where: pBefore)
                var out: [UUID: ChangeResult] = [:]
                for card in cards {
                    out[card.id] = ChangeEngine.evaluate(card, current: current, previous: previous, label: label,
                                                         filterNow: fNow, filterBefore: fBefore, watch: watch)
                }
                let scope: Set<String>? = scopeName == "All stocks" ? nil : (scopeName == "Watchlists" ? watch : fNow)
                // conditions: which stocks moved this way
                var matches: [String: [String]] = [:]
                if !condPreds.isEmpty {
                    func key(_ r: SheetRow) -> String { r.text(label).trimmingCharacters(in: .whitespaces).uppercased() }
                    var before: [String: SheetRow] = [:]
                    for r in previous.rows { let k = key(r); if !k.isEmpty, before[k] == nil { before[k] = r } }
                    for r in current.rows {
                        let k = key(r)
                        guard !k.isEmpty, matches[k] == nil else { continue }
                        if let scope, !scope.contains(k) { continue }
                        var met: [String] = []
                        for (name, became, now, then) in condPreds {
                            guard let now, now(r) else { continue }
                            if became, let b = before[k], let then, then(b) { continue }     // was already true → didn't move
                            met.append(name)
                        }
                        if !met.isEmpty { matches[k] = met }
                    }
                }
                let byStock = ChangeEngine.byStock(current: current, previous: previous, label: label, columns: watchCols,
                                                   scope: scope, filterNow: fNow, filterBefore: fBefore, include: Set(matches.keys))
                return (out, byStock, matches)
            }.value
            self.changeResults = results.0
            self.stockChanges = results.1
            self.stockChangeMatches = results.2
            self.changeComparedDay = day
            self.isComputingChanges = false
        }
    }
}
