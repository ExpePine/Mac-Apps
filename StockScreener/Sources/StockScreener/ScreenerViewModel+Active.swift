import SwiftUI

// MARK: - Active Filter window data

extension ScreenerViewModel {

    /// Finds a sheet column by name, ignoring case and surrounding spaces.
    func resolveColumn(_ name: String) -> String? {
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return nil }
        return headers.first { $0.trimmingCharacters(in: .whitespaces).lowercased() == target }
    }

    var triggerHeader: String? { resolveColumn(settings.triggerColumn) }

    /// Column that names the stock (shown first, used in emails). Defaults to the sheet's first column.
    var labelHeader: String? {
        resolveColumn(settings.labelColumn) ?? headers.first
    }

    /// D_Trigger and every column after it, with the label column in front if it isn't already there.
    var activeColumns: [String] {
        guard let trigger = triggerHeader, let index = headers.firstIndex(of: trigger) else { return [] }
        var columns = Array(headers[index...])
        if let label = labelHeader, !columns.contains(label) {
            columns.insert(label, at: 0)
        }
        return columns
    }

    static func hasValue(_ raw: String?) -> Bool {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["", "0", "-", "—", "false", "no", "n/a", "na", "#n/a"].contains(s)
    }

    /// Rows for the Active Filter window: filtered by its own rules, sorted by D_Trigger.
    var activeRows: [SheetRow] {
        guard let trigger = triggerHeader else { return [] }
        let filters = settings.activeFilterRules.filter { $0.isEnabled && !$0.column.isEmpty }

        var result = rows.filter { row in
            if settings.onlyRowsWithTrigger && !Self.hasValue(row.values[trigger]) { return false }
            guard !filters.isEmpty else { return true }
            switch settings.activeMatchMode {
            case .all: return filters.allSatisfy { $0.matches(row.values) }
            case .any: return filters.contains { $0.matches(row.values) }
            }
        }

        let descending = settings.triggerSortDescending
        result.sort { a, b in
            let order = Self.smartCompare(a.values[trigger] ?? "", b.values[trigger] ?? "")
            if order == .orderedSame { return a.id < b.id }
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        return result
    }

    /// Compares as dates if both are dates, else as numbers, else as text. Blanks sort last.
    static func smartCompare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.trimmingCharacters(in: .whitespaces), y = b.trimmingCharacters(in: .whitespaces)
        if x.isEmpty || y.isEmpty {
            if x.isEmpty && y.isEmpty { return .orderedSame }
            return x.isEmpty ? .orderedDescending : .orderedAscending
        }
        if let dx = DateParser.parse(x), let dy = DateParser.parse(y) {
            return dx == dy ? .orderedSame : (dx < dy ? .orderedAscending : .orderedDescending)
        }
        if let nx = NumberParser.parse(x), let ny = NumberParser.parse(y) {
            return nx == ny ? .orderedSame : (nx < ny ? .orderedAscending : .orderedDescending)
        }
        return x.localizedStandardCompare(y)
    }

    /// The shade for one cell: first enabled rule for that column that matches.
    func shade(for row: SheetRow, column: String) -> Shade? {
        for rule in settings.cellRules
        where rule.condition.isEnabled && rule.condition.column == column && rule.condition.matches(row.values) {
            return rule.shade == .none ? nil : rule.shade
        }
        return nil
    }
}

// MARK: - MV2 date check

struct MV2Status {
    enum State { case ok, notUpdated, unknown }
    let state: State
    let text: String
}

extension ScreenerViewModel {

    /// The date MV2 should carry: today, or the previous Friday on weekends when weekends are skipped.
    func mv2ExpectedDate(today: Date = Date()) -> Date {
        let cal = Calendar.current
        var day = today
        if settings.mv2.skipWeekends {
            while cal.isDateInWeekend(day) {
                day = cal.date(byAdding: .day, value: -1, to: day) ?? day
            }
        }
        return day
    }

