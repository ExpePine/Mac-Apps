import Foundation

enum ReportKind: String, CaseIterable, Identifiable {
    case calendar = "Calendar", day = "Day", week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }

    var calendarComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month, .calendar: return .month
        case .year: return .year
        }
    }

    var recapKind: String {
        switch self {
        case .day: return "Daily"
        case .week: return "Weekly"
        case .month, .calendar: return "Monthly"
        case .year: return "Yearly"
        }
    }
}

/// Stores one recap per day in Reports/daily/YYYY-MM-DD.json (+ .html),
/// and builds week / month / year reports by adding those up.
@MainActor
final class ReportArchive: ObservableObject {
    let directory: URL
    /// Bumped whenever a report is saved, so views refresh.
    @Published private(set) var version = 0

    let store: EntryStore
    let usage: UsageStore
    let goals: GoalsStore
    /// Set by the app delegate; used for flow breaks in the day replay.
    weak var plans: PlanStore?

    init(baseDirectory: URL, store: EntryStore, usage: UsageStore, goals: GoalsStore) {
        directory = baseDirectory.appendingPathComponent("Reports/daily", isDirectory: true)
        self.store = store
        self.usage = usage
        self.goals = goals
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ day: Date, _ ext: String) -> URL {
        directory.appendingPathComponent("\(UsageStore.key(day)).\(ext)")
    }

    // MARK: Daily records

