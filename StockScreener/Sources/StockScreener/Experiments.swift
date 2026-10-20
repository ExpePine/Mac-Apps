import Foundation

// MARK: - Experiments: your own sheet + plain-English instructions → a plan → numbers
//
// Groq only turns your instructions into a PLAN (which column is the stock, which is the shortlist, which are the
// timing triggers and how to read them). You can check and change the plan. The app then does all the arithmetic
// itself with Yahoo daily closes, and Groq may finally write a summary from those numbers only.

struct ExpTrigger: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var column = ""
    var kind = "date"          // date = the cell holds the trigger date · flag = non-empty/1 means triggered (on the base date) · price = the cell holds the entry price
    var label = ""
    var name: String { label.isEmpty ? column : label }
}

struct ExpPlan: Codable, Equatable {
    var symbolColumn = ""
    var shortlistColumn = ""
    var shortlistKind = "flag"     // flag · date · symbol (the shortlist column IS the stock column)
    var baseDateColumn = ""        // row date for flag / price triggers ("" = the shortlist date)
    var triggers: [ExpTrigger] = []
    var horizons = [5, 10, 21]     // trading days after the entry
    var winPercent = 10.0          // "hit" = best close within the horizon at least this % above the entry
    var explanation = ""
}

struct Experiment: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New experiment"
    var link = ""
    var instructions = ""
    var plan = ExpPlan()
    var summary = ""               // Groq's write-up of the last results
    var createdAt = Date()
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

// MARK: Results

struct ExpEntry: Identifiable {
    var id: String { symbol + "|" + trigger + "|" + day }
    let symbol: String
    let trigger: String
    let day: String                // entry day (first trading day on / after the trigger date)
    let entry: Double
    let returns: [Double?]         // per horizon, % at the close h days later
    let best: [Double?]            // per horizon, best close within h days, %
    let worst: [Double?]           // per horizon, worst close within h days, %
    let daysAfterShortlist: Int?   // trading days from the shortlist date to the entry
}

struct ExpTriggerStats: Identifiable {
    var id: String { name }
    let name: String
    let rows: Int                  // shortlisted rows
    let triggered: Int             // rows where this trigger gave an entry with prices
    let mean: [Double?], median: [Double?], winRate: [Double?], hitRate: [Double?], meanWorst: [Double?]
    let meanDaysAfterShortlist: Double?
}

struct ExpHeadToHead {
    let a: String, b: String
    let horizon: Int
    let pairs: Int
    let aWins: Int, bWins: Int
    let pValue: Double?            // two-sided sign test
    let aEarlier: Int, bEarlier: Int
}

struct ExpResult {
    var stats: [ExpTriggerStats] = []
    var entries: [ExpEntry] = []
    var headToHead: [ExpHeadToHead] = []
    var shortlisted = 0
    var problems: [String] = []
    var missingPrices: [String] = []

