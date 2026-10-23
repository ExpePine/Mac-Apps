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
    var mismatched = 0            // rows whose month/day are not the expected date
    var checked = 0               // rows with a readable month/day
    var examples: [String] = []   // a few of the mismatched stocks, with what they say
}

extension ScreenerViewModel {

    /// The date MV2 should carry: today on Mon–Fri; on Sat/Sun, the previous Friday.
    func mv2ExpectedDate(today: Date = Date()) -> Date {
        let cal = Calendar.current
        var day = today
        while cal.isDateInWeekend(day) {
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return day
    }

    /// Counts every row whose month/day don't match the expected date.
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
        let label = labelIndex
        var matched = 0, mismatched = 0
        var seen: [String: Int] = [:]        // what the wrong rows say -> how many
        var examples: [String] = []

        for row in rows {
            let m = row.text(monthCol), d = row.text(dayCol)
            switch DayMatcher.matchesToday(monthCell: m, dayCell: d, today: today) {
            case true?:
                matched += 1
            case false?:
                mismatched += 1
                let said = DayMatcher.describe(monthCell: m, dayCell: d)
                seen[said, default: 0] += 1
                if examples.count < 15 {
                    let name = label.map { row.text($0) } ?? "row \(row.id + 1)"
                    examples.append("\(name): \(said)")
                }
            case nil:
                continue
            }
        }
        let checked = matched + mismatched
        let monthName = headers[monthCol], dayName = headers[dayCol]
        guard checked > 0 else {
            return MV2Status(state: .unknown, text: "Couldn't read dates in \(monthName) / \(dayName)")
        }
        let when = isWeekendFallback ? "the last weekday, \(todayText)" : "today, \(todayText)"
        if mismatched == 0 {
            return MV2Status(state: .ok, text: "MV2 is up to date: all \(checked) rows are dated \(when)",
                             mismatched: 0, checked: checked)
        }
        let saying = seen.sorted { $0.value > $1.value }.prefix(3).map { "\($0.value)× \($0.key)" }.joined(separator: ", ")
        return MV2Status(state: .notUpdated,
                         text: "MV2 not updated: \(mismatched) of \(checked) rows have \(monthName)/\(dayName) not matching \(when) (\(saying))",
                         mismatched: mismatched, checked: checked, examples: examples)
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
        ruleAlerts() + shortlistInAppAlerts() + TrackerCenter.shared.watchAlerts(vm: self)
    }

    private func ruleAlerts() -> [InAppAlert] {
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

    /// Emails only on Monday–Friday. force = "Check now" button: ignores the once-a-day limit.
    func checkMV2(force: Bool) async {
        rollAlertDayIfNeeded()
        let cfg = settings.mv2
        guard cfg.isEnabled || force else { return }

        let status = mv2Status()
        guard status.state == .notUpdated else {
            addLog("MV2 check", status.text, success: status.state == .ok)
            return
        }
        if Calendar.current.isDateInWeekend(Date()) {
            if force { addLog("MV2 check", status.text + " — no email on Sat/Sun", success: false) }
            return
        }
        guard force || !alertState.mv2Alerted else { return }

        var body = """
        \(status.text)

        \(status.mismatched) of \(status.checked) rows in the MV2 sheet have \(cfg.monthColumn) / \(cfg.dayColumn) values that don't match today's date.
        """
        if !status.examples.isEmpty {
            body += "\n\nFor example:\n" + status.examples.map { "• \($0)" }.joined(separator: "\n")
            if status.mismatched > status.examples.count { body += "\n…and \(status.mismatched - status.examples.count) more" }
        }
        body += "\n\nChecked at \(Date().formatted(date: .abbreviated, time: .shortened)) by Stock Screener on your Mac."
        let subject = "\(cfg.subject) (\(status.mismatched) of \(status.checked) rows)"
        if await sendEmail(subject: subject, body: body, recipients: "", logTitle: "MV2 alert"), !force {
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