    func mv2Status(today realToday: Date = Date()) -> MV2Status {
        let today = mv2ExpectedDate(today: realToday)
        let isWeekendFallback = !Calendar.current.isDate(today, inSameDayAs: realToday)
        let cfg = settings.mv2
        guard !rows.isEmpty else {
            return MV2Status(state: .unknown, text: "No data downloaded yet")
        }
        guard let monthCol = resolveColumn(cfg.monthColumn), let dayCol = resolveColumn(cfg.dayColumn) else {
            return MV2Status(state: .unknown,
                             text: "Columns \(cfg.monthColumn) / \(cfg.dayColumn) not found in the sheet")
        }
        let todayText = today.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        var otherDay: String?

        for row in rows {
            let m = row.values[monthCol] ?? "", d = row.values[dayCol] ?? ""
            switch DayMatcher.matchesToday(monthCell: m, dayCell: d, today: today) {
            case true?:
                let when = isWeekendFallback ? "the last weekday, \(todayText) (weekend)" : "today"
                return MV2Status(state: .ok,
                                 text: "MV2 is dated \(when) (\(DayMatcher.describe(monthCell: m, dayCell: d)))")
            case false?:
                if otherDay == nil { otherDay = DayMatcher.describe(monthCell: m, dayCell: d) }
            case nil:
                continue
            }
        }
        if let otherDay {
            return MV2Status(state: .notUpdated,
                             text: "MV2 not updated: \(monthCol)/\(dayCol) say \(otherDay), expected \(todayText)")
        }
        return MV2Status(state: .unknown, text: "Couldn't read dates in \(monthCol) / \(dayCol)")
    }
}

// MARK: - Alerts: MV2 email and buy triggers

extension ScreenerViewModel {

    private static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func rollAlertDayIfNeeded() {
        let key = Self.dayKey()
        if alertState.day != key {
            alertState.day = key
            alertState.mv2Alerted = false
            alertState.buySent = [:]
        }
    }

    /// Called after every download whose content changed.
    func runAlertChecks() async {
        rollAlertDayIfNeeded()
        await checkMV2(force: false)
        for trigger in settings.buyTriggers where trigger.isEnabled {
            await checkBuyTrigger(trigger, force: false)
        }
    }

    // MV2

    /// force = "Check now" button: ignores weekends and the once-a-day limit.
    func checkMV2(force: Bool) async {
        rollAlertDayIfNeeded()
        let cfg = settings.mv2
        guard cfg.isEnabled || force else { return }
        if !force && cfg.skipWeekends && Calendar.current.isDateInWeekend(Date()) { return }

        let status = mv2Status()
        guard status.state == .notUpdated else {
            addLog("MV2 check", status.text, success: status.state == .ok)
            return
        }
        guard force || !alertState.mv2Alerted else { return }

        let body = """
        \(status.text)

        The MV2 sheet was refreshed, but its \(cfg.monthColumn) / \(cfg.dayColumn) values don't match today's date.
        Checked at \(Date().formatted(date: .abbreviated, time: .shortened)) by Stock Screener on your Mac.
        """
        if await sendEmail(subject: cfg.subject, body: body, recipients: "", logTitle: "MV2 alert"), !force {
            alertState.mv2Alerted = true
        }
    }

    // Buy triggers

    func buyMatches(_ trigger: BuyTrigger) -> [SheetRow] {
        let conditions = trigger.conditions.filter { $0.isEnabled && !$0.column.isEmpty }
        guard !conditions.isEmpty else { return [] }
        return rows.filter { row in
            switch trigger.matchMode {
            case .all: return conditions.allSatisfy { $0.matches(row.values) }
            case .any: return conditions.contains { $0.matches(row.values) }
            }
        }
    }

