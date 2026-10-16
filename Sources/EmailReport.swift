import Foundation

/// Builds the daily recap: Groq only labels entries (category, short title,
/// success); all minutes, ordering and layout are computed here.
struct DailyRecap: Codable {
    struct Block: Codable {
        var start: Date
        var end: Date
        var category: String
        var titles: [String]
        var success: Bool?      // true = success, false = failed/blocked, nil = not stated
    }

    var dayText: String
    var headline: String
    var tagline: String?        // exactly 3 words, shown in the calendar
    var categories: [CategoryMinutes] = []
    var timeline: [Block] = []
    var solved: [String] = []
    var next: [String] = []
    var answered = 0
    var missed = 0
    var usage: DayUsage?
    var aiNote: String?         // shown small if the AI step failed / no key
    var goals: [Goal] = []
    var onPlanPercent: Int?     // share of checked check-ins that served a goal

    // Period reports (week / month / year)
    var kind = "Daily"                   // "Daily", "Weekly", "Monthly", "Yearly"
    var days: [DaySummary] = []          // day-by-day (or month-by-month) rows
    var successTotal: Int?               // set for period reports
    var missingDays = 0                  // days with check-ins but no stored report

    var successCount: Int { successTotal ?? timeline.filter { $0.success == true }.count }
}

struct CategoryMinutes: Codable {
    var name: String
    var minutes: Int
}

struct DaySummary: Codable {
    var label: String                    // "Mon 12 Oct" or "October"
    var headline: String
    var activeSeconds: Double
    var answered: Int
    var successes: Int
    var topCategory: String?
}

enum RecapBuilder {
    private struct Label {
        var category: String
        var title: String
        var success: Bool?
        var solved: String?
    }

    static func build(dayText: String, entries: [Entry], usage: DayUsage?, goals: [Goal] = [],
                      apiKey: String, model: String) async -> DailyRecap {
        let answered = entries.filter { $0.status != .missed && $0.status != .skipped }
        let useful = answered.filter { !text(of: $0).isEmpty }
        var recap = DailyRecap(dayText: dayText, headline: "")
        recap.answered = answered.count
        recap.missed = entries.filter { $0.status == .missed }.count
        recap.usage = usage
        recap.goals = goals
        let checked = answered.filter { $0.goalAligned != nil }
        if !checked.isEmpty {
            recap.onPlanPercent = Int((Double(checked.filter { $0.goalAligned == true }.count)
                                       / Double(checked.count) * 100).rounded())
        }

        var labels: [UUID: Label] = [:]
        var headline = ""
        var tagline = ""
        var next: [String] = []

        if !useful.isEmpty && !apiKey.isEmpty {
            do {
                let raw = try await Groq.complete(apiKey: apiKey, model: model, system: systemPrompt,
                                                  user: userPrompt(useful), jsonMode: true)
                (labels, headline, next, tagline) = parse(raw, entries: useful)
            } catch {
                recap.aiNote = "AI labels unavailable: \(error.localizedDescription)"
            }
        } else if !useful.isEmpty {
            recap.aiNote = "Add a Groq API key in settings for categories and a headline."
        }

        // Fallback labels for anything the AI didn't cover.
        for e in useful where labels[e.id] == nil {
            labels[e.id] = Label(category: "Other", title: shortTitle(text(of: e)),
                                 success: keywordSuccess(text(of: e)), solved: nil)
        }

        // Timeline: merge consecutive entries in the same category.
        var blocks: [DailyRecap.Block] = []
        for e in useful {
            guard let l = labels[e.id] else { continue }
            if var last = blocks.last, last.category == l.category,
               e.periodStart.timeIntervalSince(last.end) < 5 * 60 {
                last.end = e.periodEnd
                if !last.titles.contains(l.title) { last.titles.append(l.title) }
                if l.success == true { last.success = true }
                else if l.success == false && last.success == nil { last.success = false }
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(.init(start: e.periodStart, end: e.periodEnd, category: l.category,
                                    titles: [l.title], success: l.success))
            }
        }
        recap.timeline = blocks

        // Category minutes from real check-in durations.
        var minutes: [String: Double] = [:]
        for e in useful {
            guard let l = labels[e.id] else { continue }
            minutes[l.category, default: 0] += e.periodEnd.timeIntervalSince(e.periodStart) / 60
        }
        recap.categories = minutes.sorted { $0.value > $1.value }.map { CategoryMinutes(name: $0.key, minutes: Int($0.value.rounded())) }

        recap.solved = useful.compactMap { e -> String? in
            guard let l = labels[e.id], l.success == true else { return nil }
            return (l.solved?.isEmpty == false ? l.solved! : l.title)
        }
        recap.next = Array(next.prefix(2))

        if headline.isEmpty {
            headline = recap.categories.isEmpty
                ? "No check-ins logged."
                : "Mostly " + recap.categories.prefix(2).map { $0.name }.joined(separator: " and ") + "."
        }
        recap.headline = headline
        if tagline.isEmpty, let top = recap.categories.first?.name {
            tagline = top   // no AI: fall back to the main category
        }
        recap.tagline = tagline.isEmpty ? nil : tagline
        return recap
    }

