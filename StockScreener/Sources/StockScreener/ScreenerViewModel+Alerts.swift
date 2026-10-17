import SwiftUI

// MARK: - MV2 date check

struct InAppAlert: Identifiable {
    var id: UUID { triggerID }
    let triggerID: UUID
    let name: String
    let stocks: [String]
}

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
        guard hasData else {
            return MV2Status(state: .unknown, text: "No data imported yet")
        }
        guard let monthCol = table.index(of: cfg.monthColumn), let dayCol = table.index(of: cfg.dayColumn) else {
            return MV2Status(state: .unknown,
                             text: "Columns \(cfg.monthColumn) / \(cfg.dayColumn) not found in the sheet")
        }
        let todayText = today.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        var otherDay: String?

        for row in rows {
            let m = row.text(monthCol), d = row.text(dayCol)
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
        let monthName = headers[monthCol], dayName = headers[dayCol]
        if let otherDay {
            return MV2Status(state: .notUpdated,
                             text: "MV2 not updated: \(monthName)/\(dayName) say \(otherDay), expected \(todayText)")
        }
        return MV2Status(state: .unknown, text: "Couldn't read dates in \(monthName) / \(dayName)")
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
        for trigger in settings.buyTriggers where trigger.isEnabled && trigger.sendEmail {
            await checkBuyTrigger(trigger, force: false)
        }
    }

    /// In-app alerts: which enabled rules are met right now, and by which stocks.
    func computeInAppAlerts() -> [InAppAlert] {
        settings.buyTriggers
            .filter { $0.isEnabled && $0.alertInApp && $0.filter.activeCount > 0 }
            .compactMap { t in
                let matches = buyMatches(t)
                guard !matches.isEmpty else { return nil }
                recordAlertEvents(rule: t, rows: matches, kind: .alert)
                return InAppAlert(triggerID: t.id, name: t.name, stocks: matches.map { rowKey($0) })
            }
    }

    /// Shows the "Conditions met" pop-up (on launch) or banner (on new data).
    func raiseInAppAlerts(asPopup: Bool) {
        let alerts = computeInAppAlerts()
        inAppAlerts = alerts
        guard !alerts.isEmpty else { return }
        if asPopup { showAlertsPopup = true } else { showAlertsBanner = true }
        let summary = alerts.map { "\($0.name): \($0.stocks.count)" }.joined(separator: ", ")
        addLog("In-app alert", summary, success: true)
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
        guard let rule = Self.compileRules([trigger], table: table).first, rule.predicate != nil else { return [] }
        let label = labelIndex
        return rows.filter { rule.matches($0, label) }
    }

    func triggerIssues(_ trigger: BuyTrigger) -> [String] {
        var issues: [String] = []
        _ = FilterCompiler.compile(trigger.filter, table: table, issues: &issues)
        return issues
    }

    func rowKey(_ row: SheetRow) -> String {
        if let label = labelIndex {
            let value = row.text(label).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return "row \(row.id + 2)"   // sheet row number (header is row 1)
    }

    /// Emails rows that newly meet the trigger today. force = "Check now": includes rows already emailed.
    func checkBuyTrigger(_ trigger: BuyTrigger, force: Bool) async {
        rollAlertDayIfNeeded()
        guard trigger.filter.activeCount > 0 else {
            if force { addLog(trigger.name, "This trigger has no conditions yet.", success: false) }
            return
        }
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

        // Columns to show: stock name, every column the conditions use, then the trigger column.
        var columns: [Int] = []
        for c in [labelIndex] + FilterCompiler.referencedColumns(trigger.filter, table: table).map({ Optional($0) })
                 + [table.index(of: settings.triggerColumn)] {
            if let c, !columns.contains(c) { columns.append(c) }
        }

        let names = fresh.prefix(5).map { rowKey($0) }.joined(separator: ", ")
        let more = fresh.count > 5 ? " +\(fresh.count - 5) more" : ""
        let subject = "\(trigger.name): \(names)\(more)"
        let conditionText = Self.describe(trigger.filter)

        let textRows = fresh.map { row in
            columns.map { "\(headers[$0]): \(row.text($0))" }.joined(separator: " | ")
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
        let headerHTML = columns.map { "<th style=\"text-align:left;padding:6px 10px;border-bottom:2px solid #ccc\">\(esc(headers[$0]))</th>" }.joined()
        let rowsHTML = fresh.map { row in
            "<tr>" + columns.map { "<td style=\"padding:6px 10px;border-bottom:1px solid #eee\">\(esc(row.text($0)))</td>" }.joined() + "</tr>"
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
            recordAlertEvents(rule: trigger, rows: fresh, kind: .email)
            var sent = alertState.buySent[trigger.id.uuidString] ?? []
            for row in fresh where !sent.contains(rowKey(row)) { sent.append(rowKey(row)) }
            alertState.buySent[trigger.id.uuidString] = sent
        }
    }

    /// Plain-English summary of a filter, e.g. "CLOSE > 100 AND (RSI ≥ 60 OR VOL > AVGVOL × 2)".
    static func describe(_ group: FilterGroup) -> String {
        guard group.isEnabled else { return "" }
        var parts: [String] = group.conditions.filter(\.isEnabled).map { c in
            if c.kind == .formula { return c.formula }
            switch c.op {
            case .hasValue, .isEmpty: return "\(c.column) \(c.op.rawValue)"
            case .between: return "\(c.column) between \(c.value) and \(c.value2)"
            default:
                if c.target == .column {
                    let f = c.factor.trimmingCharacters(in: .whitespaces)
                    return "\(c.column) \(c.op.rawValue) \(c.otherColumn)\(f.isEmpty || f == "1" ? "" : " × \(f)")"
                }
                return "\(c.column) \(c.op.rawValue) \(c.value)"
            }
        }
        parts += group.groups.map { "(\(describe($0)))" }.filter { $0 != "()" }
        let joiner: String
        switch group.mode {
        case .all: joiner = " AND "
        case .any, .notAny: joiner = " OR "
        }
        let joined = parts.joined(separator: joiner)
        return group.mode == .notAny ? "NOT (\(joined))" : joined
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
