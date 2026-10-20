import Foundation

// MARK: - Experiments: your sheet + any number of plain-English commands → plans → numbers
//
// For each command, Groq (or a simple built-in reader) turns your words into a PLAN made of a few building blocks the
// app knows how to compute. You can check / change the plan. All numbers are computed by the app from your sheet and
// Yahoo daily closes; Groq may then write a conclusion from those numbers only.
//
// Tasks:  compare  – returns after entries (trigger columns, or the row date), optionally per group, with filters,
//                    entry delay, target / stop exits
//         gap      – trading days between two date columns
//         describe – numbers / counts of columns, optionally per group
//         relation – does a number column go with better returns afterwards? (rank correlation + Low / Mid / High)

struct ExpTrigger: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var column = ""
    var kind = "date"          // date = cell holds the date · flag = non-empty/1 = triggered on the row date · price = cell is the entry price
    var label = ""
    var name: String { label.isEmpty ? column : label }
}

struct ExpFilter: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var column = ""
    var op = "="               // = ≠ > ≥ < ≤ contains nonempty empty
    var value = ""
}

struct ExpPlan: Codable, Equatable {
    var task = "compare"
    var symbolColumn = ""
    var shortlistColumn = ""       // optional: rows count only when shortlisted
    var shortlistKind = "flag"     // flag · date · symbol
    var baseDateColumn = ""        // the row's date (for flag / price triggers and the row-date entry)
    var filters: [ExpFilter] = []
    var triggers: [ExpTrigger] = []    // compare: entries to compare ([] = the row date)
    var groupBy = ""                   // compare / describe: split by this column
    var groupBuckets = 0               // 0 = by value, 3 = Low / Mid / High of a number column
    var entryDelay = 0                 // trading days after the trigger date (0 = that day's close)
    var targetPercent = 0.0            // exit at +x% (0 = off)
    var stopPercent = 0.0              // exit at −x% (0 = off)
    var gapFrom = ""                   // gap: from this date column…
    var gapTo = ""                     // …to this one
    var columns: [String] = []         // describe: columns · relation: the number column(s)
    var horizons = [5, 10, 21]
    var winPercent = 10.0
    var explanation = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExpPlan()
        func v<T: Decodable>(_ k: CodingKeys, _ x: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? x }
        task = v(.task, d.task); symbolColumn = v(.symbolColumn, d.symbolColumn); shortlistColumn = v(.shortlistColumn, d.shortlistColumn)
        shortlistKind = v(.shortlistKind, d.shortlistKind); baseDateColumn = v(.baseDateColumn, d.baseDateColumn); filters = v(.filters, d.filters)
        triggers = v(.triggers, d.triggers); groupBy = v(.groupBy, d.groupBy); groupBuckets = v(.groupBuckets, d.groupBuckets)
        entryDelay = v(.entryDelay, d.entryDelay); targetPercent = v(.targetPercent, d.targetPercent); stopPercent = v(.stopPercent, d.stopPercent)
        gapFrom = v(.gapFrom, d.gapFrom); gapTo = v(.gapTo, d.gapTo); columns = v(.columns, d.columns); horizons = v(.horizons, d.horizons)
        winPercent = v(.winPercent, d.winPercent); explanation = v(.explanation, d.explanation)
    }
}

struct ExpChat: Codable, Identifiable, Equatable {
    var id = UUID()
    var fromUser: Bool
    var text: String
    var table: String? = nil       // what the app computed for this answer (shown under it)
}

struct ExpCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var plan = ExpPlan()
    var summary = ""
    var createdAt = Date()
    var chat: [ExpChat] = []

    init(text: String = "", plan: ExpPlan = ExpPlan(), summary: String = "") { self.text = text; self.plan = plan; self.summary = summary }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ x: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? x }
        id = v(.id, UUID()); text = v(.text, ""); plan = v(.plan, ExpPlan()); summary = v(.summary, "")
        createdAt = v(.createdAt, Date()); chat = v(.chat, [])
    }
}

struct Experiment: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New experiment"
    var link = ""
    var notes = ""                 // what the columns mean (shared by every command)
    var commands: [ExpCommand] = []
    var createdAt = Date()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func v<T: Decodable>(_ k: String, _ x: T) -> T { (try? c.decodeIfPresent(T.self, forKey: AnyKey(k))) ?? x }
        id = v("id", UUID()); name = v("name", "New experiment"); link = v("link", ""); notes = v("notes", "")
        commands = v("commands", []); createdAt = v("createdAt", Date())
        // older version: one instruction + plan
        let oldText: String = v("instructions", "")
        if commands.isEmpty && !oldText.isEmpty {
            commands = [ExpCommand(text: oldText, plan: v("plan", ExpPlan()), summary: v("summary", ""))]
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id")); try c.encode(name, forKey: AnyKey("name")); try c.encode(link, forKey: AnyKey("link"))
        try c.encode(notes, forKey: AnyKey("notes")); try c.encode(commands, forKey: AnyKey("commands")); try c.encode(createdAt, forKey: AnyKey("createdAt"))
    }
    struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