    // MARK: AI

    private static let systemPrompt = """
    You label entries from a person's work log. Output only valid JSON, nothing else. \
    Use only what the log says. Keep every string short.
    """

    private static func userPrompt(_ entries: [Entry]) -> String {
        let lines = entries.enumerated().map { i, e in
            "e\(i + 1) | \(e.timeRangeText) | \(text(of: e).replacingOccurrences(of: "\n", with: " / "))"
        }.joined(separator: "\n")
        return """
        Work log (id | time | what I did):
        \(lines)

        Return JSON exactly like:
        {"headline": "max 12 words: what the day was mainly about",
         "tagline": "exactly 3 words naming what I did most, e.g. MV2 picker data",
         "items": [{"id": "e1", "category": "2-3 words", "title": "max 7 words, start with a verb",
                    "success": true, "solved": "max 10 words: problem -> result"}],
         "next": ["max 8 words"]}

        Rules:
        - One item per log entry, same ids.
        - Use at most 6 distinct categories and reuse the exact same category names (e.g. "Hardware design", "Job search", "Mac app", "Meetings", "Admin").
        - success = true ONLY if the entry itself says it worked / succeeded / solved / fixed / done / completed. false if it says failed / blocked / not working. Otherwise null.
        - solved: only when success is true, otherwise null.
        - next: at most 2, only for work the log says is unfinished or blocked. Empty list if none.
        """
    }

    private static func parse(_ raw: String, entries: [Entry]) -> ([UUID: Label], String, [String], String) {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return ([:], "", [], "") }

        var labels: [UUID: Label] = [:]
        for item in json["items"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, id.hasPrefix("e"),
                  let n = Int(id.dropFirst()), n >= 1, n <= entries.count else { continue }
            let e = entries[n - 1]
            let category = clean(item["category"] as? String, max: 30) ?? "Other"
            let title = clean(item["title"] as? String, max: 60) ?? shortTitle(text(of: e))
            labels[e.id] = Label(category: category, title: title,
                                 success: item["success"] as? Bool,
                                 solved: clean(item["solved"] as? String, max: 80))
        }
        let headline = clean(json["headline"] as? String, max: 100) ?? ""
        let next = (json["next"] as? [String] ?? []).compactMap { clean($0, max: 70) }
        let tagline = threeWords(json["tagline"] as? String)
        return (labels, headline, next, tagline)
    }

    // MARK: Helpers

    /// Keeps at most three words, without trailing punctuation.
    static func threeWords(_ s: String?) -> String {
        guard let s else { return "" }
        let words = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!\"'"))
            .split(whereSeparator: \.isWhitespace)
            .prefix(3)
        return words.joined(separator: " ")
    }

    private static func text(of e: Entry) -> String {
        let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return (e.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ s: String?, max: Int) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              s.lowercased() != "null" else { return nil }
        return s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }

    private static func shortTitle(_ s: String) -> String {
        let words = s.split(separator: " ").prefix(8).joined(separator: " ")
        return words.count < s.count ? words + "…" : words
    }

    /// Used when there's no AI: look for the words the user types to mark a success.
    static func keywordSuccess(_ s: String) -> Bool? {
        let t = s.lowercased()
        let bad = ["not working", "didn't work", "did not work", "failed", "blocked", "stuck", "unsuccessful"]
        if bad.contains(where: t.contains) { return false }
        let good = ["success", "solved", "fixed", "done", "completed", "working now", "it works", "✅"]
        return good.contains(where: t.contains) ? true : nil
    }
}