    func save(_ recap: DailyRecap, for day: Date) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(recap) {
            try? data.write(to: url(day, "json"), options: .atomic)
        }
        try? Data(RecapRenderer.html(recap).utf8).write(to: url(day, "html"), options: .atomic)
        version += 1
    }

    func load(_ day: Date) -> DailyRecap? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(day, "json")) else { return nil }
        return try? decoder.decode(DailyRecap.self, from: data)
    }

    func hasRecord(_ day: Date) -> Bool {
        FileManager.default.fileExists(atPath: url(day, "json").path)
    }

    /// Days that had check-ins or screen time.
    func hasActivity(_ day: Date) -> Bool {
        !store.entries(on: day).isEmpty || usage.usage(for: day).activeSeconds >= 60
    }

    // MARK: Periods

    func interval(_ kind: ReportKind, containing date: Date) -> DateInterval {
        Calendar.current.dateInterval(of: kind.calendarComponent, for: date)
            ?? DateInterval(start: Calendar.current.startOfDay(for: date), duration: 86_400)
    }

    func days(in interval: DateInterval) -> [Date] {
        let cal = Calendar.current
        var result: [Date] = []
        var d = cal.startOfDay(for: interval.start)
        let end = min(interval.end, cal.startOfDay(for: Date()).addingTimeInterval(86_400))
        while d < end {
            result.append(d)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return result
    }

    func label(_ kind: ReportKind, _ interval: DateInterval) -> String {
        let start = interval.start
        let last = interval.end.addingTimeInterval(-1)
        switch kind {
        case .day: return start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week: return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month, .calendar: return start.formatted(.dateTime.month(.wide).year())
        case .year: return start.formatted(.dateTime.year())
        }
    }

    /// Past days in the period that have activity but no stored report.
    func missingDays(_ kind: ReportKind, containing date: Date) -> [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return days(in: interval(kind, containing: date)).filter { day in
            guard day < today, hasActivity(day) else { return false }
            guard let rec = load(day) else { return true }
            // The calendar also needs the 3-word summary (older reports don't have it).
            return kind == .calendar && rec.tagline == nil
        }
    }

    // MARK: Aggregation

    // MARK: Calendar

    struct CalendarDay {
        let date: Date
        let tagline: String?
        let topCategory: String?
        let activeSeconds: Double
        let checkIns: Int
        let successes: Int
        let hasRecord: Bool
    }

    func calendarDay(_ day: Date) -> CalendarDay {
        let rec = load(day)
        let entries = store.entries(on: day).filter { $0.status != .missed && $0.status != .skipped }
        return CalendarDay(
            date: day,
            tagline: rec?.tagline ?? rec.map { RecapBuilder.threeWords($0.headline) },
            topCategory: rec?.categories.first?.name,
            activeSeconds: usage.usage(for: day).activeSeconds,
            checkIns: entries.count,
            successes: rec?.successCount
                ?? entries.filter { RecapBuilder.keywordSuccess(CoachService.text(of: $0)) == true }.count,
            hasRecord: rec != nil
        )
    }

    func aggregate(_ kind: ReportKind, containing date: Date) -> DailyRecap {
        let range = interval(kind, containing: date)
        let allDays = days(in: range)
        var recap = DailyRecap(dayText: label(kind, range), headline: "")
        recap.kind = kind.recapKind

        var categoryMinutes: [String: Int] = [:]
        var solved: [String] = []
        var successes = 0
        var missing = 0
        var usageSum = DayUsage()
        var rows: [DaySummary] = []
        var monthRows: [String: DaySummary] = [:]
        var monthOrder: [String] = []
        var checkedOn = 0, checkedTotal = 0
        let today = Calendar.current.startOfDay(for: Date())

        for day in allDays {
            let rec = load(day)
            let entries = store.entries(on: day)
            let u = usage.usage(for: day)
            let answered = entries.filter { $0.status != .missed && $0.status != .skipped }

            // Usage totals
            usageSum.activeSeconds += u.activeSeconds
            for (k, v) in u.sites { usageSum.sites[k, default: 0] += v }
            for (k, v) in u.apps { usageSum.apps[k, default: 0] += v }
            if usageSum.firstActive == nil { usageSum.firstActive = u.firstActive }
            if u.lastActive != nil { usageSum.lastActive = u.lastActive }

            // Check-in counts come straight from the log
            recap.answered += answered.count
            recap.missed += entries.filter { $0.status == .missed }.count
            let checked = answered.filter { $0.goalAligned != nil }
            checkedTotal += checked.count
            checkedOn += checked.filter { $0.goalAligned == true }.count

            var daySuccesses = 0
            var topCategory: String?
            var headline: String
            if let rec {
                for c in rec.categories { categoryMinutes[c.name, default: 0] += c.minutes }
                daySuccesses = rec.successCount
                let short = day.formatted(.dateTime.day().month(.abbreviated))
                solved += rec.solved.map { "\(short): \($0)" }
                topCategory = rec.categories.first?.name
                headline = rec.headline
            } else {
                daySuccesses = answered.filter { RecapBuilder.keywordSuccess(CoachService.text(of: $0)) == true }.count
                if day < today && (!entries.isEmpty || u.activeSeconds >= 60) { missing += 1 }
                headline = entries.isEmpty ? (u.activeSeconds >= 60 ? "Screen time only" : "No activity")
                                           : (day >= today ? "In progress" : "Report not generated yet")
            }
            successes += daySuccesses

            if kind == .year {
                let key = day.formatted(.dateTime.month(.wide))
                if monthRows[key] == nil {
                    monthOrder.append(key)
                    monthRows[key] = DaySummary(label: key, headline: "", activeSeconds: 0, answered: 0, successes: 0, topCategory: nil)
                }
                monthRows[key]!.activeSeconds += u.activeSeconds
                monthRows[key]!.answered += answered.count
                monthRows[key]!.successes += daySuccesses
            } else if !entries.isEmpty || u.activeSeconds >= 60 {
                rows.append(DaySummary(label: day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                                       headline: headline, activeSeconds: u.activeSeconds,
                                       answered: answered.count, successes: daySuccesses, topCategory: topCategory))
            }
        }

        if kind == .year {
            // Top category per month from stored daily reports
            for key in monthOrder {
                var cats: [String: Int] = [:]
                for day in allDays where day.formatted(.dateTime.month(.wide)) == key {
                    for c in load(day)?.categories ?? [] { cats[c.name, default: 0] += c.minutes }
                }
                let top = cats.max { $0.value < $1.value }?.key
                monthRows[key]!.topCategory = top
                let row = monthRows[key]!
                monthRows[key]!.headline = row.answered == 0 && row.activeSeconds < 60
                    ? "No activity"
                    : (top.map { "Mostly \($0)" } ?? "Not categorized yet")
            }
            rows = monthOrder.compactMap { monthRows[$0] }.filter { $0.answered > 0 || $0.activeSeconds >= 60 }
        }

        recap.categories = categoryMinutes.sorted { $0.value > $1.value }
            .map { CategoryMinutes(name: $0.key, minutes: $0.value) }
        recap.solved = Array(solved.suffix(kind == .year ? 40 : 25))
        recap.successTotal = successes
        recap.days = rows
        recap.missingDays = missing
        recap.usage = usageSum.activeSeconds >= 60 ? usageSum : nil
        if checkedTotal > 0 { recap.onPlanPercent = Int((Double(checkedOn) / Double(checkedTotal) * 100).rounded()) }
        if kind == .month { recap.goals = goals.monthGoals(for: range.start) }
        recap.headline = recap.categories.isEmpty
            ? (rows.isEmpty ? "No activity recorded in this period." : "Activity recorded — generate daily reports for categories.")
            : "Mostly " + recap.categories.prefix(2).map(\.name).joined(separator: " and ")
              + " · \(durationText(Double(recap.categories.reduce(0) { $0 + $1.minutes }) * 60)) logged."
        return recap
    }

    // MARK: Timeline CSV

    /// One row per check-in in the period, with the report's category and title where available.
    func timelineCSV(_ kind: ReportKind, containing date: Date) -> String {
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
        func esc(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return "" }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func yesNo(_ b: Bool?) -> String { b.map { $0 ? "yes" : "no" } ?? "" }

        var lines = ["date,start,end,minutes,status,category,title,text,voice_transcript,success,on_plan,goal_served,off_plan_reason,explanation,explanation_accepted,coach_feedback"]
        for day in days(in: interval(kind, containing: date)) {
            let blocks = load(day)?.timeline ?? []
            for e in store.entries(on: day).sorted(by: { $0.periodStart < $1.periodStart }) {
                let block = blocks.first { e.periodStart >= $0.start.addingTimeInterval(-60) && e.periodEnd <= $0.end.addingTimeInterval(60) }
                let text = CoachService.text(of: e)
                let success = block?.success ?? RecapBuilder.keywordSuccess(text)
                let minutes = Int((e.periodEnd.timeIntervalSince(e.periodStart) / 60).rounded())
                lines.append([
                    dayFmt.string(from: e.periodStart), timeFmt.string(from: e.periodStart), timeFmt.string(from: e.periodEnd),
                    "\(minutes)", e.status.rawValue, esc(block?.category), esc(block?.titles.first),
                    esc(e.text), esc(e.transcript), yesNo(success), yesNo(e.goalAligned), esc(e.alignedGoal),
                    esc(e.goalAligned == false ? e.deviationNote : nil), esc(e.explanation),
                    yesNo(e.explanationAccepted), esc(e.coachFeedback),
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }
}
