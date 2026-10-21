import SwiftUI

// MARK: - Model

struct Priority: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var why = ""
    var progress = ""

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct LifeAnalysis: Identifiable, Codable, Equatable {
    struct Review: Codable, Equatable, Identifiable {
        var id = UUID()
        var priority: String
        var share: Int              // % of tracked work time serving it
        var status: String          // on track / drifting / neglected
        var evidence: String
        var move: String
    }
    struct Pattern: Codable, Equatable, Identifiable {
        var id = UUID()
        var title: String
        var detail: String
        var evidence: String?
    }
    struct Leak: Codable, Equatable, Identifiable {
        var id = UUID()
        var title: String
        var detail: String
        var hoursPerWeek: Double?
    }
    struct Tip: Codable, Equatable, Identifiable {
        var id = UUID()
        var title: String
        var detail: String
    }
    struct Experiment: Codable, Equatable, Identifiable {
        var id = UUID()
        var title: String
        var how: String
        var measure: String
    }

    var id = UUID()
    var date = Date()
    var priorities: [Priority]
    var daysTracked: Int
    var verdict: String
    var reviews: [Review]
    var patterns: [Pattern]
    var leaks: [Leak]
    var bestConditions: String
    var tips: [Tip]
    var experiments: [Experiment]
}

/// Numbers computed locally from all days (shown without AI, and sent to the AI as facts).
struct AnalysisStats {
    var daysTracked = 0
    var first: Date?
    var last: Date?
    var totalActive: Double = 0
    var answered = 0
    var missed = 0
    var skipped = 0
    var checked = 0
    var onPlan = 0
    var successes = 0
    var weekdayActive = Array(repeating: 0.0, count: 7)     // index: Calendar weekday - 1
    var weekdayDays = Array(repeating: 0, count: 7)
    var hourActive = Array(repeating: 0.0, count: 24)
    var hourMissed = Array(repeating: 0, count: 24)
    var hourOffPlan = Array(repeating: 0, count: 24)

    var avgActive: Double { daysTracked > 0 ? totalActive / Double(daysTracked) : 0 }
    var responseRate: Int? {
        let all = answered + missed + skipped
        return all > 0 ? Int((Double(answered) / Double(all) * 100).rounded()) : nil
    }
    var onPlanRate: Int? { checked > 0 ? Int((Double(onPlan) / Double(checked) * 100).rounded()) : nil }
}

// MARK: - Storage

@MainActor
final class AnalysisStore: ObservableObject {
    @Published var priorities: [Priority] = []
    @Published private(set) var prioritiesUpdated: Date?
    @Published private(set) var history: [LifeAnalysis] = []

    private let fileURL: URL