// MARK: - Rendering

enum RecapRenderer {
    private static let palette = ["#4F6BED", "#14A38B", "#E8833A", "#C2489C", "#8A5CF6", "#D9A21B", "#3B9DD8", "#7A8699"]

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    private static func mins(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }

    // MARK: HTML

    static func html(_ r: DailyRecap) -> String {
        let colorFor: [String: String] = Dictionary(uniqueKeysWithValues:
            r.categories.enumerated().map { ($1.name, palette[$0 % palette.count]) })
        let font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
        var h = """
        <!doctype html><html><body style="margin:0;padding:0;background:#F3F4F6;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F3F4F6;">
        <tr><td align="center" style="padding:24px 12px;">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#FFFFFF;border-radius:12px;font-family:\(font);color:#1F2937;">
        <tr><td style="padding:24px 24px 8px 24px;">
          <div style="font-size:13px;color:#6B7280;text-transform:uppercase;letter-spacing:.06em;">\(esc(r.kind)) recap · \(esc(r.dayText))</div>
          <div style="font-size:20px;font-weight:600;margin-top:6px;line-height:1.35;">\(esc(r.headline))</div>
        </td></tr>
        """

        // Stat tiles
        let active = r.usage.map { durationText($0.activeSeconds) } ?? "–"
        func tile(_ value: String, _ label: String) -> String {
            """
            <td width="33%" style="padding:6px;"><div style="background:#F9FAFB;border-radius:8px;padding:12px;text-align:center;">
            <div style="font-size:20px;font-weight:700;">\(esc(value))</div>
            <div style="font-size:12px;color:#6B7280;margin-top:2px;">\(esc(label))</div></div></td>
            """
        }
        h += """
        <tr><td style="padding:8px 18px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
        \(tile(active, "Active screen time"))
        \(tile("\(r.answered)", r.missed > 0 ? "Check-ins (\(r.missed) missed)" : "Check-ins"))
        \(tile("\(r.successCount)", r.successCount == 1 ? "Success" : "Successes"))
        </tr></table></td></tr>
        """

        // Goals
        if !r.goals.isEmpty {
            let done = r.goals.filter(\.done).count
            var title = "Goals · \(done) of \(r.goals.count) done"
            if let p = r.onPlanPercent { title += " · \(p)% of check-ins on plan" }
            h += section(title)
            h += "<tr><td style=\"padding:0 24px 8px 24px;\">"
            for g in r.goals {
                let mark = g.done ? "<span style=\"color:#16A34A;\">●</span>" : "<span style=\"color:#D1D5DB;\">○</span>"
                let style = g.done ? "color:#6B7280;" : ""
                h += "<div style=\"font-size:14px;padding:3px 0;\(style)\">\(mark)&nbsp; \(esc(g.text))</div>"
            }
            h += "</td></tr>"
        }

        // Categories
        if !r.categories.isEmpty {
            let total = max(1, r.categories.reduce(0) { $0 + $1.minutes })
            h += section("Where your time went")
            h += "<tr><td style=\"padding:0 24px 8px 24px;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">"
            for c in r.categories {
                let pct = max(2, Int((Double(c.minutes) / Double(total) * 100).rounded()))
                let color = colorFor[c.name] ?? palette.last!
                h += """
                <tr><td style="padding:5px 0;font-size:14px;width:38%;"><span style="display:inline-block;width:9px;height:9px;border-radius:5px;background:\(color);margin-right:7px;"></span>\(esc(c.name))</td>
                <td style="padding:5px 8px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
                <td width="\(pct)%" style="background:\(color);height:8px;border-radius:4px;font-size:0;line-height:0;">&nbsp;</td><td style="font-size:0;line-height:0;">&nbsp;</td></tr></table></td>
                <td style="padding:5px 0;font-size:13px;color:#6B7280;text-align:right;white-space:nowrap;width:60px;">\(mins(c.minutes))</td></tr>
                """
            }
            h += "</table></td></tr>"
        }

        // Problems solved
        h += section("Problems solved")
        if r.solved.isEmpty {
            h += "<tr><td style=\"padding:0 24px 8px 24px;font-size:14px;color:#9CA3AF;\">None marked yet — type “success”, “solved” or “fixed” in a check-in to log one.</td></tr>"
        } else {
            h += "<tr><td style=\"padding:0 24px 8px 24px;\">"
            for s in r.solved {
                h += "<div style=\"font-size:14px;padding:4px 0;\">✅&nbsp; \(esc(s))</div>"
            }
            h += "</td></tr>"
        }

        // Day by day (period reports)
        if !r.days.isEmpty {
            h += section(r.kind == "Yearly" ? "Month by month" : "Day by day")
            h += "<tr><td style=\"padding:0 24px 8px 24px;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">"
            let maxActive = max(1, r.days.map(\.activeSeconds).max() ?? 1)
            for d in r.days {
                let pct = max(1, Int((d.activeSeconds / maxActive * 100).rounded()))
                let color = d.topCategory.flatMap { colorFor[$0] } ?? "#9CA3AF"
                let stars = d.successes > 0 ? " · ✅ \(d.successes)" : ""
                h += """
                <tr>
                <td style="padding:6px 8px 6px 0;font-size:12px;color:#6B7280;white-space:nowrap;vertical-align:top;width:90px;">\(esc(d.label))</td>
                <td style="padding:6px 0;vertical-align:top;">
                  <div style="font-size:13px;">\(esc(d.headline))</div>
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:4px;"><tr>
                  <td width="\(pct)%" style="background:\(color);height:6px;border-radius:3px;font-size:0;line-height:0;">&nbsp;</td><td style="font-size:0;line-height:0;">&nbsp;</td></tr></table>
                  <div style="font-size:11px;color:#6B7280;margin-top:2px;">\(durationText(d.activeSeconds)) active · \(d.answered) check-ins\(stars)\(d.topCategory.map { " · " + esc($0) } ?? "")</div>
                </td></tr>
                """
            }
            h += "</table></td></tr>"
        }

        // Timeline
        if !r.timeline.isEmpty {
            h += section("Timeline")
            h += "<tr><td style=\"padding:0 24px 8px 24px;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">"
            for b in r.timeline {
                let color = colorFor[b.category] ?? palette.last!
                let mark = b.success == true ? "✅" : (b.success == false ? "⚠️" : "")
                h += """
                <tr>
                <td style="padding:6px 8px 6px 0;font-size:12px;color:#6B7280;white-space:nowrap;vertical-align:top;width:120px;">\(time(b.start))–\(time(b.end))</td>
                <td style="padding:6px 0;vertical-align:top;border-left:3px solid \(color);padding-left:10px;">
                  <div style="font-size:14px;">\(esc(b.titles.prefix(2).joined(separator: " · ")))</div>
                  <div style="font-size:11px;color:\(color);margin-top:1px;">\(esc(b.category))</div></td>
                <td style="padding:6px 0;font-size:14px;text-align:right;vertical-align:top;width:24px;">\(mark)</td>
                </tr>
                """
            }
            h += "</table></td></tr>"
        }

        // Screen time
        if let u = r.usage, u.activeSeconds >= 60 {
            let sites = u.top(u.sites, 5).filter { $0.seconds >= 60 }
            let apps = u.top(u.apps, 5).filter { $0.seconds >= 60 }
            func list(_ title: String, _ items: [(name: String, seconds: Double)]) -> String {
                var s = "<td width=\"50%\" style=\"vertical-align:top;padding-right:8px;\"><div style=\"font-size:12px;color:#6B7280;margin-bottom:4px;\">\(title)</div>"
                if items.isEmpty { s += "<div style=\"font-size:13px;color:#9CA3AF;\">–</div>" }
                for i in items {
                    s += "<div style=\"font-size:13px;padding:2px 0;\"><span style=\"color:#6B7280;display:inline-block;width:56px;\">\(durationText(i.seconds))</span>\(esc(i.name))</div>"
                }
                return s + "</td>"
            }
            h += section("Screen time")
            h += "<tr><td style=\"padding:0 24px 8px 24px;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr>\(list("Websites", sites))\(list("Apps", apps))</tr></table></td></tr>"
        }

        // Next
        if !r.next.isEmpty {
            h += section("Next")
            h += "<tr><td style=\"padding:0 24px 8px 24px;\">"
            for n in r.next { h += "<div style=\"font-size:14px;padding:3px 0;\">→&nbsp; \(esc(n))</div>" }
            h += "</td></tr>"
        }

        var note = r.aiNote.map { "<br>\(esc($0))" } ?? ""
        if r.missingDays > 0 {
            note += "<br>\(r.missingDays) day\(r.missingDays == 1 ? "" : "s") in this period had no stored report — generate them in Activity Logger → Reports."
        }
        h += """
        <tr><td style="padding:16px 24px 24px 24px;font-size:11px;color:#9CA3AF;">Full log: Activity Logger → History\(note)</td></tr>
        </table></td></tr></table></body></html>
        """
        return h
    }