    /// The trigger with the best mean return at the middle horizon (needs ≥ 5 entries).
    func best(horizonIndex h: Int) -> String? {
        stats.filter { $0.triggered >= 5 }.max { ($0.mean[h] ?? -.infinity) < ($1.mean[h] ?? -.infinity) }?.name
    }
}

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

    /// A day key ("yyyy-MM-dd") from the many ways a sheet writes dates; nil if it isn't a date.
    static func day(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 6, s.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        for f in formatters { if let d = f.date(from: s) { return key.string(from: d) } }
        return nil
    }

    static func isOn(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return !s.isEmpty && !["0", "false", "no", "n", "-", "—", "na", "n/a", "#n/a"].contains(s)
    }

    static func cleanSymbol(_ raw: String) -> String { SymbolBook.clean(raw).replacingOccurrences(of: " ", with: "") }

    /// Columns the plan refers to that aren't in the sheet.
    static func problems(_ p: ExpPlan, table: SheetTable) -> [String] {
        var out: [String] = []
        for (what, c) in [("Stock column", p.symbolColumn), ("Shortlist column", p.shortlistColumn)] where table.index(of: c) == nil {
            out.append("\(what) “\(c)” isn't in the sheet")
        }
        if !p.baseDateColumn.isEmpty && table.index(of: p.baseDateColumn) == nil { out.append("Date column “\(p.baseDateColumn)” isn't in the sheet") }
        for t in p.triggers where table.index(of: t.column) == nil { out.append("Trigger column “\(t.column)” isn't in the sheet") }
        if p.triggers.isEmpty { out.append("No timing trigger columns in the plan") }
        return out
    }

    static func symbols(_ p: ExpPlan, table: SheetTable) -> [String] {
        guard let sc = table.index(of: p.symbolColumn) else { return [] }
        return Array(Set(table.rows.map { cleanSymbol($0.text(sc)) }.filter { !$0.isEmpty }))
    }

    static func run(_ p: ExpPlan, table: SheetTable, prices: PriceBook) -> ExpResult {
        var r = ExpResult()
        r.problems = problems(p, table: table)
        guard let sc = table.index(of: p.symbolColumn), let lc = table.index(of: p.shortlistColumn) else { return r }
        let bc = p.baseDateColumn.isEmpty ? nil : table.index(of: p.baseDateColumn)
        let trig = p.triggers.compactMap { t in table.index(of: t.column).map { (t, $0) } }
        let hs = p.horizons.filter { $0 > 0 }
        var missing = Set<String>()
        var perTrigger: [String: [ExpEntry]] = [:]
        var byRow: [Int: [String: ExpEntry]] = [:]

        for row in table.rows {
            let sym = cleanSymbol(row.text(sc))
            guard !sym.isEmpty else { continue }
            let cell = row.text(lc)
            let shortDay: String?
            switch p.shortlistKind {
            case "date": shortDay = day(cell); if shortDay == nil { continue }
            case "symbol": shortDay = nil
            default: guard isOn(cell) else { continue }; shortDay = day(cell)
            }
            r.shortlisted += 1
            let baseDay = bc.flatMap { day(row.text($0)) } ?? shortDay
            guard let s = prices.series(for: sym), !s.days.isEmpty else { missing.insert(sym); continue }
            for (t, c) in trig {
                let v = row.text(c)
                var d: String?
                var price: Double?
                switch t.kind {
                case "flag": d = isOn(v) ? baseDay : nil
                case "price": price = row.number(c); d = price != nil ? baseDay : nil
                default: d = day(v)
                }
                guard let d, let i = s.days.firstIndex(where: { $0 >= d }) else { continue }
                let entry = price ?? s.closes[i]
                guard entry > 0 else { continue }
                var rets: [Double?] = [], best: [Double?] = [], worst: [Double?] = []
                for h in hs {
                    if i + h < s.closes.count {
                        let win = s.closes[(i + 1)...(i + h)]
                        rets.append((s.closes[i + h] / entry - 1) * 100)
                        best.append(((win.max() ?? entry) / entry - 1) * 100)
                        worst.append(((win.min() ?? entry) / entry - 1) * 100)
                    } else { rets.append(nil); best.append(nil); worst.append(nil) }
                }
                let after = shortDay.flatMap { sd in s.days.firstIndex(where: { $0 >= sd }) }.map { i - $0 }
                let e = ExpEntry(symbol: sym, trigger: t.name, day: s.days[i], entry: entry, returns: rets, best: best, worst: worst, daysAfterShortlist: after)
                perTrigger[t.name, default: []].append(e)
                byRow[row.id, default: [:]][t.name] = e
                r.entries.append(e)
            }
        }
        r.missingPrices = missing.sorted()

        func mean(_ x: [Double]) -> Double? { x.isEmpty ? nil : x.reduce(0, +) / Double(x.count) }
        func median(_ x: [Double]) -> Double? {
            guard !x.isEmpty else { return nil }
            let s = x.sorted(); let m = s.count / 2
            return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
        }
        for (t, _) in trig {
            let es = perTrigger[t.name] ?? []
            var mn: [Double?] = [], md: [Double?] = [], wr: [Double?] = [], hr: [Double?] = [], mw: [Double?] = []
            for k in hs.indices {
                let rets = es.compactMap { $0.returns[k] }, bests = es.compactMap { $0.best[k] }, worsts = es.compactMap { $0.worst[k] }
                mn.append(mean(rets)); md.append(median(rets))
                wr.append(rets.isEmpty ? nil : Double(rets.filter { $0 > 0 }.count) / Double(rets.count) * 100)
                hr.append(bests.isEmpty ? nil : Double(bests.filter { $0 >= p.winPercent }.count) / Double(bests.count) * 100)
                mw.append(mean(worsts))
            }
            r.stats.append(ExpTriggerStats(name: t.name, rows: r.shortlisted, triggered: es.count, mean: mn, median: md, winRate: wr,
                                           hitRate: hr, meanWorst: mw, meanDaysAfterShortlist: mean(es.compactMap { $0.daysAfterShortlist.map(Double.init) })))
        }

        // Head to head: same row, both triggers fired — which one did better after the middle horizon, and which came first
        if trig.count >= 2, !hs.isEmpty {
            let k = hs.count / 2
            for x in 0..<trig.count { for y in (x + 1)..<trig.count {
                let a = trig[x].0.name, b = trig[y].0.name
                var aw = 0, bw = 0, ae = 0, be = 0, n = 0
                for (_, m) in byRow {
                    guard let ea = m[a], let eb = m[b] else { continue }
                    if ea.day < eb.day { ae += 1 } else if eb.day < ea.day { be += 1 }
                    guard let ra = ea.returns[k], let rb = eb.returns[k] else { continue }
                    n += 1
                    if ra > rb { aw += 1 } else if rb > ra { bw += 1 }
                }
                let decided = aw + bw
                let pv: Double? = decided > 0 ? min(1, 2 * Stats.binomialUpperTail(k: max(aw, bw), n: decided, p: 0.5)) : nil
                r.headToHead.append(ExpHeadToHead(a: a, b: b, horizon: hs[k], pairs: n, aWins: aw, bWins: bw, pValue: pv, aEarlier: ae, bEarlier: be))
            } }
        }
        return r
    }

    /// Without Groq: reads "COL A … shortlist", "COL B and COL C … timing / compare" style instructions.
    static func guessPlan(_ text: String, table: SheetTable) -> ExpPlan {
        var p = ExpPlan()
        let lower = text.lowercased()
        func header(_ letter: Character) -> String? {
            guard let a = letter.uppercased().unicodeScalars.first?.value, a >= 65, a <= 90 else { return nil }
            let i = Int(a - 65)
            return i < table.headers.count ? table.headers[i] : nil
        }
        // sentences / clauses with the columns they mention
        let clauses = lower.components(separatedBy: CharacterSet(charactersIn: ".;\n")).flatMap { $0.components(separatedBy: " -- ") }
        for cl in clauses {
            var cols: [String] = []
            let scanner = cl.replacingOccurrences(of: "column", with: "col")
            let parts = scanner.components(separatedBy: "col ")
            for part in parts.dropFirst() { if let ch = part.first, let h = header(ch) { cols.append(h) } }
            for h in table.headers where cl.contains(h.lowercased()) && h.count > 2 && !cols.contains(h) { cols.append(h) }
            if cl.contains("shortlist") || cl.contains("short list") || cl.contains("selected"), let c = cols.first, p.shortlistColumn.isEmpty {
                p.shortlistColumn = c
            } else if cl.contains("timing") || cl.contains("trigger") || cl.contains("compare") || cl.contains("entry") {
                for c in cols where c != p.shortlistColumn && !p.triggers.contains(where: { $0.column == c }) { p.triggers.append(ExpTrigger(column: c)) }
            }
        }
        // stock column: a header like Symbol, else the shortlist column if it holds symbols
        p.symbolColumn = table.headers.first { ["symbol", "nse symbol", "stock", "ticker", "nse", "scrip"].contains($0.lowercased()) } ?? ""
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
                p.triggers[k].kind = sample.contains { day($0) != nil } ? "date" : (sample.allSatisfy { Double($0) != nil && (Double($0) ?? 0) > 1.5 } ? "price" : "flag")
            }
        }
        if lower.contains("week") { p.horizons = [5] + p.horizons.filter { $0 != 5 } }
        p.explanation = "Read from your words without Groq — check the columns below."
        return p
    }

    /// Asks Groq to turn the instructions into a plan (columns must be the sheet's headers).
    static func groqPlan(_ text: String, table: SheetTable, model: String) async throws -> ExpPlan {
        let letters = table.headers.enumerated().map { i, h in "\(columnLetter(i)) = \(h)" }.joined(separator: "\n")
        let sample = table.rows.prefix(6).map { r in table.headers.indices.map { r.text($0) }.joined(separator: " | ") }.joined(separator: "\n")
        let system = """
        You turn a trader's instructions about their Google Sheet into an analysis plan. The app will compute everything \
        itself from daily prices; you only decide which column means what. Use ONLY the exact header names given. \
        Reply as JSON: {"symbolColumn": header holding the NSE stock symbol, "shortlistColumn": header, \
        "shortlistKind": "flag" (non-empty/1 = shortlisted) | "date" (cell is the shortlist date) | "symbol" (the column itself is the symbol), \
        "baseDateColumn": header with the row's date or "" , "triggers": [{"column": header, "kind": "date" | "flag" | "price", "label": short name}], \
        "horizons": [trading days to measure returns after the entry, e.g. 5,10,21], "winPercent": number, \
        "explanation": one or two sentences on how you read the instructions and anything ambiguous}.
        """
        let user = "Columns (letter = header):\n\(letters)\n\nFirst rows:\n\(sample)\n\nInstructions:\n\(text)"
        let reply = try await GroqClient.chat(model: model, system: system, user: user, json: true)
        guard let d = reply.data(using: .utf8), let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw GroqClient.Failure(message: "Groq's plan couldn't be read")
        }
        var p = ExpPlan()
        p.symbolColumn = j["symbolColumn"] as? String ?? ""
        p.shortlistColumn = j["shortlistColumn"] as? String ?? ""
        p.shortlistKind = (j["shortlistKind"] as? String).flatMap { ["flag", "date", "symbol"].contains($0) ? $0 : nil } ?? "flag"
        p.baseDateColumn = j["baseDateColumn"] as? String ?? ""
        p.triggers = (j["triggers"] as? [[String: Any]] ?? []).compactMap { t in
            guard let c = t["column"] as? String, table.index(of: c) != nil else { return nil }
            let k = (t["kind"] as? String).flatMap { ["date", "flag", "price"].contains($0) ? $0 : nil } ?? "date"
            return ExpTrigger(column: c, kind: k, label: t["label"] as? String ?? "")
        }
        if let h = j["horizons"] as? [Any] { let v = h.compactMap { ($0 as? Int) ?? ($0 as? Double).map { Int($0) } }.filter { (1...250).contains($0) }; if !v.isEmpty { p.horizons = Array(v.prefix(4)) } }
        if let w = (j["winPercent"] as? Double) ?? (j["winPercent"] as? Int).map(Double.init) { p.winPercent = w }
        p.explanation = j["explanation"] as? String ?? ""
        if table.index(of: p.symbolColumn) == nil || table.index(of: p.shortlistColumn) == nil || p.triggers.isEmpty {
            let g = guessPlan(text, table: table)
            if table.index(of: p.symbolColumn) == nil { p.symbolColumn = g.symbolColumn }
            if table.index(of: p.shortlistColumn) == nil { p.shortlistColumn = g.shortlistColumn; p.shortlistKind = g.shortlistKind }
            if p.triggers.isEmpty { p.triggers = g.triggers }
        }
        return p
    }

    /// Groq writes the conclusion from the computed numbers only.
    static func groqSummary(_ r: ExpResult, plan: ExpPlan, instructions: String, model: String) async throws -> String {
        var lines: [String] = ["Shortlisted rows: \(r.shortlisted). Horizons (trading days): \(plan.horizons.map(String.init).joined(separator: ", ")). Hit = best close ≥ \(plan.winPercent)% within the horizon."]
        for s in r.stats {
            var l = "\(s.name): \(s.triggered) entries"
            for (k, h) in plan.horizons.enumerated() where k < s.mean.count {
                l += "; \(h)d mean \(f(s.mean[k]))%, median \(f(s.median[k]))%, win \(f(s.winRate[k]))%, hit \(f(s.hitRate[k]))%, avg worst \(f(s.meanWorst[k]))%"
            }
            if let d = s.meanDaysAfterShortlist { l += "; avg \(String(format: "%.1f", d)) trading days after shortlist" }
            lines.append(l)
        }
        for h in r.headToHead {
            lines.append("Head to head at \(h.horizon)d on \(h.pairs) rows where both fired: \(h.a) better \(h.aWins)×, \(h.b) better \(h.bWins)×, sign-test p = \(h.pValue.map { String(format: "%.3f", $0) } ?? "n/a"); \(h.a) fired first \(h.aEarlier)×, \(h.b) first \(h.bEarlier)×.")
        }
        let system = """
        You are a careful trading-research assistant. Using ONLY the numbers provided (never invent any), say which timing \
        trigger did better and why, in 4–6 short bullet points: returns, consistency (win / hit rate), risk (worst), timing, \
        head-to-head and whether the difference could be luck (p-value, sample size). End with one practical next step. \
        If samples are small (< 30 entries), say clearly that the result is not reliable yet.
        """
        return try await GroqClient.chat(model: model, system: system, user: "Goal: \(instructions)\n\nResults:\n" + lines.joined(separator: "\n"), json: false)
    }

    static func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "n/a" }

    static func columnLetter(_ i: Int) -> String {
        var n = i, s = ""
        repeat { s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n = n / 26 - 1 } while n >= 0
        return s
    }
}
