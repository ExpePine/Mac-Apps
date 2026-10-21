import SwiftUI

// MARK: - Which goal did each check-in serve?

struct GoalTimeRow: Identifiable {
    enum Kind { case goal, neutral, drift, untagged, notLogged }
    var id: String { name }
    let name: String
    var seconds: Double
    let kind: Kind
}

enum GoalAccounting {
    static let breakKinds: [String: String] = ["break": "Break", "meeting": "Meeting", "admin": "Admin"]

    /// Finds the goal a free-text name refers to (exact, then shared key words).
    static func match(_ name: String, in goals: [String]) -> String? {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if let exact = goals.first(where: { $0.lowercased() == n }) { return exact }
        if let contained = goals.first(where: { $0.lowercased().contains(n) || n.contains($0.lowercased()) }) { return contained }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
        }
        let target = words(n)
        let scored = goals.map { ($0, words($0).intersection(target).count) }.filter { $0.1 > 0 }
        return scored.max { $0.1 < $1.1 }?.0
    }

    static func classify(_ e: Entry, goals: [String]) -> (name: String, kind: GoalTimeRow.Kind) {
        if e.status == .missed || e.status == .skipped { return ("Not logged", .notLogged) }
        if let k = e.checkinKind, let label = breakKinds[k] { return (label, .neutral) }
        if e.checkinKind == "drift" || e.goalAligned == false { return ("Drift / off-plan", .drift) }
        if let tag = e.goalTag, !tag.isEmpty { return (match(tag, in: goals) ?? tag, .goal) }
        if e.goalAligned == true, let g = e.alignedGoal, !g.isEmpty { return (match(g, in: goals) ?? g, .goal) }
        return ("Untagged", .untagged)
    }

    static func rows(_ entries: [Entry], goals: [String]) -> [GoalTimeRow] {
        var totals: [String: (Double, GoalTimeRow.Kind)] = [:]
        for e in entries {
            let c = classify(e, goals: goals)
            let secs = e.periodEnd.timeIntervalSince(e.periodStart)
            totals[c.name, default: (0, c.kind)].0 += secs
        }
        // Goals with no time yet still show (that's the point).
        for g in goals where totals[g] == nil { totals[g] = (0, .goal) }
        let order: [GoalTimeRow.Kind] = [.goal, .neutral, .drift, .untagged, .notLogged]
        return totals.map { GoalTimeRow(name: $0.key, seconds: $0.value.0, kind: $0.value.1) }
            .sorted { a, b in
                let ia = order.firstIndex(of: a.kind)!, ib = order.firstIndex(of: b.kind)!
                return ia != ib ? ia < ib : a.seconds > b.seconds
            }
    }

    struct Summary {
        var goalSeconds = 0.0
        var driftSeconds = 0.0
        var untaggedSeconds = 0.0
        var tiedShare: Double? = nil         // goal time / (goal + drift + untagged)
        var driftShare: Double? = nil
        var pull: (name: String, share: Double)? = nil      // goal taking the biggest share of goal time
        var neglected: [String] = []

        var warning: String? {
            if let p = pull, p.share >= 0.6, !neglected.isEmpty {
                return "\(Int(p.share * 100))% of goal time went to “\(p.name)” — \(neglected.prefix(2).map { "“\($0)”" }.joined(separator: " and ")) got none."
            }
            if let d = driftShare, d >= 0.35 { return "\(Int(d * 100))% of logged time was drift or off-plan." }
            return nil
        }
    }

    static func summary(_ rows: [GoalTimeRow], goals: [String]) -> Summary {
        var s = Summary()
        let goalRows = rows.filter { $0.kind == .goal }
        s.goalSeconds = goalRows.reduce(0) { $0 + $1.seconds }
        s.driftSeconds = rows.filter { $0.kind == .drift }.reduce(0) { $0 + $1.seconds }
        s.untaggedSeconds = rows.filter { $0.kind == .untagged }.reduce(0) { $0 + $1.seconds }
        let base = s.goalSeconds + s.driftSeconds + s.untaggedSeconds
        if base > 0 {
            s.tiedShare = s.goalSeconds / base
            s.driftShare = s.driftSeconds / base
        }
        if s.goalSeconds > 0, let top = goalRows.max(by: { $0.seconds < $1.seconds }) {
            s.pull = (top.name, top.seconds / s.goalSeconds)
        }
        s.neglected = goals.filter { g in (goalRows.first { $0.name == g }?.seconds ?? 0) < 60 }
        return s
    }
}

