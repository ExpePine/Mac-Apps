import SwiftUI
import AppKit

// MARK: - E column status

/// Status of a stock's E button on the Filter screen.
enum EState {
    case none          // light grey: no rule set for this stock
    case configured    // orange: a rule is set for this stock, not met
    case met           // green: an Email / Alert rule is met for this stock

    var nsColor: NSColor {
        switch self {
        case .none:       return NSColor.secondaryLabelColor.withAlphaComponent(0.18)
        case .configured: return NSColor.systemOrange
        case .met:        return NSColor.systemGreen
        }
    }
}

/// A rule turned into a fast test.
struct CompiledRule {
    let id: UUID
    let symbol: String           // "" = every stock
    let predicate: RowPredicate?

    func applies(to row: SheetRow, _ labelColumn: Int?) -> Bool {
        guard !symbol.isEmpty else { return true }
        guard let c = labelColumn else { return false }
        return row.text(c).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(symbol) == .orderedSame
    }

    func matches(_ row: SheetRow, _ labelColumn: Int?) -> Bool {
        guard let predicate, applies(to: row, labelColumn) else { return false }
        return predicate(row)
    }
}

extension ScreenerViewModel {

    nonisolated static func compileRules(_ rules: [BuyTrigger], table: SheetTable) -> [CompiledRule] {
        rules.map { rule in
            var ignored: [String] = []
            return CompiledRule(id: rule.id,
                                symbol: rule.symbol.trimmingCharacters(in: .whitespaces),
                                predicate: rule.filter.activeCount > 0
                                    ? FilterCompiler.compile(rule.filter, table: table, issues: &ignored) : nil)
        }
    }

    /// grey / orange / green for every row shown on the Filter screen.
    nonisolated static func eStatuses(rows: [SheetRow], rules: [CompiledRule], labelColumn: Int?) -> [Int: EState] {
        guard !rules.isEmpty else { return [:] }
        let perStock = rules.filter { !$0.symbol.isEmpty }
        let global = rules.filter { $0.symbol.isEmpty && $0.predicate != nil }
        var out: [Int: EState] = [:]
        for row in rows {
            let own = perStock.filter { $0.applies(to: row, labelColumn) }
            if own.contains(where: { $0.matches(row, labelColumn) }) || global.contains(where: { $0.matches(row, labelColumn) }) {
                out[row.id] = .met
            } else if !own.isEmpty {
                out[row.id] = .configured
            }
        }
        return out
    }

    /// Rules that belong to one stock (from its E button).
    func rules(for stock: String) -> [BuyTrigger] {
        settings.buyTriggers.filter { $0.symbol.caseInsensitiveCompare(stock) == .orderedSame }
    }

    func stockName(_ row: SheetRow) -> String { rowKey(row) }

    // MARK: - Filter time slider

    /// Shows the time slider with the last 30 stored days (plus Live at the end).
    func openTimeline() {
        refreshHistoryInfo()
        timelineDays = Array(HistoryStore.days().suffix(30))
        showTimeline = true
    }

    func closeTimeline() {
        pauseTimeline()
        showTimeline = false
        goLive()
    }

    /// Slider positions: 0..<days.count are stored days, days.count is Live.
    var timelinePosition: Int { timelineIndex ?? timelineDays.count }

    func goLive() {
        timelineLoadTask?.cancel()
        timelineIndex = nil
        timelineTable = nil
        isTimelineLoading = false
        scheduleFilterRecompute(delayMs: 0)
    }

    func setTimelinePosition(_ position: Int) {
        guard position < timelineDays.count, position >= 0 else { goLive(); return }
        let day = timelineDays[position]
        timelineIndex = position
        timelineLoadTask?.cancel()
        if let cached = timelineCache[day] {
            timelineTable = cached
            scheduleFilterRecompute(delayMs: 0)
            prefetch(position + 1)
            return
        }
        isTimelineLoading = true
        timelineLoadTask = Task { [weak self] in
            guard let self else { return }
            let t = await self.loadAlignedDay(day)
            if Task.isCancelled || self.timelineIndex != position { return }
            self.isTimelineLoading = false
            self.timelineTable = t
            self.scheduleFilterRecompute(delayMs: 0)
            self.prefetch(position + 1)
        }
    }

