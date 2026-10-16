import Foundation

// MARK: - Shared models

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: String          // "user" or "assistant"
    var text: String
    var date = Date()
}

struct StuckSession: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var problem: String
    var messages: [ChatMessage] = []
    var resolved = false
    var resolution: String?
}

struct Alignment {
    let aligned: Bool
    let goal: String?
    let reason: String
}

struct Judgement {
    let accepted: Bool
    let feedback: String
    let suggestion: String?
}

struct InsightItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

struct PatternReport {
    var patterns: [InsightItem]
    var suggestions: [InsightItem]
    var bestTime: String?
    var date = Date()
}

struct BreakdownStep: Identifiable {
    let id = UUID()
    let text: String
    let minutes: Int?
    var why: String? = nil
}

enum CoachError: LocalizedError {
    case noKey, badResponse
    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Groq API key in Settings to use the coach."
        case .badResponse: return "The AI answer couldn't be read. Please try again."
        }
    }
}

/// Finds the first {...} block in a model reply and parses it.
func extractJSON(_ raw: String) -> [String: Any]? {
    guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
          let data = String(raw[start...end]).data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - Stuck sessions storage

@MainActor
final class StuckStore: ObservableObject {
    @Published private(set) var sessions: [StuckSession] = []
    private let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("stuck.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let list = try? decoder.decode([StuckSession].self, from: data) {
            sessions = list.sorted { $0.date > $1.date }
        }
    }

    func upsert(_ session: StuckSession) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.insert(session, at: 0)
        }
        save()
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(sessions) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Coach

@MainActor
final class CoachService: ObservableObject {
    private let settings: SettingsStore
    private let store: EntryStore
    private let goals: GoalsStore
    private let usage: UsageStore
    let stuck: StuckStore

    /// Set by the app delegate; used to mention the active plan step in prompts.
    var plans: PlanStore?

    private var lastSnapshot: DayUsage?
    private var lastSnapshotKey = ""

    init(settings: SettingsStore, store: EntryStore, goals: GoalsStore, usage: UsageStore, stuck: StuckStore) {
        self.settings = settings
        self.store = store
        self.goals = goals
        self.usage = usage
        self.stuck = stuck
    }

    var hasKey: Bool { !Keychain.get(Keychain.groqAPIKey).isEmpty }

    func ask(system: String, user: String, json: Bool) async throws -> String {
        let key = Keychain.get(Keychain.groqAPIKey)
        guard !key.isEmpty else { throw CoachError.noKey }
        return try await Groq.complete(apiKey: key, model: settings.groqModel, system: system, user: user, jsonMode: json)
    }

    // MARK: Context helpers

    static func text(of e: Entry) -> String {
        let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (e.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : t
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " / ")
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }

    func goalsContext() -> String {
        let d = goals.activeToday, m = goals.activeMonth
        let daily = d.isEmpty ? "(none set)" : d.enumerated()
            .map { "\($0 + 1). \($1.text)\($1.done ? " [done]" : "")" }.joined(separator: "\n")
        let monthly = m.isEmpty ? "(none set)" : m.map { "- \($0.text)\($0.done ? " [done]" : "")" }.joined(separator: "\n")
        var context = "Today's goals:\n\(daily)\n\nThis month's goals:\n\(monthly)"
        if let plan = plans?.activePlan, let i = plan.currentIndex {
            context += "\n\nActive plan: \(plan.goal)\nCurrent step: \(plan.steps[i].text)"
        }
        return context
    }