// MARK: - Coach: guess where I am, explain my path

struct PositionGuess {
    var kind: String            // goal / break / meeting / admin / drift
    var goal: String?
    var planID: UUID?
    var stepID: UUID?
    var why: String
}

extension CoachService {
    func guessPosition(goals: [String], plans: [Plan], previous: Entry?, usageText: String) async -> PositionGuess? {
        guard hasKey else { return nil }
        var planText = ""
        for (pi, p) in plans.enumerated() {
            planText += "P\(pi + 1) \"\(p.goal)\":\n"
            for (si, s) in p.steps.enumerated() where s.status != .skipped {
                let mark = si == p.currentIndex ? " ← current" : ""
                planText += "  \(si + 1). [\(s.status.rawValue)] \(s.text)\(mark)\n"
            }
        }
        let user = """
        My goals:
        \(goals.enumerated().map { "G\($0 + 1). \($1)" }.joined(separator: "\n"))

        My active plan paths:
        \(planText.isEmpty ? "(none)" : planText)
        Previous check-in: \(previous.map { "\($0.timeRangeText): \(CoachService.text(of: $0))" } ?? "(none)")
        Screen activity in this period: \(usageText.isEmpty ? "(no data)" : usageText)

        Guess where I most likely am right now. Prefer continuity with the previous check-in unless the screen \
        activity clearly says otherwise. Entertainment/news/social sites with no link to a goal suggest drift.
        Return {"kind": "goal" or "break" or "meeting" or "admin" or "drift",
                "goal": "G number like G2, or null", "plan": "P number like P1, or null", "step": step number or null,
                "confidence": 0.0-1.0, "why": "max 10 words"}
        """
        guard let raw = try? await ask(system: "You infer what someone is working on from their plan and screen activity. Output only valid JSON.",
                                       user: user, json: true),
              let json = extractJSON(raw) else { return nil }
        let confidence = (json["confidence"] as? NSNumber)?.doubleValue ?? 0
        guard confidence >= 0.45 else { return nil }
        func index(_ v: Any?, prefix: String) -> Int? {
            if let n = v as? NSNumber { return n.intValue - 1 }
            if let s = v as? String { return Int(s.uppercased().replacingOccurrences(of: prefix, with: "")).map { $0 - 1 } }
            return nil
        }
        var g = PositionGuess(kind: (json["kind"] as? String ?? "goal").lowercased(), why: json["why"] as? String ?? "")
        if let gi = index(json["goal"], prefix: "G"), gi >= 0, gi < goals.count { g.goal = goals[gi] }
        if let pi = index(json["plan"], prefix: "P"), pi >= 0, pi < plans.count {
            let plan = plans[pi]
            g.planID = plan.id
            if let si = index(json["step"], prefix: ""), si >= 0, si < plan.steps.count { g.stepID = plan.steps[si].id }
            if g.goal == nil { g.goal = GoalAccounting.match(plan.goal, in: goals) ?? plan.goal }
        }
        return g
    }

    func explainPath(_ digest: String) async throws -> PathNote {
        let user = """
        \(digest)

        Describe how my work actually moved through this period, like a route on a map.
        Return {"path": "max 70 words: how the work moved day by day across goals",
                "drift": "max 30 words: which direction I tend to drift, and when",
                "tied": "max 20 words: how goal-tied the period was",
                "suggestion": "max 25 words: one change for next period"}
        """
        let raw = try await ask(system: "You read time logs and describe work patterns plainly and specifically. Use only the data. Output only valid JSON.",
                                user: user, json: true)
        guard let json = extractJSON(raw), let path = json["path"] as? String else { throw CoachError.badResponse }
        return PathNote(path: path, drift: json["drift"] as? String ?? "", tied: json["tied"] as? String ?? "",
                        suggestion: json["suggestion"] as? String ?? "")
    }
}