enum ExperimentFile {
    private static var url: URL { AppFolders.base.appendingPathComponent("experiments.json") }
    static func load() -> [Experiment] {
        guard let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([Experiment].self, from: d) else { return [] }
        return e
    }
    static func save(_ e: [Experiment]) {
        try? FileManager.default.createDirectory(at: AppFolders.base, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - Results (generic: a headline, tables, bars)

struct ExpTable: Identifiable {
    let id = UUID()
    let title: String
    let columns: [String]
    var rows: [[String]]
}

struct ExpBar: Identifiable {
    let id = UUID()
    let series: String, category: String, value: Double
}

struct ExpEntry: Identifiable {
    var id: String { symbol + "|" + arm + "|" + day }
    let symbol: String
    let arm: String
    let day: String
    let entry: Double
    let returns: [Double?]
    let best: [Double?]
    let worst: [Double?]
    let trade: Double?             // with target / stop
    let daysAfterShortlist: Int?
    var rowID: Int = -1            // the sheet row it came from (for questions about other columns)
}

struct ExpResult {
    var headline = ""
    var tables: [ExpTable] = []
    var bars: [ExpBar] = []
    var barTitle = ""
    var notes: [String] = []
    var entries: [ExpEntry] = []
    var rowsUsed = 0

    /// Plain text of everything, for Groq's conclusion.
    var text: String {
        var s = headline + "\n"
        for t in tables {
            s += "\n" + t.title + "\n" + t.columns.joined(separator: " | ") + "\n"
            for r in t.rows { s += r.joined(separator: " | ") + "\n" }
        }
        return s + notes.joined(separator: "\n")
    }
}

// MARK: - Engine

enum ExperimentEngine {

    private static let formats = ["yyyy-MM-dd", "dd-MM-yyyy", "dd/MM/yyyy", "d/M/yyyy", "d-MMM-yyyy", "dd-MMM-yyyy", "d MMM yyyy",
                                  "dd MMM yyyy", "MMM d, yyyy", "d MMM yy", "dd-MMM-yy", "yyyy/MM/dd", "M/d/yyyy", "yyyy-MM-dd HH:mm:ss",
                                  "dd/MM/yyyy HH:mm:ss", "M/d/yyyy H:mm:ss"]
    private static let formatters: [DateFormatter] = formats.map { f in
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = TimeZone(identifier: "Asia/Kolkata"); d.dateFormat = f; return d
    }
    private static let key: DateFormatter = {
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = TimeZone(identifier: "Asia/Kolkata"); d.dateFormat = "yyyy-MM-dd"; return d
    }()

    /// Set per sheet before reading it: does it write 10/19/2026 (month first) or 19/10/2026 (day first)?
    static var monthFirst = false

    static func day(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 6, s.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        if let d = numericDay(s) { return d }
        for f in formatters { if let d = f.date(from: s) { return key.string(from: d) } }
        return nil
    }

    /// 2026-10-19 · 19/10/2026 · 10/19/2026 · 19-10-26 (with an optional time after a space)
    private static func numericDay(_ s: String) -> String? {
        let datePart = s.split(separator: " ").first.map(String.init) ?? s
        let parts = datePart.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." }).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), let a = Int(parts[0]), let b = Int(parts[1]), var c = Int(parts[2]) else { return nil }
        var y: Int, m: Int, d: Int
        if parts[0].count == 4 { y = a; m = b; d = c } else {
            if c < 100 { c += 2000 }
            y = c
            (m, d) = monthFirst ? (a, b) : (b, a)
            if m > 12 && d <= 12 { swap(&m, &d) }            // the other order is the only valid one
        }
        guard (1...12).contains(m), (1...31).contains(d), (1990...2100).contains(y) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Looks at every a/b/yyyy cell: a first number above 12 means day first, a second above 12 means month first.
    static func detectMonthFirst(_ t: SheetTable) -> Bool {
        var dayFirst = 0, monthFirst = 0
        for r in t.rows.prefix(3000) {
            for c in t.headers.indices {
                let parts = r.text(c).split(separator: " ").first.map { $0.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." }) } ?? []
                guard parts.count == 3, parts[0].count <= 2, let a = Int(parts[0]), let b = Int(parts[1]), Int(parts[2]) != nil else { continue }
                if a > 12 { dayFirst += 1 } else if b > 12 { monthFirst += 1 }
            }
        }
        return monthFirst > dayFirst
    }

    /// The row's date column: the one you picked, else a column named like "date", else one that is mostly dates.
    static func rowDateColumn(_ p: ExpPlan, table: SheetTable) -> Int? {
        if !p.baseDateColumn.isEmpty, let i = table.index(of: p.baseDateColumn) { return i }
        if let i = table.headers.firstIndex(where: { ["date", "day", "row date", "trade date", "as of", "asof", "dt"].contains($0.lowercased()) }) { return i }
        let skip = Set(p.triggers.compactMap { table.index(of: $0.column) })
        for c in table.headers.indices where !skip.contains(c) {
            let v = table.rows.prefix(200).map { $0.text(c) }.filter { !$0.isEmpty }
            if v.count >= 5, Double(v.filter { day($0) != nil }.count) / Double(v.count) >= 0.8 { return c }
        }
        return nil
    }

    /// A header from a loose name: exact, else ignoring case / spaces / _ / - ("var 2" → "var2", "COL D" → 4th column).
    static func resolve(_ name: String, in table: SheetTable) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if let i = table.index(of: n) { return table.headers[i] }
        func norm(_ x: String) -> String { x.lowercased().filter { $0.isLetter || $0.isNumber } }
        let k = norm(n)
        if let h = table.headers.first(where: { norm($0) == k }) { return h }
        let up = n.uppercased()
        if up.hasPrefix("COL"), let ch = up.dropFirst(3).trimmingCharacters(in: .whitespaces).first, let a = ch.asciiValue, (65...90).contains(a) {
            let i = Int(a - 65); if i < table.headers.count { return table.headers[i] }
        }
        return nil
    }

    static func isOn(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return !s.isEmpty && !["0", "false", "no", "n", "-", "—", "na", "n/a", "#n/a"].contains(s)
    }

    static func cleanSymbol(_ raw: String) -> String { SymbolBook.clean(raw).replacingOccurrences(of: " ", with: "") }

    static func columnLetter(_ i: Int) -> String {
        var n = i, s = ""
        repeat { s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n = n / 26 - 1 } while n >= 0
        return s
    }

    static func f(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%+.1f%%", $0) } ?? "—" }
    static func mean(_ x: [Double]) -> Double? { x.isEmpty ? nil : x.reduce(0, +) / Double(x.count) }
    static func median(_ x: [Double]) -> Double? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted(); let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    /// Plan columns that aren't in the sheet.
    static func problems(_ p: ExpPlan, table: SheetTable) -> [String] {
        var out: [String] = []
        func check(_ what: String, _ c: String, optional: Bool = true) {
            if c.isEmpty { if !optional { out.append("\(what): pick a column") } } else if table.index(of: c) == nil { out.append("\(what) “\(c)” isn't in the sheet") }
        }
        check("Stock column", p.symbolColumn, optional: p.task == "gap" || p.task == "describe")
        check("Shortlist column", p.shortlistColumn); check("Row date", p.baseDateColumn); check("Group by", p.groupBy)
        for f in p.filters { check("Filter", f.column) }
        switch p.task {
        case "gap": check("Gap from", p.gapFrom, optional: false); check("Gap to", p.gapTo, optional: false)
        case "describe", "relation": if p.columns.isEmpty { out.append("Pick at least one column") }; for c in p.columns { check("Column", c) }
        default: for t in p.triggers { check("Trigger", t.column) }
        }
        return out
    }

    static func symbols(_ p: ExpPlan, table: SheetTable) -> [String] {
        guard let sc = table.index(of: p.symbolColumn) else { return [] }
        return Array(Set(table.rows.map { cleanSymbol($0.text(sc)) }.filter { !$0.isEmpty }))
    }

    static func needsPrices(_ p: ExpPlan) -> Bool { p.task == "compare" || p.task == "relation" }

    // Rows after shortlist + filters
    private static func usableRows(_ p: ExpPlan, table: SheetTable) -> [(row: SheetRow, shortDay: String?)] {
        let lc = p.shortlistColumn.isEmpty ? nil : table.index(of: p.shortlistColumn)
        let filters: [(Int, ExpFilter)] = p.filters.compactMap { f in table.index(of: f.column).map { ($0, f) } }
        var out: [(SheetRow, String?)] = []
        for row in table.rows {
            var shortDay: String?
            if let lc {
                let cell = row.text(lc)
                switch p.shortlistKind {
                case "date": shortDay = day(cell); if shortDay == nil { continue }
                case "symbol": if cleanSymbol(cell).isEmpty { continue }
                default: if !isOn(cell) { continue }; shortDay = day(cell)
                }
            }
            if !filters.allSatisfy({ passes(row, $0.0, $0.1) }) { continue }
            out.append((row, shortDay))
        }
        return out
    }

    static func passes(_ row: SheetRow, _ c: Int, _ f: ExpFilter) -> Bool {
        let t = row.text(c).trimmingCharacters(in: .whitespaces)
        let x = row.number(c) ?? Double(t), y = Double(f.value.trimmingCharacters(in: .whitespaces))
        switch f.op {
        case "nonempty": return isOn(t)
        case "empty": return !isOn(t)
        case "contains": return t.localizedCaseInsensitiveContains(f.value)
        case "≠", "!=": return x != nil && y != nil ? x != y : t.caseInsensitiveCompare(f.value) != .orderedSame
        case ">": return x != nil && y != nil && x! > y!
        case "≥", ">=": return x != nil && y != nil && x! >= y!
        case "<": return x != nil && y != nil && x! < y!
        case "≤", "<=": return x != nil && y != nil && x! <= y!
        default: return x != nil && y != nil ? x == y : t.caseInsensitiveCompare(f.value) == .orderedSame
        }
    }

    /// Group label of each row: the column's value, or Low / Mid / High thirds of a number column.
    private static func groups(_ p: ExpPlan, table: SheetTable, rows: [SheetRow]) -> [Int: String] {
        guard !p.groupBy.isEmpty, let g = table.index(of: p.groupBy) else { return [:] }
        var out: [Int: String] = [:]
        if p.groupBuckets >= 2 {
            let vals = rows.compactMap { $0.number(g) }.sorted()
            guard vals.count >= 3 else { return [:] }
            let q1 = vals[vals.count / 3], q2 = vals[vals.count * 2 / 3]
            for r in rows { if let v = r.number(g) { out[r.id] = v <= q1 ? "Low (≤ \(f(q1, 2)))" : (v <= q2 ? "Mid" : "High (> \(f(q2, 2)))") } }
        } else {
            for r in rows { let t = r.text(g).trimmingCharacters(in: .whitespaces); out[r.id] = t.isEmpty ? "(blank)" : t }
        }
        return out
    }

    static func run(_ p: ExpPlan, table: SheetTable, prices: PriceBook, calendar: [String]) -> ExpResult {
        monthFirst = detectMonthFirst(table)
        var r = ExpResult()
        let issues = problems(p, table: table)
        if !issues.isEmpty { r.notes = issues }
        let rows = usableRows(p, table: table)
        r.rowsUsed = rows.count
        if p.task == "compare", !p.triggers.isEmpty {
            var first = ExpResult()
            first.notes = r.notes
            compare(p, table: table, rows: rows, prices: prices, into: &first)
            let measured = first.entries.contains { $0.returns.contains { $0 != nil } }
            // Every row is too recent to measure "on the row date", but the trigger columns hold whole numbers:
            // read them as bars ago (trading days since the trigger fired) so performance can be computed now.
            let convertible = p.triggers.indices.filter { k in
                let t = p.triggers[k]
                guard t.kind == "flag" || t.kind == "price", let c = table.index(of: t.column) else { return false }
                let v = table.rows.prefix(300).map { $0.text(c).replacingOccurrences(of: ",", with: "") }.filter { !$0.isEmpty }
                let n = v.compactMap { Double($0) }
                return !n.isEmpty && n.count == v.count && n.allSatisfy { $0 >= 0 && $0 == $0.rounded() } && n.contains { $0 > 1 }
            }
            if !measured && !convertible.isEmpty {
                var q = p
                for k in convertible { q.triggers[k].kind = "barsAgo" }
                var second = ExpResult()
                second.notes = r.notes
                compare(q, table: table, rows: rows, prices: prices, into: &second)
                if second.entries.contains(where: { $0.returns.contains { $0 != nil } }) {
                    second.notes.insert("All rows are too recent to measure from the row date, so \(convertible.map { p.triggers[$0].name }.joined(separator: ", ")) were read as BARS AGO (trading days since the trigger fired, counted back from the row date). If that's not what they mean, change the trigger type under Plan.", at: 0)
                    r = second
                } else { r = first }
            } else { r = first }
            r.rowsUsed = rows.count
            if r.rowsUsed < 30 { r.notes.append("Only \(r.rowsUsed) rows — treat this as a hint, not a result.") }
            return r
        }
        switch p.task {
        case "gap": gap(p, table: table, rows: rows, calendar: calendar, into: &r)
        case "describe": describe(p, table: table, rows: rows, into: &r)
        case "relation": relation(p, table: table, rows: rows, prices: prices, into: &r)
        default: compare(p, table: table, rows: rows, prices: prices, into: &r)
        }
        if r.rowsUsed < 30 && p.task != "describe" { r.notes.append("Only \(r.rowsUsed) rows — treat this as a hint, not a result.") }
        return r
    }

    // MARK: compare

    private static func entry(_ p: ExpPlan, _ t: ExpTrigger?, row: SheetRow, table: SheetTable, baseDay: String?) -> (day: String, price: Double?, back: Int)? {
        guard let t, let c = table.index(of: t.column) else { return baseDay.map { ($0, nil, 0) } }
        let v = row.text(c)
        switch t.kind {
        case "flag": return isOn(v) ? baseDay.map { ($0, nil, 0) } : nil
        case "price": return row.number(c).flatMap { pr in baseDay.map { ($0, pr, 0) } }
        case "barsAgo":
            guard let n = row.number(c) ?? Double(v.trimmingCharacters(in: .whitespaces)), n >= 0, n < 5000 else { return nil }
            return baseDay.map { ($0, nil, Int(n.rounded())) }
        default: return day(v).map { ($0, nil, 0) }
        }
    }

    private static func compare(_ p: ExpPlan, table: SheetTable, rows: [(row: SheetRow, shortDay: String?)], prices: PriceBook, into r: inout ExpResult) {
        guard let sc = table.index(of: p.symbolColumn) else { r.notes.append("Pick the stock column."); return }
        let bc = rowDateColumn(p, table: table)
        if p.baseDateColumn.isEmpty, let bc { r.notes.append("Row date: using the “\(table.headers[bc])” column.") }
        let hs = p.horizons.filter { $0 > 0 }
        guard !hs.isEmpty else { r.notes.append("Add at least one horizon."); return }
        let grp = groups(p, table: table, rows: rows.map(\.row))
        var noDate = 0, beforeHistory = 0, tooRecent = 0
        var latestEntry = ""
        let arms: [ExpTrigger?] = p.triggers.isEmpty ? [nil] : p.triggers.map { Optional($0) }
        var missing = Set<String>()
        var byArm: [String: [ExpEntry]] = [:]
        var byRow: [Int: [String: ExpEntry]] = [:]
        let maxH = hs.max() ?? 0

        for (row, shortDay) in rows {
            let sym = cleanSymbol(row.text(sc))
            guard !sym.isEmpty else { continue }
            guard let s = prices.series(for: sym), !s.days.isEmpty else { missing.insert(sym); continue }
            let baseDay = bc.flatMap { day(row.text($0)) } ?? shortDay
            for t in arms {
                guard let e = entry(p, t, row: row, table: table, baseDay: baseDay) else { noDate += 1; continue }
                let i0: Int
                if e.back > 0 {
                    // N trading days before the row date (on the stock's own trading days)
                    guard let b = s.days.lastIndex(where: { $0 <= e.day }), b - e.back >= 0 else { beforeHistory += 1; continue }
                    i0 = b - e.back
                } else {
                    guard let f = s.days.firstIndex(where: { $0 >= e.day }) else { tooRecent += 1; continue }
                    i0 = f
                }
                let i = i0 + max(0, p.entryDelay)
                guard i < s.closes.count else { tooRecent += 1; continue }
                if i + (hs.min() ?? 1) >= s.closes.count { tooRecent += 1; latestEntry = max(latestEntry, s.days[i]) }
                let price = (p.entryDelay == 0 ? e.price : nil) ?? s.closes[i]
                guard price > 0 else { continue }
                var rets: [Double?] = [], best: [Double?] = [], worst: [Double?] = []
                for h in hs {
                    if i + h < s.closes.count {
                        let w = s.closes[(i + 1)...(i + h)]
                        rets.append((s.closes[i + h] / price - 1) * 100)
                        best.append(((w.max() ?? price) / price - 1) * 100)
                        worst.append(((w.min() ?? price) / price - 1) * 100)
                    } else { rets.append(nil); best.append(nil); worst.append(nil) }
                }
                // target / stop over the longest horizon
                var trade: Double?
                if (p.targetPercent > 0 || p.stopPercent > 0), i + maxH < s.closes.count {
                    trade = (s.closes[i + maxH] / price - 1) * 100
                    for k in (i + 1)...(i + maxH) {
                        let g = (s.closes[k] / price - 1) * 100
                        if p.targetPercent > 0 && g >= p.targetPercent { trade = p.targetPercent; break }
                        if p.stopPercent > 0 && g <= -p.stopPercent { trade = -p.stopPercent; break }
                    }
                }
                let armName = (t?.name ?? "Row date") + (grp[row.id].map { " · " + $0 } ?? "")
                let after = shortDay.flatMap { sd in s.days.firstIndex(where: { $0 >= sd }) }.map { i - $0 }
                let en = ExpEntry(symbol: sym, arm: armName, day: s.days[i], entry: price, returns: rets, best: best, worst: worst, trade: trade, daysAfterShortlist: after, rowID: row.id)
                byArm[armName, default: []].append(en)
                byRow[row.id, default: [:]][t?.name ?? "Row date"] = en
                r.entries.append(en)
            }
        }
        if !missing.isEmpty { r.notes.append("No Yahoo prices for \(missing.count) stock\(missing.count == 1 ? "" : "s") (e.g. \(missing.sorted().prefix(4).joined(separator: ", ")))") }
        if noDate > 0 {
            let flags = p.triggers.filter { $0.kind != "date" }.map(\.name)
            r.notes.append("\(noDate) row/entry pair\(noDate == 1 ? "" : "s") had no entry date"
                + (bc == nil && !flags.isEmpty ? " — \(flags.joined(separator: ", ")) need a row date: pick “Row date” in the plan." : " (empty / unreadable cell)."))
        }
        if beforeHistory > 0 { r.notes.append("\(beforeHistory) entr\(beforeHistory == 1 ? "y goes" : "ies go") further back than the Yahoo history (5 years).") }
        if tooRecent > 0 {
            r.notes.append("\(tooRecent) entr\(tooRecent == 1 ? "y is" : "ies are") too recent to measure\(latestEntry.isEmpty ? "" : " (up to \(latestEntry))"): returns after \(hs.min() ?? 1) trading days need entries at least that old."
                + (p.triggers.contains { $0.kind == "flag" || $0.kind == "price" } ? " With “non-empty = triggered on the row date”, today's rows can only be measured in a few days — if the cells hold how many bars ago the trigger fired, set the trigger to “bars ago”." : ""))
        }

        var cols = ["Entry", "N"]
        for h in hs { cols += ["\(h)d mean", "\(h)d median", "\(h)d win", "\(h)d hit ≥\(f(p.winPercent, 0))%"] }
        cols.append("worst (\(hs.last!)d)")
        if p.targetPercent > 0 || p.stopPercent > 0 { cols += ["trade mean", "trade win"] }
        cols.append("days after shortlist")
        var t = ExpTable(title: "Returns after each entry (from the entry close)", columns: cols, rows: [])
        let mid = hs.count / 2
        var best: (String, Double)?
        for (name, es) in byArm.sorted(by: { $0.key < $1.key }) {
            var row = [name, "\(es.count)"]
            for k in hs.indices {
                let rets = es.compactMap { $0.returns[k] }, bests = es.compactMap { $0.best[k] }
                row += [pct(mean(rets)), pct(median(rets)),
                        rets.isEmpty ? "—" : f(Double(rets.filter { $0 > 0 }.count) / Double(rets.count) * 100, 0) + "%",
                        bests.isEmpty ? "—" : f(Double(bests.filter { $0 >= p.winPercent }.count) / Double(bests.count) * 100, 0) + "%"]
                if let m = mean(rets) { r.bars.append(ExpBar(series: name, category: "\(hs[k])d", value: m)) }
                if k == mid, es.count >= 5, let m = mean(rets), m > (best?.1 ?? -.infinity) { best = (name, m) }
            }
            row.append(pct(mean(es.compactMap { $0.worst.last ?? nil })))
            if p.targetPercent > 0 || p.stopPercent > 0 {
                let tr = es.compactMap(\.trade)
                row += [pct(mean(tr)), tr.isEmpty ? "—" : f(Double(tr.filter { $0 > 0 }.count) / Double(tr.count) * 100, 0) + "%"]
            }
            row.append(f(mean(es.compactMap { $0.daysAfterShortlist.map(Double.init) })))
            t.rows.append(row)
        }
        r.tables.append(t)
        r.barTitle = "Mean return by horizon"
        if let best { r.headline = "Best after \(hs[mid]) trading days: \(best.0) (mean \(pct(best.1)))" }
        else {
            let measured = r.entries.filter { $0.returns.contains { $0 != nil } }.count
            r.headline = measured == 0 ? "Nothing could be measured yet — see why below" : "\(measured) entries measured — too few (< 5) per entry type to pick a winner"
        }

        // head to head on rows where two entries both fired (no grouping)
        if p.triggers.count >= 2 {
            var h2h = ExpTable(title: "Head to head on the same rows (after \(hs[mid])d)", columns: ["A vs B", "rows", "A better", "B better", "could be luck? (sign test p)", "A first", "B first"], rows: [])
            for x in 0..<p.triggers.count { for y in (x + 1)..<p.triggers.count {
                let a = p.triggers[x].name, b = p.triggers[y].name
                var aw = 0, bw = 0, ae = 0, be = 0, n = 0
                for (_, m) in byRow {
                    guard let ea = m[a], let eb = m[b] else { continue }
                    if ea.day < eb.day { ae += 1 } else if eb.day < ea.day { be += 1 }
                    guard let ra = ea.returns[mid], let rb = eb.returns[mid] else { continue }
                    n += 1
                    if ra > rb { aw += 1 } else if rb > ra { bw += 1 }
                }
                let d = aw + bw
                let pv: Double? = d > 0 ? min(1, 2 * Stats.binomialUpperTail(k: max(aw, bw), n: d, p: 0.5)) : nil
                h2h.rows.append(["\(a) vs \(b)", "\(n)", "\(aw)", "\(bw)", pv.map { String(format: "%.3f%@", $0, $0 < 0.05 ? " (unlikely luck)" : " (could be luck)") } ?? "—", "\(ae)", "\(be)"])
            } }
            r.tables.append(h2h)
        }
    }

    // MARK: gap

    private static func gap(_ p: ExpPlan, table: SheetTable, rows: [(row: SheetRow, shortDay: String?)], calendar: [String], into r: inout ExpResult) {
        guard let a = table.index(of: p.gapFrom), let b = table.index(of: p.gapTo) else { return }
        let grp = groups(p, table: table, rows: rows.map(\.row))
        let cal = calendar
        func tradingDays(_ x: String, _ y: String) -> Int {
            if !cal.isEmpty, let i = cal.firstIndex(where: { $0 >= x }), let j = cal.firstIndex(where: { $0 >= y }) { return j - i }
            // weekdays
            guard let dx = key.date(from: x), let dy = key.date(from: y) else { return 0 }
            let sign = dx <= dy ? 1 : -1
            var n = 0, d = min(dx, dy)
            var greg = Calendar(identifier: .gregorian)
            greg.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
            while d < max(dx, dy) { let w = greg.component(.weekday, from: d); if w != 1 && w != 7 { n += 1 }; d = d.addingTimeInterval(86_400) }
            return n * sign
        }
        var by: [String: [Double]] = [:]
        var none = 0
        for (row, _) in rows {
            guard let x = day(row.text(a)), let y = day(row.text(b)) else { none += 1; continue }
            by[grp[row.id] ?? "All", default: []].append(Double(tradingDays(x, y)))
        }
        var t = ExpTable(title: "Trading days from \(p.gapFrom) to \(p.gapTo)", columns: ["Group", "rows", "mean", "median", "min", "max", "\(p.gapTo) after \(p.gapFrom)", "same day", "before"], rows: [])
        for (g, v) in by.sorted(by: { $0.key < $1.key }) {
            t.rows.append([g, "\(v.count)", f(mean(v)), f(median(v), 0), f(v.min(), 0), f(v.max(), 0),
                           "\(v.filter { $0 > 0 }.count)", "\(v.filter { $0 == 0 }.count)", "\(v.filter { $0 < 0 }.count)"])
            if let m = mean(v) { r.bars.append(ExpBar(series: "mean days", category: g, value: m)) }
        }
        r.tables.append(t)
        r.barTitle = "Mean trading days"
        let all = by.values.flatMap { $0 }
        r.headline = "\(p.gapTo) comes a median \(f(median(all), 0)) trading days after \(p.gapFrom) (\(all.count) rows)"
        if none > 0 { r.notes.append("\(none) rows had no date in one of the two columns.") }
    }

    // MARK: describe

    private static func describe(_ p: ExpPlan, table: SheetTable, rows: [(row: SheetRow, shortDay: String?)], into r: inout ExpResult) {
        let grp = groups(p, table: table, rows: rows.map(\.row))
        let cols = p.columns.compactMap { c in table.index(of: c).map { (c, $0) } }
        let groupsSorted = Array(Set(rows.map { grp[$0.row.id] ?? "All" })).sorted()
        for (name, c) in cols {
            let nums = rows.compactMap { $0.row.number(c) }
            if nums.count * 2 >= rows.filter({ !$0.row.text(c).isEmpty }).count && !nums.isEmpty {
                var t = ExpTable(title: name, columns: ["Group", "rows", "mean", "median", "min", "max"], rows: [])
                for g in groupsSorted {
                    let v = rows.filter { (grp[$0.row.id] ?? "All") == g }.compactMap { $0.row.number(c) }
                    t.rows.append([g, "\(v.count)", f(mean(v), 2), f(median(v), 2), f(v.min(), 2), f(v.max(), 2)])
                    if let m = mean(v) { r.bars.append(ExpBar(series: name, category: g, value: m)) }
                }
                r.tables.append(t)
            } else {
                var counts: [String: Int] = [:]
                for (row, _) in rows { let v = row.text(c).trimmingCharacters(in: .whitespaces); counts[v.isEmpty ? "(blank)" : v, default: 0] += 1 }
                let top = counts.sorted { $0.value > $1.value }.prefix(12)
                r.tables.append(ExpTable(title: "\(name) — most common values", columns: ["Value", "rows", "share"],
                                         rows: top.map { [$0.key, "\($0.value)", f(Double($0.value) / Double(max(1, rows.count)) * 100, 0) + "%"] }))
            }
        }
        r.barTitle = "Mean by group"
        r.headline = "\(rows.count) rows" + (p.groupBy.isEmpty ? "" : " in \(groupsSorted.count) groups of \(p.groupBy)")
    }

    // MARK: relation

    private static func relation(_ p: ExpPlan, table: SheetTable, rows: [(row: SheetRow, shortDay: String?)], prices: PriceBook, into r: inout ExpResult) {
        guard let sc = table.index(of: p.symbolColumn) else { r.notes.append("Pick the stock column."); return }
        let bc = rowDateColumn(p, table: table)
        let hs = p.horizons.filter { $0 > 0 }
        guard !hs.isEmpty else { return }
        let k = hs.count / 2, h = hs[k]
        var t = ExpTable(title: "Does a higher value go with a better return \(h) trading days later?",
                         columns: ["Column", "rows", "rank correlation", "Low third mean", "Mid third mean", "High third mean"], rows: [])
        for c in p.columns {
            guard let ci = table.index(of: c) else { continue }
            var pairs: [(Double, Double)] = []
            for (row, shortDay) in rows {
                let sym = cleanSymbol(row.text(sc))
                guard let x = row.number(ci), let s = prices.series(for: sym),
                      let d = (p.triggers.first.flatMap { tr in table.index(of: tr.column).flatMap { day(row.text($0)) } }) ?? bc.flatMap({ day(row.text($0)) }) ?? shortDay,
                      let i0 = s.days.firstIndex(where: { $0 >= d }) else { continue }
                let i = i0 + max(0, p.entryDelay)
                guard i + h < s.closes.count, s.closes[i] > 0 else { continue }
                pairs.append((x, (s.closes[i + h] / s.closes[i] - 1) * 100))
            }
            guard pairs.count >= 6 else { t.rows.append([c, "\(pairs.count)", "too few", "—", "—", "—"]); continue }
            let rx = PanelBuilder.ranks(pairs.map { Optional($0.0) }), ry = PanelBuilder.ranks(pairs.map { Optional($0.1) })
            let mx = rx.reduce(0, +) / Double(rx.count), my = ry.reduce(0, +) / Double(ry.count)
            var num = 0.0, dx = 0.0, dy = 0.0
            for i in rx.indices { num += (rx[i] - mx) * (ry[i] - my); dx += (rx[i] - mx) * (rx[i] - mx); dy += (ry[i] - my) * (ry[i] - my) }
            let rho = dx > 0 && dy > 0 ? num / (dx * dy).squareRoot() : 0
            let sorted = pairs.sorted { $0.0 < $1.0 }
            let n = sorted.count
            let thirds = [sorted[..<(n / 3)], sorted[(n / 3)..<(2 * n / 3)], sorted[(2 * n / 3)...]].map { mean($0.map(\.1)) }
            t.rows.append([c, "\(n)", String(format: "%+.2f", rho), pct(thirds[0]), pct(thirds[1]), pct(thirds[2])])
            for (name, v) in zip(["Low", "Mid", "High"], thirds) { if let v { r.bars.append(ExpBar(series: c, category: name, value: v)) } }
        }
        r.tables.append(t)
        r.barTitle = "Mean \(h)d return by third of the column"
        r.headline = "Rank correlation near 0 = no link; +0.1 or more = higher values tended to do better (on this sample)"
    }

    // MARK: - Reading commands

    /// Without Groq: understands "COL A … shortlist", "COL B and COL C … compare / timing", "days between", "describe", "group by".
    static func guessPlan(_ text: String, notes: String, table: SheetTable, previous: ExpPlan?) -> ExpPlan {
        var p = previous ?? ExpPlan()
        p.explanation = ""
        let lower = (notes + "\n" + text).lowercased()
        func header(_ letter: Character) -> String? {
            guard let a = letter.uppercased().unicodeScalars.first?.value, a >= 65, a <= 90 else { return nil }
            let i = Int(a - 65)
            return i < table.headers.count ? table.headers[i] : nil
        }
        func colsIn(_ cl: String) -> [String] {
            var cols: [String] = []
            for part in cl.replacingOccurrences(of: "column", with: "col").components(separatedBy: "col ").dropFirst() {
                if let ch = part.first, let h = header(ch), !cols.contains(h) { cols.append(h) }
            }
            let squashed = cl.filter { $0.isLetter || $0.isNumber }
            for h in table.headers where h.count > 2 && !cols.contains(h) {
                let hk = h.lowercased().filter { $0.isLetter || $0.isNumber }
                if cl.contains(h.lowercased()) || (hk.count > 2 && squashed.contains(hk)) { cols.append(h) }
            }
            return cols
        }
        let clauses = lower.components(separatedBy: CharacterSet(charactersIn: ".;\n")).flatMap { $0.components(separatedBy: " -- ") }
        var compareCols: [String] = []
        for cl in clauses {
            let cols = colsIn(cl)
            if (cl.contains("shortlist") || cl.contains("short list")), let c = cols.first { p.shortlistColumn = c }
            if cl.contains("timing") || cl.contains("trigger") || cl.contains("compare") || cl.contains("entry") || cl.contains("better") {
                compareCols += cols.filter { $0 != p.shortlistColumn && !compareCols.contains($0) }
            }
            if cl.contains("group by") || cl.contains("per ") || cl.contains("by sector") || cl.contains("split by"), let c = cols.last { p.groupBy = c }
            if cl.contains("between") || cl.contains("gap") || cl.contains("how many days") || cl.contains("days from"), cols.count >= 2 {
                p.task = "gap"; p.gapFrom = cols[0]; p.gapTo = cols[1]
            }
            if cl.contains("describe") || cl.contains("average") || cl.contains("distribution") || cl.contains("count") { if p.task != "gap" { p.task = "describe"; p.columns = cols } }
            if cl.contains("correlat") || cl.contains("relation") || cl.contains("higher") { p.task = "relation"; p.columns = cols }
            if cl.contains("next day") { p.entryDelay = 1 }
        }
        if p.task == "compare", !compareCols.isEmpty { p.triggers = compareCols.map { ExpTrigger(column: $0) } }
        if p.symbolColumn.isEmpty || table.index(of: p.symbolColumn) == nil {
            p.symbolColumn = table.headers.first { ["symbol", "nse symbol", "stock", "ticker", "nse", "scrip"].contains($0.lowercased()) } ?? ""
        }
        if p.symbolColumn.isEmpty, let lc = table.index(of: p.shortlistColumn) {
            let sample = table.rows.prefix(20).map { $0.text(lc) }.filter { !$0.isEmpty }
            if !sample.isEmpty && sample.allSatisfy({ day($0) == nil && Double($0) == nil }) { p.symbolColumn = p.shortlistColumn; p.shortlistKind = "symbol" }
        }
        if p.symbolColumn.isEmpty { p.symbolColumn = table.headers.first ?? "" }
        if let lc = table.index(of: p.shortlistColumn), p.shortlistKind != "symbol",
           table.rows.prefix(20).contains(where: { day($0.text(lc)) != nil }) { p.shortlistKind = "date" }
        for k in p.triggers.indices {
            if let c = table.index(of: p.triggers[k].column) {
                let sample = table.rows.prefix(30).map { $0.text(c) }.filter { !$0.isEmpty }
                let nums = sample.compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
                p.triggers[k].kind = sample.contains { day($0) != nil } ? "date"
                    : (nums.count == sample.count && !nums.isEmpty && nums.allSatisfy { $0 == $0.rounded() && $0 >= 0 } && nums.contains { $0 > 1 } ? "barsAgo"
                       : (nums.count == sample.count && nums.allSatisfy { $0 > 1.5 } ? "price" : "flag"))
            }
        }
        p.explanation = "Read without Groq — check the columns below."
        return p
    }

    /// Groq: command (+ column notes + earlier commands) → plan made of the building blocks above.
    static func groqPlan(_ text: String, notes: String, history: [ExpCommand], table: SheetTable, model: String) async throws -> ExpPlan {
        let letters = table.headers.enumerated().map { i, h in "\(columnLetter(i)) = \(h)" }.joined(separator: "\n")
        let sample = table.rows.prefix(6).map { r in table.headers.indices.map { r.text($0) }.joined(separator: " | ") }.joined(separator: "\n")
        let earlier = history.suffix(3).map { "- \($0.text)" }.joined(separator: "\n")
        let system = """
        You turn a trader's command about their Google Sheet into an analysis plan for an app that computes everything \
        itself (from the sheet and daily closing prices). Use ONLY the exact header names given. Pick one task:
        "compare" = returns after entries: each trigger column is an entry (kind "date": cell is the date; "flag": non-empty/1 means \
        triggered on the row date; "barsAgo": cell is how many trading days (bars) ago the trigger fired, counted back from the row \
        date — typical when a number column holds ta.barssince-style counts; "price": cell is the entry price on the row date); \
        no triggers = enter on the row date. Always set baseDateColumn when the sheet has a date column. If you are unsure what a \
        trigger column's numbers mean, say so in explanation.
        "gap" = trading days between two date columns (gapFrom → gapTo).
        "describe" = numbers / value counts of some columns.
        "relation" = does a higher value of number column(s) go with better returns later.
        Any task can be split by groupBy (a column; groupBuckets 3 = Low/Mid/High of a number column, 0 = by value) and restricted \
        by filters [{column, op: "=","≠",">","≥","<","≤","contains","nonempty","empty", value}].
        Reply as JSON: {"task", "symbolColumn", "shortlistColumn" (or ""), "shortlistKind": "flag"|"date"|"symbol", "baseDateColumn" (or ""), \
        "filters": [...], "triggers": [{"column","kind","label"}], "groupBy", "groupBuckets", "entryDelay" (0 = that day's close, 1 = next day), \
        "targetPercent" (0 = off), "stopPercent" (0 = off), "gapFrom", "gapTo", "columns": [...], "horizons": [trading days], "winPercent", \
        "explanation": 1–2 sentences on how you read the command and anything you had to assume}.
        If the command can't be done with these blocks, choose the closest one and say so in explanation.
        """
        let user = "Columns (letter = header):\n\(letters)\n\nFirst rows:\n\(sample)\n\nWhat the columns mean (user's notes):\n\(notes)\n\nEarlier commands:\n\(earlier)\n\nCommand:\n\(text)"
        let reply = try await GroqClient.chat(model: model, system: system, user: user, json: true)
        guard let d = reply.data(using: .utf8), let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw GroqClient.Failure(message: "Groq's plan couldn't be read")
        }
        func s(_ k: String) -> String { resolve(j[k] as? String ?? "", in: table) ?? "" }
        func n(_ k: String) -> Double { (j[k] as? Double) ?? (j[k] as? Int).map(Double.init) ?? 0 }
        var p = ExpPlan()
        p.task = (j["task"] as? String).flatMap { ["compare", "gap", "describe", "relation"].contains($0) ? $0 : nil } ?? "compare"
        p.symbolColumn = s("symbolColumn"); p.shortlistColumn = s("shortlistColumn"); p.baseDateColumn = s("baseDateColumn")
        p.shortlistKind = (j["shortlistKind"] as? String).flatMap { ["flag", "date", "symbol"].contains($0) ? $0 : nil } ?? "flag"
        p.filters = (j["filters"] as? [[String: Any]] ?? []).compactMap { f in
            guard let c = (f["column"] as? String).flatMap({ resolve($0, in: table) }) else { return nil }
            let v = f["value"].map { "\($0)" } ?? ""
            return ExpFilter(column: c, op: f["op"] as? String ?? "=", value: v)
        }
        p.triggers = (j["triggers"] as? [[String: Any]] ?? []).compactMap { t in
            guard let c = (t["column"] as? String).flatMap({ resolve($0, in: table) }) else { return nil }
            let k = (t["kind"] as? String).flatMap { ["date", "flag", "price", "barsAgo"].contains($0) ? $0 : nil } ?? "date"
            return ExpTrigger(column: c, kind: k, label: t["label"] as? String ?? "")
        }
        p.groupBy = s("groupBy"); p.groupBuckets = Int(n("groupBuckets"))
        p.entryDelay = max(0, min(5, Int(n("entryDelay")))); p.targetPercent = max(0, n("targetPercent")); p.stopPercent = max(0, n("stopPercent"))
        p.gapFrom = s("gapFrom"); p.gapTo = s("gapTo")
        p.columns = (j["columns"] as? [String] ?? []).compactMap { resolve($0, in: table) }
        if let h = j["horizons"] as? [Any] { let v = h.compactMap { ($0 as? Int) ?? ($0 as? Double).map { Int($0) } }.filter { (1...250).contains($0) }; if !v.isEmpty { p.horizons = Array(v.prefix(4)) } }
        if n("winPercent") > 0 { p.winPercent = n("winPercent") }
        p.explanation = j["explanation"] as? String ?? ""
        let g = guessPlan(text, notes: notes, table: table, previous: nil)
        if p.symbolColumn.isEmpty { p.symbolColumn = g.symbolColumn }
        // Groq named columns that aren't in the sheet → use the ones the command mentions
        if p.task == "compare" && p.triggers.isEmpty && !g.triggers.isEmpty {
            p.triggers = g.triggers
            p.explanation += " (Trigger columns matched from your words: \(g.triggers.map(\.column).joined(separator: ", ")).)"
        }
        return p
    }

    static func groqSummary(_ r: ExpResult, command: String, notes: String, model: String) async throws -> String {
        let system = """
        You are a careful trading-research assistant. Using ONLY the numbers provided (never invent any), answer the trader's \
        command in 4–6 short bullet points: the answer first, then consistency, risk, sample size and whether it could be luck. \
        End with one practical next step. If rows < 30, say clearly that it is not reliable yet.
        """
        return try await GroqClient.chat(model: model, system: system,
                                         user: "Column notes: \(notes)\nCommand: \(command)\n\nResults:\n\(r.text)", json: false)
    }
}


// MARK: - Chat with the results
//
// Groq never calculates. It answers either directly from the result tables, or asks the app for a QUERY over the
// entries (top / bottom stocks, a subset's stats, stats per group of any sheet column); the app computes it and Groq
// answers from those numbers. It can also propose a new command (a new analysis card).

enum ExperimentChatEngine {

    struct Query {
        var kind = "stats"                 // stats · top · entries
        var metric = "return"              // return · best · worst · trade
        var horizon: Int?                  // trading days (one of the plan's horizons)
        var order = "desc"
        var limit = 10
        var arm = ""                       // entry type ("" = all)
        var symbol = ""
        var filters: [ExpFilter] = []      // on sheet columns
        var minValue: Double?              // metric ≥
        var maxValue: Double?              // metric ≤
        var groupBy = ""                   // a sheet column
        var buckets = 0
    }

    static func parseQuery(_ j: [String: Any], table: SheetTable) -> Query {
        var q = Query()
        func n(_ k: String) -> Double? { (j[k] as? Double) ?? (j[k] as? Int).map(Double.init) ?? (j[k] as? String).flatMap(Double.init) }
        q.kind = (j["kind"] as? String).flatMap { ["stats", "top", "entries"].contains($0) ? $0 : nil } ?? "stats"
        q.metric = (j["metric"] as? String).flatMap { ["return", "best", "worst", "trade"].contains($0) ? $0 : nil } ?? "return"
        q.horizon = n("horizon").map { Int($0) }
        q.order = (j["order"] as? String) == "asc" ? "asc" : "desc"
        q.limit = max(1, min(50, Int(n("limit") ?? 10)))
        q.arm = j["arm"] as? String ?? ""
        q.symbol = SymbolBook.clean(j["symbol"] as? String ?? "")
        q.filters = (j["filters"] as? [[String: Any]] ?? []).compactMap { f in
            guard let c = (f["column"] as? String).flatMap({ ExperimentEngine.resolve($0, in: table) }) else { return nil }
            return ExpFilter(column: c, op: f["op"] as? String ?? "=", value: f["value"].map { "\($0)" } ?? "")
        }
        q.minValue = n("min"); q.maxValue = n("max")
        q.groupBy = (j["groupBy"] as? String).flatMap { ExperimentEngine.resolve($0, in: table) } ?? ""
        q.buckets = Int(n("buckets") ?? 0)
        return q
    }

    /// Computes a query over the entries; returns a small text table.
    static func run(_ q: Query, result: ExpResult, plan: ExpPlan, table: SheetTable) -> String {
        let hs = plan.horizons.filter { $0 > 0 }
        guard !hs.isEmpty else { return "No horizons in the plan." }
        let k = q.horizon.flatMap { h in hs.firstIndex(of: h) ?? hs.enumerated().min { abs($0.element - h) < abs($1.element - h) }?.offset } ?? hs.count / 2
        let h = hs[k]
        let rowsByID = Dictionary(table.rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let filters = q.filters.compactMap { f in table.index(of: f.column).map { ($0, f) } }
        func value(_ e: ExpEntry) -> Double? {
            switch q.metric {
            case "best": return e.best[k]
            case "worst": return e.worst[k]
            case "trade": return e.trade
            default: return e.returns[k]
            }
        }
        var es = result.entries.filter { e in
            (q.arm.isEmpty || e.arm.localizedCaseInsensitiveContains(q.arm)) && (q.symbol.isEmpty || e.symbol == q.symbol)
                && filters.allSatisfy { f in rowsByID[e.rowID].map { ExperimentEngine.passes($0, f.0, f.1) } ?? false }
        }
        es = es.filter { e in
            guard let v = value(e) else { return false }
            return (q.minValue.map { v >= $0 } ?? true) && (q.maxValue.map { v <= $0 } ?? true)
        }
        let label = q.metric == "return" ? "\(h)d return" : (q.metric == "trade" ? "trade result" : "\(q.metric) within \(h)d")
        var desc = "Entries: \(es.count)" + (q.arm.isEmpty ? "" : " · type \(q.arm)") + (q.symbol.isEmpty ? "" : " · \(q.symbol)")
            + (q.filters.isEmpty ? "" : " · " + q.filters.map { "\($0.column) \($0.op) \($0.value)" }.joined(separator: ", "))
            + (q.minValue.map { " · \(label) ≥ \($0)" } ?? "") + (q.maxValue.map { " · \(label) ≤ \($0)" } ?? "")
        func stats(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "n 0" }
            let m = ExperimentEngine.mean(v)!, md = ExperimentEngine.median(v)!
            let win = Double(v.filter { $0 > 0 }.count) / Double(v.count) * 100
            return "n \(v.count) · mean \(ExperimentEngine.pct(m)) · median \(ExperimentEngine.pct(md)) · win \(Int(win.rounded()))% · min \(ExperimentEngine.pct(v.min())) · max \(ExperimentEngine.pct(v.max()))"
        }
        switch q.kind {
        case "top", "entries":
            let sorted = es.sorted { (value($0) ?? 0) > (value($1) ?? 0) }
            let pick = q.order == "asc" ? Array(sorted.reversed().prefix(q.limit)) : Array(sorted.prefix(q.limit))
            desc += "\n" + (q.order == "asc" ? "Lowest" : "Highest") + " \(label):\n"
            for e in pick {
                desc += "\(e.symbol) · \(e.arm) · entry \(e.day) at \(String(format: "%.2f", e.entry)) · \(label) \(ExperimentEngine.pct(value(e)))"
                    + (e.daysAfterShortlist.map { " · \($0)d after shortlist" } ?? "") + "\n"
            }
            desc += "All of them: " + stats(es.compactMap(value))
        default:
            if !q.groupBy.isEmpty, let g = table.index(of: q.groupBy) {
                var groups: [String: [Double]] = [:]
                if q.buckets >= 2 {
                    let vals = es.compactMap { rowsByID[$0.rowID]?.number(g) }.sorted()
                    if vals.count >= 3 {
                        let q1 = vals[vals.count / 3], q2 = vals[vals.count * 2 / 3]
                        for e in es { if let x = rowsByID[e.rowID]?.number(g), let v = value(e) { groups[x <= q1 ? "Low ≤\(ExperimentEngine.f(q1, 2))" : (x <= q2 ? "Mid" : "High >\(ExperimentEngine.f(q2, 2))"), default: []].append(v) } }
                    }
                } else {
                    for e in es { if let v = value(e) { let t = rowsByID[e.rowID]?.text(g).trimmingCharacters(in: .whitespaces) ?? ""; groups[t.isEmpty ? "(blank)" : t, default: []].append(v) } }
                }
                desc += "\n\(label) by \(q.groupBy):\n"
                for (name, v) in groups.sorted(by: { (ExperimentEngine.mean($0.value) ?? 0) > (ExperimentEngine.mean($1.value) ?? 0) }).prefix(25) {
                    desc += "\(name): " + stats(v) + "\n"
                }
            } else {
                desc += "\n\(label): " + stats(es.compactMap(value))
            }
        }
        return desc
    }

    enum Reply { case answer(String, table: String?), newCommand(String, why: String) }

    static func ask(_ question: String, command: ExpCommand, result: ExpResult, notes: String, table: SheetTable, model: String) async throws -> Reply {
        let cols = table.headers.enumerated().map { "\(ExperimentEngine.columnLetter($0)) = \($1)" }.joined(separator: ", ")
        let history = command.chat.suffix(8).map { ($0.fromUser ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
        let arms = Array(Set(result.entries.map(\.arm))).sorted().joined(separator: ", ")
        let system = """
        You help a trader explore the results of an analysis of their stock sheet. You NEVER invent or estimate numbers. \
        Reply as JSON in ONE of these forms:
        1) {"answer": "..."} — only if the RESULTS text already contains the numbers needed.
        2) {"query": {...}} — to have the app compute from every entry: {"kind": "stats" | "top" | "entries", \
        "metric": "return" | "best" | "worst" | "trade", "horizon": one of the plan's horizons, "order": "desc" | "asc", "limit": n, \
        "arm": entry type name or "", "symbol": "" or a stock, "filters": [{"column": sheet header, "op": "="|"≠"|">"|"≥"|"<"|"≤"|"contains"|"nonempty"|"empty", "value": ...}], \
        "min": metric ≥ x or null, "max": metric ≤ x or null, "groupBy": sheet header or "", "buckets": 0 or 3}. \
        "top" lists the best (or worst with order asc) entries; "stats" gives n / mean / median / win%, optionally per group.
        3) {"command": "...", "why": "..."} — when the question needs a different analysis (other trigger columns, \
        days between two dates, a relation…); write it as a short plain-English command.
        """
        let base = """
        Sheet columns: \(cols)
        Column notes: \(notes)
        Analysis command: \(command.text)
        Plan horizons: \(command.plan.horizons.map(String.init).joined(separator: ", ")) trading days · entry types: \(arms)
        RESULTS:
        \(result.text)
        Conversation so far:
        \(history)
        """
        let first = try await GroqClient.chat(model: model, system: system, user: base + "\nQuestion: " + question, json: true)
        guard let d = first.data(using: .utf8), let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return .answer(first, table: nil)
        }
        if let c = j["command"] as? String, !c.isEmpty { return .newCommand(c, why: j["why"] as? String ?? "") }
        if let qj = j["query"] as? [String: Any] {
            let q = parseQuery(qj, table: table)
            let computed = run(q, result: result, plan: command.plan, table: table)
            let answer = try await GroqClient.chat(model: model, system: """
                You answer a trader's question using ONLY the computed numbers given (never invent any). Be short and direct: \
                the answer first, then 1–3 bullets with the key numbers, and a caution when n < 30.
                """, user: "Question: \(question)\n\nComputed by the app:\n\(computed)", json: false)
            return .answer(answer, table: computed)
        }
        return .answer(j["answer"] as? String ?? first, table: nil)
    }
}