    private struct FileFormat: Codable {
        var priorities: [Priority]
        var prioritiesUpdated: Date?
        var history: [LifeAnalysis]
    }

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("analysis.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let file = try? decoder.decode(FileFormat.self, from: data) {
            priorities = file.priorities
            prioritiesUpdated = file.prioritiesUpdated
            history = file.history
        }
    }

    var activePriorities: [Priority] { priorities.filter { !$0.isEmpty } }

    func setPriorities(_ list: [Priority]) {
        priorities = list
        prioritiesUpdated = Date()
        save()
    }

    func add(_ analysis: LifeAnalysis) {
        history.insert(analysis, at: 0)
        if history.count > 30 { history = Array(history.prefix(30)) }
        save()
    }

    func delete(_ id: UUID) {
        history.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let file = FileFormat(priorities: priorities, prioritiesUpdated: prioritiesUpdated, history: history)
        if let data = try? encoder.encode(file) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - All-days digest (computed locally, kept compact for the AI)

extension ReportArchive {
    func analysisDigest(stuck: StuckStore) -> (text: String, stats: AnalysisStats) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var stats = AnalysisStats()

        // First day with any data (check-ins or screen time files), at most 180 days back
        let usageDays = ((try? FileManager.default.contentsOfDirectory(atPath: usage.directory.path)) ?? [])
            .compactMap { name -> Date? in
                guard name.hasSuffix(".json") else { return nil }
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                return f.date(from: String(name.dropLast(5)))
            }
        let earliest = ([store.entries.map(\.periodStart).min()] + [usageDays.min()]).compactMap { $0 }.min() ?? today
        let start = max(cal.startOfDay(for: earliest), cal.date(byAdding: .day, value: -180, to: today) ?? today)

        func clip(_ s: String, _ n: Int) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " / ")
            return one.count > n ? String(one.prefix(n - 1)) + "…" : one
        }
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEE dd MMM"
        let stampFmt = DateFormatter(); stampFmt.dateFormat = "dd MMM HH:mm"

        var dayLines: [String] = []
        var categoryTotals: [String: Double] = [:]
        var siteTotals: [String: Double] = [:]
        var appTotals: [String: Double] = [:]
        var weekly: [Date: (active: Double, checkins: Int, wins: Int, on: Int, checked: Int)] = [:]
        var goalDays = 0, goalsSet = 0, goalsDone = 0
        var recentGoals: [String] = []

        var d = start
        while d <= today {
            let entries = store.entries(on: d)
            let answered = entries.filter { $0.status != .missed && $0.status != .skipped }
            let u = usage.usage(for: d)
            let rec = load(d)
            let active = !answered.isEmpty || u.activeSeconds >= 300
            if active {
                stats.daysTracked += 1
                stats.first = stats.first ?? d
                stats.last = d
                let wd = cal.component(.weekday, from: d) - 1
                stats.weekdayActive[wd] += u.activeSeconds
                stats.weekdayDays[wd] += 1
            }
            stats.totalActive += u.activeSeconds
            stats.answered += answered.count
            stats.missed += entries.filter { $0.status == .missed }.count
            stats.skipped += entries.filter { $0.status == .skipped }.count
            let checked = answered.filter { $0.goalAligned != nil }
            stats.checked += checked.count
            let on = checked.filter { $0.goalAligned == true }.count
            stats.onPlan += on
            let wins = rec?.successCount ?? answered.filter { RecapBuilder.keywordSuccess(CoachService.text(of: $0)) == true }.count
            stats.successes += wins
            for h in 0..<24 { stats.hourActive[h] += u.hourly[String(format: "%02d", h)] ?? 0 }
            for e in entries where e.status == .missed { stats.hourMissed[cal.component(.hour, from: e.periodStart)] += 1 }
            for e in answered where e.goalAligned == false { stats.hourOffPlan[cal.component(.hour, from: e.periodStart)] += 1 }
            for c in rec?.categories ?? [] { categoryTotals[c.name, default: 0] += Double(c.minutes) }
            for (k, v) in u.sites { siteTotals[k, default: 0] += v }
            for (k, v) in u.apps { appTotals[k, default: 0] += v }

            let weekStart = cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d
            var w = weekly[weekStart] ?? (0, 0, 0, 0, 0)
            w.active += u.activeSeconds; w.checkins += answered.count; w.wins += wins
            w.on += on; w.checked += checked.count
            weekly[weekStart] = w

            let g = goals.goals(on: d)
            if !g.isEmpty {
                goalDays += 1; goalsSet += g.count; goalsDone += g.filter(\.done).count
                if d > (cal.date(byAdding: .day, value: -14, to: today) ?? today) {
                    recentGoals.append("\(dayFmt.string(from: d)): " + g.map { "\($0.done ? "✓" : "○") \(clip($0.text, 50))" }.joined(separator: "; "))
                }
            }

            if active {
                var line = "\(dayFmt.string(from: d)) | active \(durationText(u.activeSeconds)) | \(answered.count) check-ins"
                let missedToday = entries.filter { $0.status == .missed }.count
                if missedToday > 0 { line += " (\(missedToday) missed)" }
                if !checked.isEmpty { line += " | on-plan \(Int(Double(on) / Double(checked.count) * 100))%" }
                if wins > 0 { line += " | wins \(wins)" }
                if let cats = rec?.categories.prefix(3), !cats.isEmpty {
                    line += " | " + cats.map { "\($0.name) \(durationText(Double($0.minutes) * 60))" }.joined(separator: ", ")
                }
                let sites = u.top(u.sites, 3).filter { $0.seconds >= 600 }
                if !sites.isEmpty { line += " | web: " + sites.map { "\($0.name) \(durationText($0.seconds))" }.joined(separator: ", ") }
                if let t = rec?.tagline { line += " | \"\(t)\"" }
                dayLines.append(line)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }

        // Recent detail
        let all = store.entries.sorted { $0.periodStart > $1.periodStart }
        let recentCheckins = all.filter { $0.status != .missed && $0.status != .skipped && !CoachService.text(of: $0).isEmpty }
            .prefix(50).reversed()
            .map { "\(stampFmt.string(from: $0.periodStart)) \(clip(CoachService.text(of: $0), 80))" }
        let offPlan = all.filter { $0.goalAligned == false }.prefix(20).reversed().map { e -> String in
            var l = "\(stampFmt.string(from: e.periodStart)) did: \(clip(CoachService.text(of: e), 60))"
            if let x = e.explanation { l += " | reason: \(clip(x, 80)) | accepted: \(e.explanationAccepted == true ? "yes" : "no")" }
            else if let n = e.deviationNote { l += " | coach: \(clip(n, 60))" }
            return l
        }
        let judged = all.compactMap { e -> (String, String?)? in e.intentResult.map { ($0, e.intentReason) } }
        var followLine = "(no intentions recorded yet)"
        if !judged.isEmpty {
            let done = judged.reduce(0.0) { $0 + ($1.0 == "did" ? 1 : ($1.0 == "partly" ? 0.5 : 0)) }
            var reasons: [String: Int] = [:]
            for (r, why) in judged where r != "did" { reasons[why ?? "no reason given", default: 0] += 1 }
            followLine = "\(Int(done / Double(judged.count) * 100))% of \(judged.count) stated intentions followed through; reasons when not: "
                + reasons.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)×" }.joined(separator: ", ")
        }
        let planList = plans?.plans ?? []
        let planLines = planList.prefix(12).map { p -> String in
            var l = "\(clip(p.goal, 60)) [\(p.status.rawValue)] \(p.doneCount)/\(p.steps.count) steps, \(p.blockers.count) flow breaks"
            if let n = p.outcomeNote { l += "; why: \(clip(n, 70))" }
            if let lesson = p.lesson { l += "; lesson: \(clip(lesson, 70))" }
            return l
        }
        let blockerLines = planList.flatMap(\.blockers).sorted { $0.date > $1.date }.prefix(12)
            .map { "\($0.category ?? "Blocked"): \(clip($0.reason, 70)) (on \(clip($0.stepText, 40)))" }
        let stuckLines = stuck.sessions.prefix(10)
            .map { "\(clip($0.problem, 80))\($0.resolved ? " → solved: \(clip($0.resolution ?? "", 60))" : " (unresolved)")" }

        func top(_ dict: [String: Double], _ n: Int, minutes: Bool = false) -> String {
            dict.sorted { $0.value > $1.value }.prefix(n)
                .map { "\($0.key) \(durationText(minutes ? $0.value * 60 : $0.value))" }.joined(separator: ", ")
        }
        let weekdayNames = cal.shortWeekdaySymbols
        let weekdayText = (0..<7).filter { stats.weekdayDays[$0] > 0 }
            .map { "\(weekdayNames[$0]) \(durationText(stats.weekdayActive[$0] / Double(stats.weekdayDays[$0])))" }
            .joined(separator: ", ")
        let hourText = (0..<24).filter { stats.hourActive[$0] >= 600 || stats.hourMissed[$0] > 0 || stats.hourOffPlan[$0] > 0 }
            .map { "\($0)h: \(durationText(stats.hourActive[$0]))\(stats.hourMissed[$0] > 0 ? ", \(stats.hourMissed[$0]) missed" : "")\(stats.hourOffPlan[$0] > 0 ? ", \(stats.hourOffPlan[$0]) off-plan" : "")" }
            .joined(separator: " | ")
        let weekText = weekly.keys.sorted().suffix(8).map { k -> String in
            let w = weekly[k]!
            let plan = w.checked > 0 ? ", on-plan \(Int(Double(w.on) / Double(w.checked) * 100))%" : ""
            return "week of \(dayFmt.string(from: k)): active \(durationText(w.active)), \(w.checkins) check-ins, \(w.wins) wins\(plan)"
        }.joined(separator: "\n")

        var monthLines: [String] = []
        for back in 0..<3 {
            guard let m = cal.date(byAdding: .month, value: -back, to: today) else { continue }
            let mg = goals.monthGoals(for: m)
            if !mg.isEmpty {
                monthLines.append(m.formatted(.dateTime.month(.wide)) + ": " + mg.map { "\($0.done ? "✓" : "○") \(clip($0.text, 60))" }.joined(separator: "; "))
            }
        }

        let pace = plans?.paceFactor.map { String(format: "%.1f× estimates (%d steps)", $0.factor, $0.samples) } ?? "not enough data"
        var text = """
        TOTALS: \(stats.daysTracked) active days (\(stats.first.map { dayFmt.string(from: $0) } ?? "-") to \(stats.last.map { dayFmt.string(from: $0) } ?? "-")); \
        screen time \(durationText(stats.totalActive)) (avg \(durationText(stats.avgActive))/day); \
        check-ins answered \(stats.answered), missed \(stats.missed), skipped \(stats.skipped); \
        on-plan \(stats.onPlanRate.map { "\($0)%" } ?? "n/a") of \(stats.checked) checked; wins \(stats.successes); \
        goals: set on \(goalDays) days, \(goalsDone)/\(goalsSet) done; plan pace: \(pace).

        FOLLOW-THROUGH (said I'd do next vs did): \(followLine)

        WORK CATEGORIES (all reports): \(categoryTotals.isEmpty ? "(none yet)" : top(categoryTotals, 10, minutes: true))
        TOP WEBSITES: \(siteTotals.isEmpty ? "(none)" : top(siteTotals, 12))
        TOP APPS: \(appTotals.isEmpty ? "(none)" : top(appTotals, 10))
        AVERAGE ACTIVE BY WEEKDAY: \(weekdayText.isEmpty ? "(n/a)" : weekdayText)
        BY HOUR (total active, missed check-ins, off-plan): \(hourText.isEmpty ? "(n/a)" : hourText)

        WEEKLY TREND:
        \(weekText.isEmpty ? "(n/a)" : weekText)

        DAY BY DAY (most recent 60):
        \(dayLines.suffix(60).joined(separator: "\n"))

        OFF-PLAN MOMENTS AND REASONS GIVEN:
        \(offPlan.isEmpty ? "(none)" : offPlan.joined(separator: "\n"))

        DAILY GOALS (last 14 days):
        \(recentGoals.isEmpty ? "(none)" : recentGoals.joined(separator: "\n"))
        MONTHLY GOALS:
        \(monthLines.isEmpty ? "(none)" : monthLines.joined(separator: "\n"))

        PLANS:
        \(planLines.isEmpty ? "(none)" : planLines.joined(separator: "\n"))
        FLOW BREAKS:
        \(blockerLines.isEmpty ? "(none)" : blockerLines.joined(separator: "\n"))
        TIMES I GOT STUCK:
        \(stuckLines.isEmpty ? "(none)" : stuckLines.joined(separator: "\n"))

        RECENT CHECK-INS (what I wrote):
        \(recentCheckins.isEmpty ? "(none)" : recentCheckins.joined(separator: "\n"))
        """
        // Keep the request small enough for Groq's free tier.
        if text.count > 24_000 { text = String(text.prefix(24_000)) + "\n(…truncated)" }
        return (text, stats)
    }
}