    func rowKey(_ row: SheetRow) -> String {
        if let label = labelHeader, let value = row.values[label],
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return value.trimmingCharacters(in: .whitespaces)
        }
        return "row \(row.id + 2)"   // sheet row number (header is row 1)
    }

    /// Emails rows that newly meet the trigger today. force = "Check now": includes rows already emailed.
    func checkBuyTrigger(_ trigger: BuyTrigger, force: Bool) async {
        rollAlertDayIfNeeded()
        let matches = buyMatches(trigger)
        let already = Set(alertState.buySent[trigger.id.uuidString] ?? [])
        let fresh = force ? matches : matches.filter { !already.contains(rowKey($0)) }

        guard !fresh.isEmpty else {
            if force {
                addLog(trigger.name, matches.isEmpty ? "No stocks meet the conditions right now."
                                                     : "All \(matches.count) matches were already emailed today.",
                       success: true)
            }
            return
        }

        // Columns to show: label, each condition's column, then the trigger column.
        var columns: [String] = []
        for c in [labelHeader] + trigger.conditions.map({ Optional($0.column) }) + [triggerHeader] {
            if let c, !c.isEmpty, headers.contains(c), !columns.contains(c) { columns.append(c) }
        }

        let names = fresh.prefix(5).map { rowKey($0) }.joined(separator: ", ")
        let more = fresh.count > 5 ? " +\(fresh.count - 5) more" : ""
        let subject = "\(trigger.name): \(names)\(more)"

        let conditionText = trigger.conditions.filter { $0.isEnabled && !$0.column.isEmpty }.map { c in
            c.op.needsSecondValue ? "\(c.column) between \(c.value) and \(c.value2)" : "\(c.column) \(c.op.rawValue) \(c.value)"
        }.joined(separator: trigger.matchMode == .all ? " AND " : " OR ")

        let textRows = fresh.map { row in
            columns.map { "\($0): \(row.values[$0] ?? "")" }.joined(separator: " | ")
        }.joined(separator: "\n")
        let body = """
        \(fresh.count) stock(s) meet "\(trigger.name)":
        \(conditionText)

        \(textRows)

        Sent by Stock Screener at \(Date().formatted(date: .abbreviated, time: .shortened)).
        """

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let headerHTML = columns.map { "<th style=\"text-align:left;padding:6px 10px;border-bottom:2px solid #ccc\">\(esc($0))</th>" }.joined()
        let rowsHTML = fresh.map { row in
            "<tr>" + columns.map { "<td style=\"padding:6px 10px;border-bottom:1px solid #eee\">\(esc(row.values[$0] ?? ""))</td>" }.joined() + "</tr>"
        }.joined()
        let html = """
        <div style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;color:#222">
        <h2 style="margin:0 0 6px;color:#1a7f37">\(esc(trigger.name))</h2>
        <p style="margin:0 0 12px;color:#555">\(fresh.count) stock(s) meet: <b>\(esc(conditionText))</b></p>
        <table style="border-collapse:collapse">\(headerHTML.isEmpty ? "" : "<tr>\(headerHTML)</tr>")\(rowsHTML)</table>
        <p style="margin-top:14px;color:#888;font-size:12px">Sent by Stock Screener at \(esc(Date().formatted(date: .abbreviated, time: .shortened))).</p>
        </div>
        """

        if await sendEmail(subject: subject, body: body, html: html, recipients: trigger.recipients, logTitle: trigger.name) {
            var sent = alertState.buySent[trigger.id.uuidString] ?? []
            for row in fresh where !sent.contains(rowKey(row)) { sent.append(rowKey(row)) }
            alertState.buySent[trigger.id.uuidString] = sent
        }
    }

    // Email + log

    @discardableResult
    func sendEmail(subject: String, body: String, html: String? = nil,
                   recipients: String, logTitle: String) async -> Bool {
        isSendingEmail = true
        defer { isSendingEmail = false }
        do {
            try await Mailer.send(settings.email, overrideRecipients: recipients,
                                  subject: subject, body: body, html: html)
            addLog(logTitle, "Email sent: \(subject)", success: true)
            return true
        } catch {
            addLog(logTitle, "Email failed: \(error.localizedDescription)", success: false)
            return false
        }
    }

    func sendTestEmail() async {
        await sendEmail(subject: "Stock Screener test email",
                        body: "If you can read this, Stock Screener can send your MV2 and buy-trigger alerts.",
                        recipients: "", logTitle: "Test email")
    }

    func addLog(_ title: String, _ detail: String, success: Bool) {
        alertState.log.insert(AlertLogEntry(title: title, detail: detail, success: success), at: 0)
        if alertState.log.count > 100 { alertState.log.removeLast(alertState.log.count - 100) }
    }
}