/// What was on screen between two times (from the usage timeline).
func usageSummary(_ usage: DayUsage, from start: Date, to end: Date) -> String {
    let midnight = Calendar.current.startOfDay(for: start)
    let s = Int(start.timeIntervalSince(midnight)), e = Int(end.timeIntervalSince(midnight))
    var sites: [String: Int] = [:], apps: [String: Int] = [:]
    for seg in usage.segments ?? [] {
        let overlap = min(seg.end, e) - max(seg.start, s)
        guard overlap > 0 else { continue }
        apps[seg.app, default: 0] += overlap
        if let site = seg.site { sites[site, default: 0] += overlap }
    }
    func top(_ d: [String: Int]) -> String {
        d.filter { $0.value >= 30 }.sorted { $0.value > $1.value }.prefix(5)
            .map { "\($0.key) \(durationText(Double($0.value)))" }.joined(separator: ", ")
    }
    return [top(apps).isEmpty ? "" : "apps: \(top(apps))", top(sites).isEmpty ? "" : "sites: \(top(sites))"]
        .filter { !$0.isEmpty }.joined(separator: "; ")
}

// MARK: - Path notes (AI summaries), stored next to reports

struct PathNote: Codable, Equatable {
    var path: String
    var drift: String
    var tied: String
    var suggestion: String
    var date = Date()
}

extension ReportArchive {
    private var pathNotesURL: URL { directory.deletingLastPathComponent().appendingPathComponent("paths.json") }

    func pathNotes() -> [String: PathNote] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: pathNotesURL) else { return [:] }
        return (try? decoder.decode([String: PathNote].self, from: data)) ?? [:]
    }

    func savePathNote(_ note: PathNote, key: String) {
        var all = pathNotes()
        all[key] = note
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(all) { try? data.write(to: pathNotesURL, options: .atomic) }
    }

    /// All goal names relevant to a period: monthly goals first, then daily goals by frequency.
    func goalNames(in days: [Date]) -> [String] {
        var month: [String] = []
        var daily: [String: Int] = [:]
        for d in days {
            for g in goals.monthGoals(for: d) where !month.contains(g.text) { month.append(g.text) }
            for g in goals.goals(on: d) { daily[g.text, default: 0] += 1 }
        }
        let dailySorted = daily.sorted { $0.value > $1.value }.map(\.key).filter { !month.contains($0) }
        return month + dailySorted
    }

    /// Goal-tied share and drift share for one day (for calendar cells).
    func goalSplit(_ day: Date) -> (tied: Double, drift: Double)? {
        let entries = store.entries(on: day)
        guard !entries.isEmpty else { return nil }
        let goals = goalNames(in: [day])
        let s = GoalAccounting.summary(GoalAccounting.rows(entries, goals: goals), goals: goals)
        guard let t = s.tiedShare else { return nil }
        return (t, s.driftShare ?? 0)
    }
}

// MARK: - Week / month work path

struct WorkPathPanel: View {
    @ObservedObject var archive: ReportArchive
    let coach: CoachService?
    let anchor: Date

    enum Span: String, CaseIterable, Identifiable { case week = "Week", month = "Month"; var id: String { rawValue } }

    @State private var span: Span = .week
    @State private var weekAnchor: Date?
    @State private var explaining = false
    @State private var error: String?
    @State private var notes: [String: PathNote] = [:]

    private var cal: Calendar { Calendar.current }

    private var period: DateInterval {
        switch span {
        case .month: return archive.interval(.month, containing: anchor)
        case .week:
            let month = archive.interval(.month, containing: anchor)
            let base = weekAnchor ?? (month.contains(Date()) ? Date() : month.start)
            return archive.interval(.week, containing: base)
        }
    }