// MARK: - Coach: the full analysis

extension CoachService {
    func analyzeEverything(priorities: [Priority], digest: String, daysTracked: Int) async throws -> LifeAnalysis {
        let pList = priorities.enumerated().map { i, p in
            var l = "\(i + 1). \(p.text)"
            if !p.why.isEmpty { l += " — why it matters: \(p.why)" }
            if !p.progress.isEmpty { l += " — progress looks like: \(p.progress)" }
            return l
        }.joined(separator: "\n")

        let system = """
        You are a sharp, caring performance coach and data analyst for an experienced engineer and product manager. \
        Think it through carefully before answering. Use only the data given — never invent facts — and quote real \
        numbers from it as evidence. Look for patterns the person is unlikely to see themselves: cross-reference \
        time of day, weekdays, websites/apps, missed check-ins, off-plan reasons, flow breaks, stuck moments and \
        goal completion. Compare their stated life priorities with where their time actually goes. Be candid but kind, \
        specific and practical. Output only valid JSON.
        """
        let user = """
        MY TOP PRIORITIES IN LIFE RIGHT NOW (from my work):
        \(pList)

        ALL MY TRACKED DATA:
        \(digest)

        Return JSON:
        {"verdict": "max 35 words: honest overall read of how things are going vs my priorities",
         "priorities": [{"priority": "copy of my priority", "share": 20,
                         "status": "on track" or "drifting" or "neglected",
                         "evidence": "max 35 words with numbers from the data",
                         "move": "max 20 words: one concrete next move this week"}],
         "hidden_patterns": [{"title": "max 7 words", "detail": "max 35 words", "evidence": "max 20 words with numbers"}],
         "time_leaks": [{"title": "max 6 words", "detail": "max 25 words", "hours_per_week": 3.5}],
         "best_conditions": "max 35 words: when and how I do my best work, from the data",
         "tips": [{"title": "max 7 words", "detail": "max 30 words: how to actually get things done, tailored to me"}],
         "experiments": [{"title": "max 8 words", "how": "max 25 words", "measure": "max 15 words: how I'll know it worked"}]}
        Rules: one entry per priority, in my order; "share" = estimated % of my tracked work time that served it \
        (the shares need not add to 100); 4-6 hidden patterns; 2-4 time leaks; 4-6 tips; 2-3 experiments for the next 7 days.
        If data is thin, say so in the verdict and keep claims modest.
        """
        let raw = try await ask(system: system, user: user, json: true)
        guard let json = extractJSON(raw) else { throw CoachError.badResponse }

        func str(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? "" }
        func list(_ k: String) -> [[String: Any]] { json[k] as? [[String: Any]] ?? [] }

        let reviews = list("priorities").map {
            LifeAnalysis.Review(priority: str($0, "priority"), share: ($0["share"] as? NSNumber)?.intValue ?? 0,
                                status: str($0, "status").lowercased(), evidence: str($0, "evidence"), move: str($0, "move"))
        }
        let analysis = LifeAnalysis(
            priorities: priorities,
            daysTracked: daysTracked,
            verdict: (json["verdict"] as? String) ?? "",
            reviews: reviews,
            patterns: list("hidden_patterns").map {
                .init(title: str($0, "title"), detail: str($0, "detail"), evidence: $0["evidence"] as? String)
            },
            leaks: list("time_leaks").map {
                .init(title: str($0, "title"), detail: str($0, "detail"), hoursPerWeek: ($0["hours_per_week"] as? NSNumber)?.doubleValue)
            },
            bestConditions: (json["best_conditions"] as? String) ?? "",
            tips: list("tips").map { .init(title: str($0, "title"), detail: str($0, "detail")) },
            experiments: list("experiments").map { .init(title: str($0, "title"), how: str($0, "how"), measure: str($0, "measure")) }
        )
        if analysis.verdict.isEmpty && analysis.reviews.isEmpty && analysis.patterns.isEmpty { throw CoachError.badResponse }
        return analysis
    }
}