    /// Website/app time since the previous check-in (difference of daily totals).
    private func periodUsageText() -> String {
        let now = Date()
        let key = UsageStore.key(now)
        let current = usage.usage(for: now)
        defer { lastSnapshot = current; lastSnapshotKey = key }
        guard key == lastSnapshotKey, let previous = lastSnapshot else { return "" }

        var sites = current.sites, apps = current.apps
        for (k, v) in previous.sites { sites[k, default: 0] -= v }
        for (k, v) in previous.apps { apps[k, default: 0] -= v }
        func top(_ d: [String: Double]) -> String {
            d.filter { $0.value >= 60 }.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key) \(durationText($0.value))" }.joined(separator: ", ")
        }
        var parts: [String] = []
        let s = top(sites), a = top(apps)
        if !s.isEmpty { parts.append("websites: \(s)") }
        if !a.isEmpty { parts.append("apps: \(a)") }
        return parts.joined(separator: "; ")
    }

    // MARK: 1. Goal alignment after each check-in

    func review(_ entry: Entry) async -> Alignment? {
        let usageText = periodUsageText()     // always advance the snapshot
        guard settings.coachChecksEnabled, !goals.activeToday.isEmpty, hasKey else { return nil }
        let text = Self.text(of: entry)
        guard !text.isEmpty || !usageText.isEmpty else { return nil }

        let system = "You are a fair, practical productivity coach. Output only valid JSON."
        let user = """
        \(goalsContext())

        Check-in \(entry.timeRangeText): "\(text.isEmpty ? "(nothing written)" : Self.clip(text, 400))"
        Measured in this period: \(usageText.isEmpty ? "(no data)" : usageText)

        Did this period serve at least one goal? Count reasonable supporting work (research, \
        communication, setup, necessary admin for a goal) as aligned. A short break (under 10 min) is aligned.
        Return {"aligned": true or false, "goal": "short name of the goal it served, or null", \
        "reason": "max 15 words"}
        """
        guard let raw = try? await ask(system: system, user: user, json: true),
              let json = extractJSON(raw), let aligned = json["aligned"] as? Bool else { return nil }
        let goal = (json["goal"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        let reason = (json["reason"] as? String) ?? (aligned ? "Fits your goals." : "Doesn't match today's goals.")
        store.update(entry.id) {
            $0.goalAligned = aligned
            $0.alignedGoal = goal
            $0.deviationNote = reason
        }
        return Alignment(aligned: aligned, goal: goal, reason: reason)
    }

    // MARK: 2. Is the explanation for a deviation reasonable?

    func judge(entry: Entry, alignment: Alignment, explanation: String) async throws -> Judgement {
        let system = """
        You are a supportive but honest productivity coach. Judge whether the person's explanation \
        for drifting from their plan is a sound reason (urgent request, dependency, meeting, health, \
        a deliberate re-prioritisation) or avoidance/distraction. Output only valid JSON.
        """
        let user = """
        \(goalsContext())

        Check-in \(entry.timeRangeText): "\(Self.clip(Self.text(of: entry), 300))"
        Why it looked off-plan: \(alignment.reason)
        Their explanation: "\(Self.clip(explanation, 400))"

        Return {"satisfactory": true or false, "feedback": "max 20 words, kind and direct", \
        "suggestion": "max 15 words: how to get back on track, or how to adjust the goals"}
        """
        let raw = try await ask(system: system, user: user, json: true)
        guard let json = extractJSON(raw), let ok = json["satisfactory"] as? Bool else { throw CoachError.badResponse }
        let feedback = (json["feedback"] as? String) ?? (ok ? "Makes sense." : "That sounds avoidable.")
        let suggestion = json["suggestion"] as? String
        store.update(entry.id) {
            $0.explanation = explanation
            $0.explanationAccepted = ok
            $0.coachFeedback = feedback
        }
        return Judgement(accepted: ok, feedback: feedback, suggestion: suggestion)
    }

    // MARK: 3. Stuck

    private static let stopwords: Set<String> = [
        "this", "that", "with", "from", "have", "what", "when", "where", "which", "about", "into",
        "there", "their", "them", "then", "than", "just", "like", "will", "would", "could", "should",
        "need", "work", "working", "worked", "some", "more", "also", "been", "being", "were", "your",
        "after", "before", "again", "today", "still", "doing", "done", "make", "made", "dont", "cant",
    ]

    private static func keywords(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopwords.contains($0) })
    }

    /// Past entries and solved "stuck" sessions that share words with the problem.
    func relevantHistory(for problem: String) -> String {
        let words = Self.keywords(problem)
        guard !words.isEmpty else { return "(nothing similar found)" }
        let cutoff = Date().addingTimeInterval(-120 * 86_400)

        let scoredEntries = store.entries
            .filter { $0.periodEnd > cutoff }
            .compactMap { e -> (Entry, Int)? in
                let t = Self.text(of: e)
                guard !t.isEmpty else { return nil }
                let overlap = Self.keywords(t).intersection(words).count
                guard overlap > 0 else { return nil }
                return (e, overlap + (RecapBuilder.keywordSuccess(t) == true ? 1 : 0))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(8)

        let scoredStuck = stuck.sessions
            .filter { $0.resolved && $0.resolution != nil }
            .compactMap { s -> (StuckSession, Int)? in
                let overlap = Self.keywords(s.problem + " " + (s.resolution ?? "")).intersection(words).count
                return overlap > 0 ? (s, overlap) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)

        var lines: [String] = []
        for (e, _) in scoredEntries {
            let date = e.periodStart.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            let tag = RecapBuilder.keywordSuccess(Self.text(of: e)) == true ? " [success]" : ""
            lines.append("- \(date): \(Self.clip(Self.text(of: e), 140))\(tag)")
        }
        for (s, _) in scoredStuck {
            let date = s.date.formatted(.dateTime.day().month(.abbreviated))
            lines.append("- Earlier stuck (\(date)): \(Self.clip(s.problem, 100)) → what worked: \(Self.clip(s.resolution ?? "", 140))")
        }
        return lines.isEmpty ? "(nothing similar found)" : lines.joined(separator: "\n")
    }

    func stuckReply(to session: StuckSession) async throws -> String {
        let key = Keychain.get(Keychain.groqAPIKey)
        guard !key.isEmpty else { throw CoachError.noKey }

        let system = """
        You are a calm, practical problem-solving coach for an experienced engineer and product manager. \
        Be concrete and brief. Use the person's own history when it is relevant and never invent history.

        For the FIRST reply use exactly this shape (plain text, **bold** labels allowed, no other markdown):
        **First, try:** one action that takes 15 minutes or less.
        **Break it down:**
        1. ...
        2. ... (3 to 5 short steps)
        **From your history:** 1-2 relevant past entries or solutions with their dates, or "Nothing similar yet."
        **One question:** the single question whose answer would most unblock this.

        For follow-up replies: answer in at most 6 short lines, same tone.

        Context:
        \(goalsContext())

        Relevant history from the person's own log:
        \(relevantHistory(for: session.problem + " " + session.messages.filter { $0.role == "user" }.map(\.text).joined(separator: " ")))
        """
        var messages: [[String: String]] = [["role": "system", "content": system]]
        for m in session.messages {
            messages.append(["role": m.role == "assistant" ? "assistant" : "user", "content": m.text])
        }
        return try await Groq.chat(apiKey: key, model: settings.groqModel, messages: messages)
    }

    // MARK: 4. Patterns over recent days

    func analyzePatterns(days: Int = 14) async throws -> PatternReport {
        let cal = Calendar.current
        var dayBlocks: [String] = []
        var total = 0
        for offset in (0..<days).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let entries = store.entries(on: day)
                .filter { $0.status != .missed && $0.status != .skipped }
                .sorted { $0.periodStart < $1.periodStart }
            let u = usage.usage(for: day)
            guard !entries.isEmpty || u.activeSeconds > 600 else { continue }

            var block = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let g = goals.goals(on: day)
            if !g.isEmpty { block += " | goals: " + g.map { "\($0.text)\($0.done ? " ✓" : "")" }.joined(separator: "; ") }
            if u.activeSeconds > 0 {
                block += " | active \(durationText(u.activeSeconds))"
                let sites = u.top(u.sites, 3).map { "\($0.name) \(durationText($0.seconds))" }.joined(separator: ", ")
                if !sites.isEmpty { block += " | top sites: \(sites)" }
            }
            for e in entries where total < 160 {
                total += 1
                let time = e.periodStart.formatted(.dateTime.hour().minute())
                var flags: [String] = []
                if e.goalAligned == true { flags.append("on-plan") }
                if e.goalAligned == false { flags.append("off-plan" + (e.explanation.map { ": \(Self.clip($0, 60))" } ?? "")) }
                if RecapBuilder.keywordSuccess(Self.text(of: e)) == true { flags.append("success") }
                block += "\n  \(time) \(Self.clip(Self.text(of: e), 90))\(flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]")"
            }
            dayBlocks.append(block)
        }
        guard !dayBlocks.isEmpty else {
            return PatternReport(patterns: [InsightItem(title: "Not enough data yet",
                                                        detail: "Log a few days of check-ins, then analyze again.")],
                                 suggestions: [], bestTime: nil)
        }

        let system = "You analyze a person's work log to find useful, specific patterns. Output only valid JSON."
        let user = """
        \(goalsContext())

        Last \(days) days (check-in time, what was done, flags):
        \(dayBlocks.joined(separator: "\n\n"))

        Find patterns in: when they do their best (successful, on-plan) work, what pulls them off-plan, \
        how big tasks get split or stall, time sinks (sites/apps), and progress on monthly goals.
        Be specific and refer to what is in the log. Never invent facts.
        Return {"patterns": [{"title": "max 6 words", "detail": "max 25 words"}],
                "suggestions": [{"title": "max 6 words", "detail": "max 25 words, a concrete change to try"}],
                "best_time": "max 15 words, e.g. when deep work goes best"}
        Give 3-5 patterns and 3 suggestions.
        """
        let raw = try await ask(system: system, user: user, json: true)
        guard let json = extractJSON(raw) else { throw CoachError.badResponse }
        func items(_ key: String) -> [InsightItem] {
            (json[key] as? [[String: Any]] ?? []).compactMap {
                guard let t = $0["title"] as? String, let d = $0["detail"] as? String else { return nil }
                return InsightItem(title: t, detail: d)
            }
        }
        return PatternReport(patterns: items("patterns"), suggestions: items("suggestions"),
                             bestTime: json["best_time"] as? String)
    }

    // MARK: 5. Break a problem or goal into steps

    func breakdown(_ problem: String) async throws -> [BreakdownStep] {
        let system = "You break work into small, concrete, ordered steps. Output only valid JSON."
        let user = """
        \(goalsContext())

        Relevant history:
        \(relevantHistory(for: problem))

        Break this down: "\(Self.clip(problem, 500))"
        Rules: 3-7 steps, each max 12 words starting with a verb; the first step must take 15 minutes or less; \
        give realistic minute estimates.
        Return {"steps": [{"step": "...", "minutes": 15}]}
        """
        let raw = try await ask(system: system, user: user, json: true)
        guard let json = extractJSON(raw), let steps = json["steps"] as? [[String: Any]] else {
            throw CoachError.badResponse
        }
        let result = steps.compactMap { s -> BreakdownStep? in
            guard let t = s["step"] as? String, !t.isEmpty else { return nil }
            return BreakdownStep(text: t, minutes: (s["minutes"] as? NSNumber)?.intValue)
        }
        if result.isEmpty { throw CoachError.badResponse }
        return result
    }
}