    private var key: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "\(span.rawValue.lowercased())-\(f.string(from: period.start))"
    }

    private var days: [Date] { archive.days(in: period) }
    private var goals: [String] { archive.goalNames(in: days) }

    /// [day][row name] = seconds
    private var grid: (rows: [GoalTimeRow], perDay: [[String: Double]]) {
        var perDay: [[String: Double]] = []
        var all: [Entry] = []
        for d in days {
            let entries = archive.store.entries(on: d)
            all += entries
            var m: [String: Double] = [:]
            for e in entries {
                let c = GoalAccounting.classify(e, goals: goals)
                m[c.name, default: 0] += e.periodEnd.timeIntervalSince(e.periodStart)
            }
            perDay.append(m)
        }
        let rows = GoalAccounting.rows(all, goals: Array(goals.prefix(8))).filter { $0.kind != .notLogged || $0.seconds > 0 }
        return (Array(rows.prefix(12)), perDay)
    }

    var body: some View {
        _ = archive.version
        let g = grid
        let summary = GoalAccounting.summary(g.rows, goals: Array(goals.prefix(8)))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Work path", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.title3.weight(.bold))
                Picker("Span", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                if span == .week {
                    Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                        .disabled(period.contains(Date()))
                }
                Text(archive.label(span == .week ? .week : .month, period)).foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 12) {
                StatTile(value: summary.tiedShare.map { "\(Int($0 * 100))%" } ?? "–", label: "Goal-tied time", symbol: "target", tint: .green)
                StatTile(value: summary.driftShare.map { "\(Int($0 * 100))%" } ?? "–", label: "Drift / off-plan", symbol: "arrow.triangle.branch", tint: .orange)
                StatTile(value: summary.pull.map { "\(Int($0.share * 100))%" } ?? "–",
                         label: summary.pull.map { "Pull: \($0.name)" } ?? "Strongest pull", symbol: "arrow.up.right", tint: .purple)
                StatTile(value: "\(summary.neglected.count)", label: summary.neglected.first.map { "Neglected: \($0)" } ?? "Neglected goals",
                         symbol: "exclamationmark.circle", tint: .red)
            }
            if let w = summary.warning {
                Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }

            Card(title: "Time by goal, day by day", symbol: "square.grid.3x3") {
                pathStrip(g.perDay)
                heatGrid(g.rows, g.perDay)
            }

            stepsDone

            Card(title: "Explain my path", symbol: "sparkles") {
                if let note = notes[key] {
                    Text(note.path).fixedSize(horizontal: false, vertical: true)
                    if !note.drift.isEmpty { Label(note.drift, systemImage: "arrow.triangle.branch").foregroundStyle(.orange) }
                    if !note.tied.isEmpty { Label(note.tied, systemImage: "target").foregroundStyle(.secondary) }
                    if !note.suggestion.isEmpty { Label(note.suggestion, systemImage: "lightbulb").foregroundStyle(Color.accentColor) }
                } else {
                    Text("Get a plain-language read of how your work moved through this \(span.rawValue.lowercased()), and which way you drift.")
                        .foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    if explaining { ProgressView().controlSize(.small) }
                    Button(notes[key] == nil ? "Explain" : "Explain again") { Task { await explain(g) } }
                        .disabled(explaining || coach == nil || g.perDay.allSatisfy(\.isEmpty))
                }
            }
        }
        .onAppear { notes = archive.pathNotes() }
    }

    // MARK: Pieces

    private func color(_ row: GoalTimeRow) -> Color {
        switch row.kind {
        case .goal: return areaColor(row.name)
        case .drift: return .orange
        case .neutral: return .teal
        case .untagged, .notLogged: return .gray
        }
    }

    private func dayLabel(_ d: Date) -> String {
        span == .week ? d.formatted(.dateTime.weekday(.abbreviated)) : "\(cal.component(.day, from: d))"
    }

    /// The route: each day's dominant direction as a coloured stop.
    private func pathStrip(_ perDay: [[String: Double]]) -> some View {
        let goalSet = Set(goals)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    let m = perDay[i]
                    let top = m.filter { $0.key != "Not logged" }.max { $0.value < $1.value }
                    let name = top?.key
                    let c: Color = name == nil ? .clear
                        : (name == "Drift / off-plan" ? .orange : (goalSet.contains(name!) ? areaColor(name!) : .gray))
                    VStack(spacing: 3) {
                        Text(dayLabel(d)).font(.caption2).foregroundStyle(.secondary)
                        Circle().fill(c).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.secondary.opacity(name == nil ? 0.3 : 0), lineWidth: 1))
                        if span == .week, let name {
                            Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.center).frame(width: 80)
                        }
                    }
                    .help(name.map { "\(d.formatted(.dateTime.weekday(.wide).day().month())): mostly \($0)" } ?? "No check-ins")
                    if i < days.count - 1 {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: span == .week ? 16 : 6, height: 2)
                            .padding(.top, 14)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
    }

    private func heatGrid(_ rows: [GoalTimeRow], _ perDay: [[String: Double]]) -> some View {
        let maxV = max(1, perDay.flatMap { $0.values }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                HStack(spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(color(row)).frame(width: 8, height: 8)
                        Text(row.name).font(.callout).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(durationText(row.seconds)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(width: 230)
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        let v = perDay[i][row.name] ?? 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(v > 0 ? color(row).opacity(0.25 + 0.75 * v / maxV) : Color.secondary.opacity(0.07))
                            .frame(height: 18)
                            .help("\(d.formatted(.dateTime.weekday(.abbreviated).day().month())) · \(row.name): \(durationText(v))")
                    }
                }
            }
        }
    }

    @ViewBuilder private var stepsDone: some View {
        let events = (archive.plans?.plans ?? []).flatMap { p in
            p.events.filter { $0.kind == .stepDone && period.contains($0.date) }.map { (p.goal, $0) }
        }.sorted { $0.1.date < $1.1.date }
        if !events.isEmpty {
            Card(title: "Steps completed (\(events.count))", symbol: "checkmark.circle") {
                ForEach(Array(events.prefix(15).enumerated()), id: \.offset) { _, item in
                    let (goal, e) = item
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.date.formatted(.dateTime.weekday(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(e.text.replacingOccurrences(of: "Done: ", with: "")).lineLimit(1)
                        Spacer()
                        Text(goal).font(.caption).foregroundStyle(areaColor(goal)).lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func moveWeek(_ delta: Int) {
        let base = period.start
        if let d = cal.date(byAdding: .weekOfYear, value: delta, to: base) { weekAnchor = min(d, Date()) }
    }

    private func explain(_ g: (rows: [GoalTimeRow], perDay: [[String: Double]])) async {
        guard let coach else { return }
        explaining = true
        error = nil
        var lines: [String] = ["Period: \(archive.label(span == .week ? .week : .month, period))",
                               "Goals: " + goals.prefix(8).joined(separator: "; "),
                               "Totals: " + g.rows.filter { $0.seconds > 0 }.map { "\($0.name) \(durationText($0.seconds))" }.joined(separator: ", "),
                               "", "Day by day:"]
        for (i, d) in days.enumerated() where !g.perDay[i].isEmpty {
            let parts = g.perDay[i].sorted { $0.value > $1.value }.map { "\($0.key) \(durationText($0.value))" }.joined(separator: ", ")
            var line = "\(d.formatted(.dateTime.weekday(.abbreviated).day().month())): \(parts)"
            let texts = archive.store.entries(on: d).filter { $0.status != .missed && $0.status != .skipped }
                .prefix(6).map { String(CoachService.text(of: $0).prefix(50)) }
            if !texts.isEmpty { line += " | notes: " + texts.joined(separator: " / ") }
            lines.append(line)
        }
        do {
            let note = try await coach.explainPath(String(lines.joined(separator: "\n").prefix(16_000)))
            archive.savePathNote(note, key: key)
            notes[key] = note
        } catch {
            self.error = error.localizedDescription
        }
        explaining = false
    }
}