    func playTimeline(secondsPerDay: Double) {
        guard !timelineDays.isEmpty else { return }
        if timelineIndex == nil { setTimelinePosition(0) }      // start 30 days back
        isTimelinePlaying = true
        timelinePlayTask?.cancel()
        timelinePlayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(secondsPerDay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if self.isTimelineLoading { continue }                 // wait for the day to load
                let next = self.timelinePosition + 1
                if next >= self.timelineDays.count {
                    self.goLive()
                    self.isTimelinePlaying = false
                    return
                }
                self.setTimelinePosition(next)
            }
        }
    }

    func pauseTimeline() {
        timelinePlayTask?.cancel()
        timelinePlayTask = nil
        isTimelinePlaying = false
    }

    private func prefetch(_ position: Int) {
        guard position >= 0, position < timelineDays.count else { return }
        let day = timelineDays[position]
        guard timelineCache[day] == nil else { return }
        Task { [weak self] in _ = await self?.loadAlignedDay(day) }
    }

    /// A stored day, with its columns lined up with today's table so filters and colors apply unchanged.
    func loadAlignedDay(_ day: String) async -> SheetTable? {
        if let cached = timelineCache[day] { return cached }
        let current = table
        let aligned = await Task.detached(priority: .userInitiated) { () -> SheetTable? in
            HistoryStore.load(day).flatMap { ScreenerViewModel.align($0, to: current) }
        }.value
        if let aligned {
            timelineCache[day] = aligned
            timelineCacheOrder.removeAll { $0 == day }
            timelineCacheOrder.append(day)
            while timelineCacheOrder.count > 8 {           // keep memory bounded
                timelineCache[timelineCacheOrder.removeFirst()] = nil
            }
        }
        return aligned
    }

    /// Parses a stored snapshot and lays its columns out like `current` (matched by sheet names).
    nonisolated static func align(_ data: Data, to current: SheetTable) -> SheetTable? {
        guard let parsed = try? SheetService.parse(data).table else { return nil }
        var byName: [String: Int] = [:]
        for (j, h) in parsed.originalHeaders.enumerated() where byName[SheetTable.normalize(h)] == nil {
            byName[SheetTable.normalize(h)] = j
        }
        let map = current.originalHeaders.map { byName[SheetTable.normalize($0)] }
        let rows = parsed.rows.map { row -> SheetRow in
            let cells = map.map { j in j.map { row.text($0) } ?? "" }
            let numbers = map.map { j in j.flatMap { row.number($0) } }
            return SheetRow(id: row.id, cells: cells, numbers: numbers)
        }
        return SheetTable(headers: current.headers, rows: rows, originalHeaders: current.originalHeaders)
    }

    func clearTimelineCache() {
        timelineCache.removeAll()
        timelineCacheOrder.removeAll()
    }

    var timelineDateText: String {
        guard let i = timelineIndex, i < timelineDays.count,
              let date = HistoryStore.date(fromKey: timelineDays[i]) else { return "Live (today's data)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    // MARK: - Alert events (Alerts browser)

    var unreadAlertCount: Int {
        alertEvents.filter { $0.date > alertsLastSeen }.count
    }

    func markAlertsSeen() {
        alertsLastSeen = Date()
        UserDefaults.standard.set(alertsLastSeen, forKey: "StockScreener.alertsLastSeen")
    }

    /// Adds one event per (rule, stock, kind) per trading day.
    func recordAlertEvents(rule: BuyTrigger, rows: [SheetRow], kind: AlertEvent.Kind) {
        guard !rows.isEmpty else { return }
        let day = HistoryStore.dayKey(dataDay(of: table))
        let columns = alertColumns(for: rule)
        let conditions = Self.describe(rule.filter)
        var added: [AlertEvent] = []
        for row in rows {
            let stock = rowKey(row)
            let exists = alertEvents.contains {
                ($0.ruleID == rule.id || $0.ruleName == rule.name) && $0.stock == stock && $0.kind == kind && $0.dataDay == day
            }
            if exists { continue }
            added.append(AlertEvent(kind: kind, ruleID: rule.id, ruleName: rule.name, stock: stock, dataDay: day,
                                    values: columns.prefix(8).map { "\(headers[$0]): \(row.text($0))" },
                                    conditions: conditions))
        }
        guard !added.isEmpty else { return }
        alertEvents.insert(contentsOf: added, at: 0)
        if alertEvents.count > AlertEventStore.maxEvents { alertEvents.removeLast(alertEvents.count - AlertEventStore.maxEvents) }
        AlertEventStore.save(alertEvents)
    }

    /// % change of the stock from the close on the alert's data day to the latest close (Yahoo).
    func alertChange(_ e: AlertEvent) -> Double? {
        guard let s = priceBook.series(for: e.stock), let i = s.index(onOrBefore: e.dataDay), s.closes[i] > 0,
              let last = s.closes.last else { return nil }
        return (last / s.closes[i] - 1) * 100
    }

    func deleteAlertEvents(where match: (AlertEvent) -> Bool) {
        alertEvents.removeAll(where: match)
        AlertEventStore.save(alertEvents)
    }

    func clearAlertEvents() {
        alertEvents.removeAll()
        AlertEventStore.save(alertEvents)
    }

    /// Columns a rule's email / alert should show: stock name, the columns the conditions use, trigger column.
    func alertColumns(for rule: BuyTrigger) -> [Int] {
        var columns: [Int] = []
        for c in [labelIndex] + FilterCompiler.referencedColumns(rule.filter, table: table).map({ Optional($0) })
                 + [table.index(of: settings.triggerColumn)] {
            if let c, !columns.contains(c) { columns.append(c) }
        }
        return columns
    }
}
