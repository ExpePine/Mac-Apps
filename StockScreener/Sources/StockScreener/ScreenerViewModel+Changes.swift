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
    /// Every column the app computes from NSE delivery data (stored snapshots hold only the sheet, so these are
    /// empty for past days until recomputed here).
    static let deliveryColumnNames = ["DLVR", "Safety", "DQ_PRANK", "JUMP", "DELSMA", "STREAK", "t3Color", "HI/T3",
                                      "DAYS_DELSMA", "DELSMAC", "DEL2", "DEL2C", "C/DL2C", "NSE_SERIES", "DEAL_PRANK", "STEEP_Z", "Z_PRANK", "Z_PRANK_DAYS"]
    static func isDeliveryColumn(_ h: String) -> Bool {
        var base = h.hasSuffix(" (NSE)") ? String(h.dropLast(6)) : h
        if base.hasPrefix("M_") { base = String(base.dropFirst(2)) }        // monthly versions (M_DELSMA …)
        return deliveryColumnNames.contains(base) || PineColumns.shared.has(h)
    }

    /// The last NSE trading day of the month before `day`'s month (M_ columns hold the values on that day).
    static func monthEnd(before day: String) -> String? {
        let first = String(day.prefix(7)) + "-01"
        return DeliveryCenter.shared.book.days.last { $0 < first }
    }

    /// Fills the M_ columns (M_DELSMA, M_Z_PRANK …) with each delivery column's value at the end of the last
    /// completed month before `day` — a month's figure stays fixed through the next month, like a monthly chart's
    /// closed bar.
    func fillMonthColumns(_ t: SheetTable, day: String) -> SheetTable {
        let mIdx = t.headers.enumerated().filter { $0.element.hasPrefix("M_") && Self.isDeliveryColumn($0.element) }
        guard !mIdx.isEmpty, let label = labelIndex ?? (t.headers.isEmpty ? nil : 0) else { return t }
        guard let me = Self.monthEnd(before: day) else { return t }
        // the same table on the month-end day (memoised: every day of a month uses the same month-end)
        let key = me + "|" + mIdx.map(\.element).joined(separator: ",")
        var bySym: [String: [String: (String, Double?)]]
        if let m = monthMemo[key] { bySym = m } else {
            let base = withDeliveryValues(t, asOf: me, monthCols: false)
            bySym = [:]
            for r in base.rows {
                let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
                var m: [String: (String, Double?)] = [:]
                for (i, h) in base.headers.enumerated() where Self.isDeliveryColumn(h) && !h.hasPrefix("M_") && i < r.cells.count {
                    m[h] = (r.cells[i], i < r.numbers.count ? r.numbers[i] : nil)
                }
                bySym[sym] = m
            }
            if monthMemo.count > 24 { monthMemo = [:] }
            monthMemo[key] = bySym
        }
        let rows = t.rows.map { r -> SheetRow in
            var cells = r.cells, nums = r.numbers
            let m = bySym[r.text(label).trimmingCharacters(in: .whitespaces).uppercased()] ?? [:]
            for (i, h) in mIdx where i < cells.count {
                let baseName = String(h.dropFirst(2))
                let v = m[baseName] ?? m[baseName + " (NSE)"]
                cells[i] = v?.0 ?? ""
                if i < nums.count { nums[i] = v?.1 ?? nil }
            }
            return SheetRow(id: r.id, cells: cells, numbers: nums)
        }
        return SheetTable(headers: t.headers, rows: rows, originalHeaders: t.originalHeaders)
    }

    /// Your Pine scripts' Filter columns (PineCenter), on the sheet's data day.
    func withPineColumns(_ t: SheetTable) -> SheetTable {
        let names = PineColumns.shared.names
        let pc = PineCenter.shared
        if pc.vm == nil { pc.vm = self }
        if names.isEmpty {
            if !pc.autoStarted, !DeliveryCenter.shared.storedDays.isEmpty, pc.scripts.contains(where: { s in s.enabled && s.outputs.values.contains { $0.filter } }) {
                pc.autoStarted = true
                DispatchQueue.main.async { pc.computeColumns() }
            }
            return t
        }
        guard let label = t.index(of: settings.labelColumn) ?? (t.headers.isEmpty ? nil : 0) else { return t }
        let day = HistoryStore.dayKey(dataDay(of: t))
        let rows = t.rows.map { row -> SheetRow in
            let sym = row.text(label).trimmingCharacters(in: .whitespaces).uppercased()
            var cells = row.cells, nums = row.numbers
            for n in names {
                let v = PineColumns.shared.value(n, sym, day)
                cells.append(v.map { String(format: abs($0) >= 1000 ? "%.0f" : "%.3f", $0) } ?? "")
                nums.append(v)
            }
            return SheetRow(id: row.id, cells: cells, numbers: nums)
        }
        return SheetTable(headers: t.headers + names, rows: rows, originalHeaders: t.originalHeaders + names)
    }

    /// The delivery columns as they were on `day` (C/DL2C = that day's close ÷ that day's DEL2C).
    func withDeliveryValues(_ t: SheetTable, asOf day: String, monthCols: Bool = true) -> SheetTable {
        let dc = DeliveryCenter.shared
        guard !dc.storedDays.isEmpty, let label = labelIndex else { return t }
        let idx = t.headers.enumerated().filter { Self.isDeliveryColumn($0.element) }.map { (n: $0.element.hasSuffix(" (NSE)") ? String($0.element.dropLast(6)) : $0.element, i: $0.offset) }
        guard !idx.isEmpty else { return t }
        // only the stocks in this table (a one-row table — the trace-back — then costs one stock, not all of them)
        let cols: [String: DeliveryColumns] = {
            if t.rows.count > 50 { return DeliveryColumns.all(dc.book, asOf: day) }
            var o: [String: DeliveryColumns] = [:]
            let d = dc.book.days.last(where: { $0 <= day }) ?? dc.book.days.last ?? ""
            for r in t.rows {
                let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
                if let s = dc.book.series[sym] { o[sym] = DeliveryColumns.of(s, latestDay: d) }
            }
            return o
        }()
        let rows = t.rows.map { r -> SheetRow in
            var cells = r.cells, nums = r.numbers
            let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
            let c = cols[sym]
            for (n, i) in idx where i < cells.count {
                if n.hasPrefix("M_") { continue }              // filled below from the month-end day
                if PineColumns.shared.has(n) {
                    let v = PineColumns.shared.value(n, sym, day)
                    cells[i] = v.map { String(format: abs($0) >= 1000 ? "%.0f" : "%.3f", $0) } ?? ""; nums[i] = v
                    continue
                }
                if n == "NSE_SERIES" {
                    var code = ""
                    if let bs = dc.book.series[sym], let k = bs.days.lastIndex(where: { $0 <= day }), k < bs.seriesCode.count { code = bs.seriesCode[k] }
                    cells[i] = code; nums[i] = nil
                    continue
                }
                if n == "Z_PRANK" || n == "Z_PRANK_DAYS" {
                    var v: Double? = nil
                    if let bs = dc.book.series[sym], let k = bs.days.lastIndex(where: { $0 <= day }) {
                        let r = Steep.zAndPRank(bs, at: k)
                        v = n == "Z_PRANK" ? r.pr : r.days.map(Double.init)
                    }
                    cells[i] = v.map { String(format: n == "Z_PRANK" ? "%.1f" : "%.0f", $0) } ?? ""; nums[i] = v
                    continue
                }
                if n == "STEEP_Z" {
                    var z: Double? = nil
                    if let bs = dc.book.series[sym], let k = bs.days.lastIndex(where: { $0 <= day }) { z = Steep.zAt(bs, at: k).map { ($0 * 100).rounded() / 100 } }
                    cells[i] = z.map { String(format: "%.2f", $0) } ?? ""; nums[i] = z
                    continue
                }
                if n == "DEAL_PRANK" {
                    var bp: Double? = nil
                    if let bs = dc.book.series[sym], let k = bs.days.lastIndex(where: { $0 <= day }), !DealsCenter.shared.deals.isEmpty {
                        bp = DealsCenter.dealPRank(DealsCenter.shared.sizeByDay(sym), axis: Array(bs.days[...k])).last ?? nil
                    }
                    cells[i] = bp.map { String(format: "%.1f", $0) } ?? ""; nums[i] = bp
                    continue
                }
                let v: Double?, f: String
                switch n {
                case "DLVR": v = c?.dlvr ?? 0; f = "%.2f"
                case "Safety": v = c?.safety; f = "%.0f"
                case "DQ_PRANK": v = c?.pctRank; f = "%.1f"
                case "JUMP": v = c?.jump; f = "%.2f"
                case "DELSMA": v = c?.delSma; f = "%.1f"
                case "STREAK": v = c?.streak.map(Double.init); f = "%.0f"
                case "t3Color": v = c?.t3Color.map(Double.init); f = "%.0f"
                case "HI/T3": v = c?.hiT3; f = "%.2f"
                case "DAYS_DELSMA": v = c?.delsmaDays.map(Double.init); f = "%.0f"
                case "DELSMAC": v = c?.delSmaC; f = "%.1f"
                case "DEL2": v = c?.del2; f = "%.1f"
                case "DEL2C": v = c?.del2c; f = "%.2f"
                default:                                   // C/DL2C on that day
                    let close = Self.close(of: sym, on: day, prices: priceBook.series(for: sym), nse: dc.book.series[sym])
                    v = (close != nil && (c?.del2c ?? 0) > 0) ? close! / c!.del2c! : nil; f = "%.3f"
                }
                cells[i] = v.map { n == "DLVR" && $0 == 0 ? "0" : String(format: f, $0) } ?? ""
                nums[i] = v
            }
            return SheetRow(id: r.id, cells: cells, numbers: nums)
        }
        let out = SheetTable(headers: t.headers, rows: rows, originalHeaders: t.originalHeaders)
        return monthCols ? fillMonthColumns(out, day: day) : out
    }

    /// Close on (or the last trading day before) `day`: Yahoo, else NSE.
    nonisolated static func close(of sym: String, on day: String, prices: PriceSeries?, nse: DeliverySeries?) -> Double? {
        if let p = prices, let i = p.days.lastIndex(where: { $0 <= day }), i < p.closes.count { return p.closes[i] }
        if let s = nse, let i = s.days.lastIndex(where: { $0 <= day }), i < s.close.count { return s.close[i] }
        return nil
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