    private static func section(_ title: String) -> String {
        """
        <tr><td style="padding:18px 24px 8px 24px;font-size:13px;font-weight:600;color:#374151;text-transform:uppercase;letter-spacing:.05em;border-top:1px solid #F3F4F6;">\(esc(title))</td></tr>
        """
    }

    // MARK: Plain-text fallback

    static func text(_ r: DailyRecap) -> String {
        var t = ["\(r.kind) recap - \(r.dayText)", r.headline, ""]
        let active = r.usage.map { durationText($0.activeSeconds) } ?? "-"
        t.append("Active: \(active)   Check-ins: \(r.answered)   Successes: \(r.successCount)")
        if !r.goals.isEmpty {
            t += ["", "GOALS" + (r.onPlanPercent.map { " (\($0)% of check-ins on plan)" } ?? "")]
                + r.goals.map { "  \($0.done ? "✓" : "○") \($0.text)" }
        }
        if !r.categories.isEmpty {
            t += ["", "WHERE YOUR TIME WENT"] + r.categories.map { "  \(mins($0.minutes))  \($0.name)" }
        }
        t += ["", "PROBLEMS SOLVED"] + (r.solved.isEmpty ? ["  none marked"] : r.solved.map { "  ✓ \($0)" })
        if !r.days.isEmpty {
            t += ["", r.kind == "Yearly" ? "MONTH BY MONTH" : "DAY BY DAY"] + r.days.map {
                "  \($0.label)  \(durationText($0.activeSeconds))  \($0.headline)"
            }
        }
        if !r.timeline.isEmpty {
            t += ["", "TIMELINE"] + r.timeline.map {
                "  \(time($0.start))-\(time($0.end))  \($0.titles.prefix(2).joined(separator: " · "))\($0.success == true ? "  ✓" : "")"
            }
        }
        if let u = r.usage, u.activeSeconds >= 60 {
            t += ["", "SCREEN TIME"] + u.top(u.sites, 5).map { "  \(durationText($0.seconds))  \($0.name)" }
        }
        if !r.next.isEmpty { t += ["", "NEXT"] + r.next.map { "  → \($0)" } }
        return t.joined(separator: "\n")
    }
}
