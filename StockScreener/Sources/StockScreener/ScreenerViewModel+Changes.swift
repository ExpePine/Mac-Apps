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
        let group = settings.filterGroup
        let watch = Set(watchlists.flatMap { $0.items.map { $0.symbol.uppercased() } })
        let watchCols = changeWatchColumnIndices
        let scopeName = settings.changeStockScope
        Task { [weak self] in
            guard let self, let previous = await self.loadAlignedDay(day) else {
                self?.isComputingChanges = false
                self?.changeStatus = "Couldn't read the stored day \(day)"
                return
            }
            var issues: [String] = []
            let pNow = FilterCompiler.compile(group, table: current, issues: &issues)
            let pBefore = FilterCompiler.compile(group, table: previous, issues: &issues)
            let results = await Task.detached(priority: .userInitiated) { () -> ([UUID: ChangeResult], [StockChange]) in
                let fNow = ChangeEngine.symbols(current, label: label, where: pNow)
                let fBefore = ChangeEngine.symbols(previous, label: label, where: pBefore)
                var out: [UUID: ChangeResult] = [:]
                for card in cards {
                    out[card.id] = ChangeEngine.evaluate(card, current: current, previous: previous, label: label,
                                                         filterNow: fNow, filterBefore: fBefore, watch: watch)
                }
                let scope: Set<String>? = scopeName == "All stocks" ? nil : (scopeName == "Watchlists" ? watch : fNow)
                let byStock = ChangeEngine.byStock(current: current, previous: previous, label: label, columns: watchCols,
                                                   scope: scope, filterNow: fNow, filterBefore: fBefore)
                return (out, byStock)
            }.value
            self.changeResults = results.0
            self.stockChanges = results.1
            self.changeComparedDay = day
            self.isComputingChanges = false
        }
    }
}