// MARK: - Insights screen

struct InsightsView: View {
    let app: AppDelegate
    @ObservedObject var analysis: AnalysisStore
    @ObservedObject var nav: Navigator

    @State private var askPriorities = false
    @State private var running = false
    @State private var error: String?
    @State private var selectedID: UUID?
    @State private var stats: AnalysisStats?
    @State private var problem = ""
    @State private var breakdown: BreakdownRequest?
    @State private var addedGoals: Set<UUID> = []

    struct BreakdownRequest: Identifiable { let id = UUID(); let text: String }

    private var current: LifeAnalysis? {
        selectedID.flatMap { id in analysis.history.first { $0.id == id } } ?? analysis.history.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if running {
                    Card(title: "Analyzing", symbol: "sparkles") {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Reading all your days and comparing them with your priorities… this can take up to a minute.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                prioritiesCard
                if let stats { StatsBlock(stats: stats) }
                if let a = current {
                    AnalysisSections(analysis: a, addedGoals: $addedGoals) { exp in addGoal(exp) }
                } else if !running {
                    Card(title: "No analysis yet", symbol: "sparkles") {
                        Text("Press Analyze. You'll be asked for your top 3 priorities first, then every day you've tracked is compared against them to find patterns you can't easily see.")
                            .foregroundStyle(.secondary)
                    }
                }
                breakdownCard
            }
            .padding(28)
        }
        .onAppear {
            stats = app.archive.analysisDigest(stuck: app.stuckStore).stats
            if nav.openAnalyze { nav.openAnalyze = false; askPriorities = true }
        }
        .onChange(of: nav.openAnalyze) { open in
            if open { nav.openAnalyze = false; askPriorities = true }
        }
        .sheet(isPresented: $askPriorities) {
            PrioritiesSheet(analysis: analysis) { Task { await run() } }
        }
        .sheet(item: $breakdown) { req in BreakdownSheet(problem: req.text, coach: app.coach) }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            PageHeader(title: "Insights",
                       subtitle: stats.map { "Across all your data · \($0.daysTracked) active day\($0.daysTracked == 1 ? "" : "s")" } ?? "Across all your data")
            Spacer()
            if analysis.history.count > 1 {
                Menu {
                    ForEach(analysis.history) { a in
                        Button(a.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())) { selectedID = a.id }
                    }
                } label: {
                    Label("Past analyses", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Button { askPriorities = true } label: { Label("Analyze", systemImage: "sparkles") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(running)
        }
    }

    private var prioritiesCard: some View {
        Card(title: "Your top priorities right now", symbol: "star.fill") {
            if analysis.activePriorities.isEmpty {
                Text("Not set yet — you'll be asked when you press Analyze.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(analysis.activePriorities.enumerated()), id: \.element.id) { i, p in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.text).font(.body.weight(.semibold))
                            if !p.why.isEmpty { Text(p.why).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if let updated = analysis.prioritiesUpdated {
                    Text("Set \(updated.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var breakdownCard: some View {
        Card(title: "Break down a problem", symbol: "list.number") {
            Text("Turn something big or vague into small steps, using your history.").foregroundStyle(.secondary)
            HStack {
                TextField("Problem", text: $problem, prompt: Text("e.g. Finalize the BOM and order samples"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startBreakdown)
                Button("Break down", action: startBreakdown)
                    .disabled(problem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func startBreakdown() {
        let t = problem.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        breakdown = BreakdownRequest(text: t)
    }

    private func run() async {
        running = true
        error = nil
        let digest = app.archive.analysisDigest(stuck: app.stuckStore)
        stats = digest.stats
        do {
            let result = try await app.coach.analyzeEverything(priorities: analysis.activePriorities,
                                                               digest: digest.text,
                                                               daysTracked: digest.stats.daysTracked)
            analysis.add(result)
            selectedID = result.id
        } catch {
            self.error = error.localizedDescription
        }
        running = false
    }

    private func addGoal(_ exp: LifeAnalysis.Experiment) {
        var list = app.goals.today().filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard list.count < 5 else { error = "Today already has 5 goals."; return }
        list.append(Goal(text: exp.title))
        app.goals.setToday(list)
        addedGoals.insert(exp.id)
    }
}

// MARK: Priorities sheet

struct PrioritiesSheet: View {
    @ObservedObject var analysis: AnalysisStore
    let onAnalyze: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Priority] = []

    private let examples = ["e.g. Grow into a product leadership role",
                            "e.g. Ship my own side project and use it",
                            "e.g. Keep evenings for family and health"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Your top 3 priorities", systemImage: "star.fill").font(.title2.weight(.bold))
                Text("What do you most want your work to give you in life right now? The analysis compares where your time really goes against these.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)").font(.headline).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.accentColor))
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Priority", text: $items[i].text, prompt: Text(examples[i]))
                            .labelsHidden().textFieldStyle(.roundedBorder).font(.body.weight(.semibold))
                        HStack(spacing: 6) {
                            TextField("Why", text: $items[i].why, prompt: Text("Why it matters (optional)"))
                                .labelsHidden().textFieldStyle(.roundedBorder).font(.callout)
                            TextField("Progress", text: $items[i].progress, prompt: Text("What progress looks like (optional)"))
                                .labelsHidden().textFieldStyle(.roundedBorder).font(.callout)
                        }
                    }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button {
                    analysis.setPriorities(items)
                    dismiss()
                    onAnalyze()
                } label: { Label("Save & Analyze", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.allSatisfy(\.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear {
            var list = analysis.priorities
            while list.count < 3 { list.append(Priority()) }
            items = Array(list.prefix(3))
        }
    }
}

// MARK: Local stats + rhythm charts

private struct StatsBlock: View {
    let stats: AnalysisStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatTile(value: "\(stats.daysTracked)", label: "Active days", symbol: "calendar", tint: .accentColor)
                StatTile(value: durationText(stats.avgActive), label: "Avg screen time / day", symbol: "desktopcomputer", tint: .orange)
                StatTile(value: stats.onPlanRate.map { "\($0)%" } ?? "–", label: "Check-ins on plan", symbol: "scope", tint: .green)
                StatTile(value: stats.responseRate.map { "\($0)%" } ?? "–", label: "Check-ins answered", symbol: "checklist", tint: .purple)
            }
            HStack(alignment: .top, spacing: 12) {
                Card(title: "By weekday (avg active)", symbol: "calendar") { weekdayChart }
                Card(title: "By hour (total active · missed check-ins)", symbol: "clock") { hourChart }
            }
        }
    }

    private var weekdayChart: some View {
        let cal = Calendar.current
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 }
        let avg = order.map { stats.weekdayDays[$0] > 0 ? stats.weekdayActive[$0] / Double(stats.weekdayDays[$0]) : 0 }
        let maxV = max(1, avg.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(avg[i] > 0 ? 0.85 : 0.12))
                        .frame(height: max(3, CGFloat(avg[i] / maxV) * 80))
                    Text(cal.veryShortWeekdaySymbols[order[i]]).font(.caption2).foregroundStyle(.secondary)
                }
                .help("\(cal.weekdaySymbols[order[i]]): \(durationText(avg[i])) average")
            }
        }
        .frame(height: 100)
    }

    private var hourChart: some View {
        let maxV = max(1, stats.hourActive.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { h in
                VStack(spacing: 2) {
                    if stats.hourMissed[h] > 0 {
                        Circle().fill(Color.red).frame(width: 4, height: 4)
                    }
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.orange.opacity(stats.hourActive[h] > 0 ? 0.85 : 0.12))
                        .frame(height: max(2, CGFloat(stats.hourActive[h] / maxV) * 74))
                    Text(h % 6 == 0 ? "\(h)" : " ").font(.caption2).foregroundStyle(.secondary)
                }
                .help("\(h):00 · \(durationText(stats.hourActive[h])) active · \(stats.hourMissed[h]) missed · \(stats.hourOffPlan[h]) off-plan")
            }
        }
        .frame(height: 100)
    }
}

// MARK: Analysis result

private struct AnalysisSections: View {
    let analysis: LifeAnalysis
    @Binding var addedGoals: Set<UUID>
    let onAddGoal: (LifeAnalysis.Experiment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Verdict
            VStack(alignment: .leading, spacing: 6) {
                Text("ANALYSIS · \(analysis.date.formatted(.dateTime.day().month(.wide).hour().minute())) · \(analysis.daysTracked) DAYS OF DATA")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(analysis.verdict).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.12)))

            if !analysis.reviews.isEmpty {
                Card(title: "Your priorities vs reality", symbol: "scalemass") {
                    ForEach(Array(analysis.reviews.enumerated()), id: \.element.id) { i, r in
                        PriorityReviewRow(number: i + 1, review: r)
                        if i < analysis.reviews.count - 1 { Divider() }
                    }
                    let other = max(0, 100 - analysis.reviews.reduce(0) { $0 + $1.share })
                    if other > 0 {
                        Text("≈ \(other)% of your tracked time didn't serve any of these priorities.")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
            }

            if !analysis.patterns.isEmpty {
                Text("Patterns you might not see").font(.title3.weight(.bold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(analysis.patterns) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(p.title, systemImage: "eye").font(.headline)
                            Text(p.detail).fixedSize(horizontal: false, vertical: true)
                            if let e = p.evidence, !e.isEmpty {
                                Label(e, systemImage: "chart.bar.xaxis").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                if !analysis.leaks.isEmpty {
                    Card(title: "Time leaks", symbol: "drop.triangle") {
                        ForEach(analysis.leaks) { l in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l.title).font(.body.weight(.semibold))
                                    Text(l.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if let h = l.hoursPerWeek {
                                    Text(String(format: "≈ %.1f h/wk", h)).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                if !analysis.bestConditions.isEmpty {
                    Card(title: "When you work best", symbol: "bolt.fill") {
                        Text(analysis.bestConditions).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !analysis.tips.isEmpty {
                Card(title: "How to get things done — for you", symbol: "lightbulb") {
                    ForEach(Array(analysis.tips.enumerated()), id: \.element.id) { i, t in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1).").font(.body.weight(.bold)).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.body.weight(.semibold))
                                Text(t.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if !analysis.experiments.isEmpty {
                Card(title: "Experiments for the next 7 days", symbol: "flask") {
                    ForEach(analysis.experiments) { e in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.title).font(.body.weight(.semibold))
                                Text(e.how).font(.callout).fixedSize(horizontal: false, vertical: true)
                                Label(e.measure, systemImage: "ruler").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if addedGoals.contains(e.id) {
                                Label("Added", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
                            } else {
                                Button("Add to today's goals") { onAddGoal(e) }.controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

private struct PriorityReviewRow: View {
    let number: Int
    let review: LifeAnalysis.Review

    private var tint: Color {
        switch review.status {
        case "on track": return .green
        case "neglected": return .red
        default: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor))
                Text(review.priority).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(review.status.capitalized)
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.15)))
            }
            HStack(spacing: 10) {
                ProgressView(value: Double(min(100, max(0, review.share))), total: 100)
                    .tint(tint)
                    .frame(maxWidth: 260)
                Text("≈ \(review.share)% of your tracked time").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(review.evidence).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(review.move, systemImage: "arrow.right.circle.fill")
                .foregroundStyle(Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
