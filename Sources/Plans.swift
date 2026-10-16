import Foundation

// MARK: - Model

struct PlanStep: Identifiable, Codable, Equatable {
    enum Status: String, Codable { case todo, doing, done, blocked, skipped }
    enum Source: String, Codable { case ai, user, mitigation }

    var id = UUID()
    var text: String
    var minutes: Int?
    var why: String?
    var source: Source
    var status: Status = .todo
    var startedAt: Date?
    var finishedAt: Date?
    var note: String?
    var area: String? = nil
    var minutesLow: Int? = nil
    var minutesHigh: Int? = nil
    var crux: Bool? = nil

    /// Midpoint estimate in minutes.
    var estimate: Int? {
        if let l = minutesLow, let h = minutesHigh { return (l + h) / 2 }
        return minutes
    }

    var rangeText: String? {
        if let l = minutesLow, let h = minutesHigh, h > l { return "\(l)–\(h)m" }
        return estimate.map { "~\($0)m" }
    }

    /// Actual minutes, once the step has been finished.
    var actualMinutes: Double? {
        guard let s = startedAt, let f = finishedAt, status == .done else { return nil }
        return f.timeIntervalSince(s) / 60
    }
}

/// Where the coach thinks the real problem is, before any steps are made.
struct ProblemFraming: Codable, Equatable {
    struct Area: Codable, Equatable, Identifiable {
        var id: String { name }
        var name: String
        var share: Int              // % of total effort
        var uncertainty: String     // low / medium / high
        var why: String?
    }
    var heart = ""
    var whyHeart: String?
    var instinct = ""               // what the user will probably want to do first
    var instinctVerdict = ""        // good / risky / premature
    var instinctReason: String?
    var areas: [Area] = []
    var focus = ""
    var assumptions: [String] = []

    // The user's reaction
    var heartConfirmed: Bool?
    var heartCorrection: String?
    var instinctConfirmed: Bool?
    var userInstinct: String?

    var asText: String {
        var t = "Heart of the problem: \(heartCorrection?.isEmpty == false ? heartCorrection! : heart)"
        if let u = userInstinct, !u.isEmpty { t += "\nMy instinct: \(u)" }
        else if instinctConfirmed == true { t += "\nMy instinct: \(instinct)" }
        if !areas.isEmpty {
            t += "\nWork areas: " + areas.map { "\($0.name) \($0.share)% (\($0.uncertainty) uncertainty)" }.joined(separator: ", ")
        }
        if !focus.isEmpty { t += "\nFocus first: \(focus)" }
        if !assumptions.isEmpty { t += "\nAssumptions to test: " + assumptions.joined(separator: "; ") }
        return t
    }
}

struct PlanEvent: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case created, started, stepStarted, stepDone, stepSkipped, stepAdded, blocked, mitigated, resumed, completed, stopped, reopened
    }
    var id = UUID()
    var date = Date()
    var kind: Kind
    var stepID: UUID?
    var text: String
}

/// A moment where the flow broke, why, and what was done about it.
struct Blocker: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var stepID: UUID
    var stepText: String
    var category: String?
    var reason: String
    var diagnosis: String?
    var addedStepIDs: [UUID] = []
    var resolved = false
}

struct Plan: Identifiable, Codable, Equatable {
    enum Status: String, Codable { case drafting, active, completed, abandoned }

    var id = UUID()
    var goal: String
    var createdAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var status: Status = .drafting
    var steps: [PlanStep] = []
    var events: [PlanEvent] = []
    var blockers: [Blocker] = []
    var outcomeNote: String?      // why it worked / why it couldn't be completed
    var details: String?          // the user's own description of the goal
    var clarifications: [Clarification]? = nil
    var brief: GoalBrief?
    var framing: ProblemFraming?
    var budgetMinutes: Int?           // time available today for this plan
    var declined: [String]?           // suggested steps the user left out
    var lesson: String?           // one-line AI lesson

    /// The step being worked on, or the next one to do.
    var currentIndex: Int? {
        steps.firstIndex { $0.status == .doing || $0.status == .blocked }
            ?? steps.firstIndex { $0.status == .todo }
    }

    var doneCount: Int { steps.filter { $0.status == .done }.count }

    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(steps.filter { $0.status == .done || $0.status == .skipped }.count) / Double(steps.count)
    }

    var lastActivity: Date { events.last?.date ?? createdAt }

    mutating func log(_ kind: PlanEvent.Kind, _ text: String, step: UUID? = nil) {
        events.append(PlanEvent(kind: kind, stepID: step, text: text))
    }
}

/// One clarifying question from the coach, and the user's answer.
struct Clarification: Identifiable, Codable, Equatable {
    var id = UUID()
    var question: String
    var why: String?
    var options: [String] = []
    var answer = ""
    var answered = false
    var round = 1
}

/// The agreed description of the goal, written from the interview.
struct GoalBrief: Codable, Equatable {
    var summary = ""
    var outcome = ""
    var doneWhen = ""
    var scope = ""
    var constraints = ""
    var context = ""

    var asText: String {
        [("Summary", summary), ("Outcome", outcome), ("Done when", doneWhen),
         ("Scope", scope), ("Constraints", constraints), ("Context", context)]
            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
    }
}

struct Mitigation {
    let diagnosis: String
    let advice: String?
    let steps: [BreakdownStep]
}

// MARK: - Storage

@MainActor
final class PlanStore: ObservableObject {
    @Published private(set) var plans: [Plan] = []
    private let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("plans.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let list = try? decoder.decode([Plan].self, from: data) {
            plans = list
        }
    }

    func plan(_ id: UUID) -> Plan? { plans.first { $0.id == id } }

    func upsert(_ plan: Plan) {
        if let i = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[i] = plan
        } else {
            plans.insert(plan, at: 0)
        }
        save()
    }

    func update(_ id: UUID, _ change: (inout Plan) -> Void) {
        guard var p = plan(id) else { return }
        change(&p)
        upsert(p)
    }

    func delete(_ id: UUID) {
        plans.removeAll { $0.id == id }
        save()
    }

    var activePlan: Plan? {
        plans.filter { $0.status == .active }.max { $0.lastActivity < $1.lastActivity }
    }

    var finished: [Plan] {
        plans.filter { $0.status == .completed || $0.status == .abandoned }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }

    /// Most common reasons the flow broke, across all plans.
    var blockerStats: [(category: String, count: Int)] {
        var counts: [String: Int] = [:]
        for p in plans { for b in p.blockers { counts[b.category ?? "Other", default: 0] += 1 } }
        return counts.sorted { $0.value > $1.value }.map { (category: $0.key, count: $0.value) }
    }

    /// How long you really take vs your estimates, from finished steps (needs 3+).
    var paceFactor: (factor: Double, samples: Int)? {
        var actual = 0.0, estimated = 0.0, n = 0
        for p in plans {
            for s in p.steps {
                guard let a = s.actualMinutes, let e = s.estimate, e > 0, a > 0.5 else { continue }
                actual += a; estimated += Double(e); n += 1
            }
        }
        guard n >= 3, estimated > 0 else { return nil }
        return (min(3, max(0.5, actual / estimated)), n)
    }

    /// What the user tends to do, for the coach to "read their instinct".
    func habitsContext() -> String {
        var lines: [String] = []
        let added = plans.flatMap { $0.steps.filter { $0.source == .user && $0.status != .skipped }.map(\.text) }.suffix(10)
        if !added.isEmpty { lines.append("Steps I tend to add myself: " + added.joined(separator: "; ")) }
        let declined = plans.flatMap { $0.declined ?? [] }.suffix(10)
        if !declined.isEmpty { lines.append("Suggestions I usually leave out: " + declined.joined(separator: "; ")) }
        let firsts = plans.compactMap { p in p.steps.first(where: { $0.status == .done || $0.status == .doing })?.text }.suffix(6)
        if !firsts.isEmpty { lines.append("What I actually started with in past plans: " + firsts.joined(separator: "; ")) }
        let instincts = plans.compactMap { $0.framing?.userInstinct }.filter { !$0.isEmpty }.suffix(5)
        if !instincts.isEmpty { lines.append("My stated instincts before: " + instincts.joined(separator: "; ")) }
        if let top = blockerStats.first { lines.append("My most common flow break: \(top.category) (\(top.count)×)") }
        if let pace = paceFactor {
            lines.append(String(format: "I usually take %.1f× my time estimates (from %d steps)", pace.factor, pace.samples))
        }
        return lines.isEmpty ? "(no habits recorded yet)" : lines.joined(separator: "\n")
    }

    /// Past outcomes and flow breaks, for AI prompts.
    func lessonsContext() -> String {
        var lines: [String] = []
        for p in finished.prefix(8) {
            let outcome = p.status == .completed ? "completed" : "stopped"
            var line = "- [\(outcome)] \(p.goal): \(p.doneCount)/\(p.steps.count) steps"
            if let n = p.outcomeNote, !n.isEmpty { line += "; why: \(n)" }
            if let l = p.lesson, !l.isEmpty { line += "; lesson: \(l)" }
            lines.append(line)
        }
        let recentBlockers = plans.flatMap(\.blockers).sorted { $0.date > $1.date }.prefix(12)
        for b in recentBlockers {
            lines.append("- flow broke on \"\(b.stepText)\": \(b.category.map { "[\($0)] " } ?? "")\(b.reason)\(b.resolved ? " → fixed with new steps" : "")")
        }
        return lines.isEmpty ? "(no past plans yet)" : lines.joined(separator: "\n")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(plans) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Coach: suggest, mitigate, learn

extension CoachService {
    private static func steps(from json: [String: Any]) -> [BreakdownStep] {
        (json["steps"] as? [[String: Any]] ?? []).compactMap { s in
            guard let t = s["step"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let low = (s["minutes_low"] as? NSNumber)?.intValue
            let high = (s["minutes_high"] as? NSNumber)?.intValue
            let mid = (low != nil && high != nil) ? (low! + high!) / 2 : (s["minutes"] as? NSNumber)?.intValue
            return BreakdownStep(text: t, minutes: mid, why: s["why"] as? String, area: s["area"] as? String,
                                 minutesLow: low, minutesHigh: high, crux: s["crux"] as? Bool ?? false)
        }
    }

    private static func qaText(_ qa: [Clarification]) -> String {
        qa.filter { $0.answered && !$0.answer.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "Q: \($0.question)\nA: \($0.answer)" }
            .joined(separator: "\n")
    }

    /// Interview: the few questions that would most change the plan.
    /// Returns ready = true when there is enough to write a brief.
    func clarifyingQuestions(goal: String, details: String, answered: [Clarification], round: Int,
                             plans: PlanStore) async throws -> (ready: Bool, questions: [Clarification]) {
        let system = """
        You are a sharp, friendly product coach for an experienced engineer and product manager. \
        Before planning, you ask only the questions whose answers would most change the plan: \
        what exactly is being built or achieved, for whom, what "done" looks like, what already exists, \
        constraints (time, tools, data, people) and the biggest unknown. Never ask what was already answered. \
        Output only valid JSON.
        """
        let roundInstruction = round == 1
            ? "Ask 3 to 5 questions."
            : "Ask at most 2 follow-up questions, only if an important gap remains; otherwise set ready to true."
        let user = """
        \(goalsContext())

        Goal title: "\(goal)"
        My description: \(details.isEmpty ? "(none yet)" : details)

        Answers so far:
        \(answered.isEmpty ? "(none)" : Self.qaText(answered))

        Relevant history from my log:
        \(relevantHistory(for: goal + " " + details))

        This is question round \(round). \(roundInstruction)
        Each question max 20 words; "why" max 10 words; 0-4 short answer options (max 5 words each) when likely answers are guessable.
        Return {"ready": false, "questions": [{"question": "...", "why": "...", "options": ["...", "..."]}]}
        """
        let raw = try await ask(system: system, user: user, json: true)
        guard let json = extractJSON(raw) else { throw CoachError.badResponse }
        let questions = (json["questions"] as? [[String: Any]] ?? []).compactMap { q -> Clarification? in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            return Clarification(question: text, why: q["why"] as? String,
                                 options: (q["options"] as? [String] ?? []).filter { !$0.isEmpty }, round: round)
        }
        let ready = (json["ready"] as? Bool ?? false) || questions.isEmpty
        return (ready, questions)
    }

    /// Finds the heart of the problem, reads the user's instinct, and maps where the effort is.
    func frameProblem(goal: String, details: String, answered: [Clarification], previous: ProblemFraming?,
                      plans: PlanStore) async throws -> ProblemFraming {
        let system = """
        You are an expert problem-solver coaching an experienced engineer and product manager. \
        Do NOT plan yet. First find the heart of the problem: the single hardest or most uncertain part \
        that decides whether this goal succeeds — not the most visible part. \
        Then read the person: predict the instinctive first move they will want to make, judging from how \
        they describe the goal and from their habits, and judge that instinct honestly (good / risky / premature). \
        Estimate where the bulk of the effort and the uncertainty really sit. Be specific to this goal, never generic. \
        Output only valid JSON.
        """
        var corrections = ""
        if let p = previous {
            if p.heartConfirmed == false, let c = p.heartCorrection, !c.isEmpty {
                corrections += "I disagree with your earlier 'heart': \"\(p.heart)\". It's actually: \(c)\n"
            }
            if p.instinctConfirmed == false, let u = p.userInstinct, !u.isEmpty {
                corrections += "You guessed my instinct as \"\(p.instinct)\" — my real instinct is: \(u)\n"
            }
        }
        let user = """
        \(goalsContext())

        Goal: "\(goal)"
        Description: \(details.isEmpty ? "(none)" : details)
        Interview:
        \(answered.isEmpty ? "(none)" : Self.qaText(answered))

        My habits:
        \(plans.habitsContext())

        Past plans and blockers:
        \(plans.lessonsContext())

        Relevant history:
        \(relevantHistory(for: goal + " " + details))
        \(corrections.isEmpty ? "" : "\nMy corrections (respect them):\n" + corrections)
        Return {"heart": "max 30 words: the crux that decides success",
                "why_heart": "max 20 words",
                "instinct": "max 20 words: the first thing I'll probably want to do",
                "instinct_verdict": "good" or "risky" or "premature",
                "instinct_reason": "max 20 words",
                "areas": [{"name": "max 4 words", "share": 40, "uncertainty": "low|medium|high", "why": "max 12 words"}],
                "focus": "max 20 words: what to attack first and why",
                "assumptions": ["max 15 words each, 2-3 risky assumptions to test early"]}
        Areas: 2-5, shares add up to 100.
        """
        let raw = try await ask(system: system, user: user, json: true)
        guard let json = extractJSON(raw), let heart = json["heart"] as? String, !heart.isEmpty else {
            throw CoachError.badResponse
        }
        let areas = (json["areas"] as? [[String: Any]] ?? []).compactMap { a -> ProblemFraming.Area? in
            guard let name = a["name"] as? String else { return nil }
            return .init(name: name, share: (a["share"] as? NSNumber)?.intValue ?? 0,
                         uncertainty: (a["uncertainty"] as? String ?? "medium").lowercased(), why: a["why"] as? String)
        }
        var f = ProblemFraming()
        f.heart = heart
        f.whyHeart = json["why_heart"] as? String
        f.instinct = json["instinct"] as? String ?? ""
        f.instinctVerdict = (json["instinct_verdict"] as? String ?? "").lowercased()
        f.instinctReason = json["instinct_reason"] as? String
        f.areas = areas
        f.focus = json["focus"] as? String ?? ""
        f.assumptions = (json["assumptions"] as? [String] ?? []).filter { !$0.isEmpty }
        return f
    }

    /// Writes the goal brief from the title, description and answers.
    func writeBrief(goal: String, details: String, answered: [Clarification],
                    framing: ProblemFraming? = nil) async throws -> GoalBrief {
        let user = """
        Goal title: "\(goal)"
        Description: \(details.isEmpty ? "(none)" : details)
        Interview:
        \(answered.isEmpty ? "(none)" : Self.qaText(answered))
        \(framing.map { "Agreed framing:\n\($0.asText)" } ?? "")

        Write a crisp goal brief using only what is stated above; where something is unknown, say "Unclear: ..." briefly.
        Return {"summary": "max 25 words, what this goal is",
                "outcome": "max 20 words, the concrete result",
                "done_when": "max 25 words, a checkable finish line",
                "scope": "max 25 words, what is in and out",
                "constraints": "max 25 words: time, tools, data, people",
                "context": "max 30 words: key facts from the answers"}
        """
        let raw = try await ask(system: "You write precise, plain goal briefs. Output only valid JSON.", user: user, json: true)
        guard let json = extractJSON(raw) else { throw CoachError.badResponse }
        func v(_ k: String) -> String { (json[k] as? String) ?? "" }
        let brief = GoalBrief(summary: v("summary"), outcome: v("outcome"), doneWhen: v("done_when"),
                              scope: v("scope"), constraints: v("constraints"), context: v("context"))
        if brief.asText.isEmpty { throw CoachError.badResponse }
        return brief
    }

    /// First breakdown of a goal into a chain of steps.
    func suggestPlanSteps(goal: String, brief: GoalBrief? = nil, framing: ProblemFraming? = nil, details: String = "",
                          answered: [Clarification] = [], existing: [String],
                          plans: PlanStore) async throws -> [BreakdownStep] {
        let system = "You turn goals into a short chain of concrete, ordered steps. Output only valid JSON."
        let user = """
        \(goalsContext())

        What happened in my past plans (use it: avoid steps that stalled before, add steps that fixed past blockers):
        \(plans.lessonsContext())

        Relevant history from my log:
        \(relevantHistory(for: goal))

        Goal: "\(goal)"
        \(brief.map { "Goal brief (agreed with me — plan exactly this):\n\($0.asText)" } ?? "")
        \(details.isEmpty ? "" : "My description: \(details)")
        \(answered.isEmpty ? "" : "My answers:\n\(Self.qaText(answered))")
        \(existing.isEmpty ? "" : "Steps I already have (don't repeat them): \(existing.joined(separator: "; "))")
        \(framing.map { "Agreed framing (plan around the heart of the problem):\n\($0.asText)" } ?? "")
        My habits:
        \(plans.habitsContext())
        Make the steps specific to this goal (names, data, tools from the brief), not generic project steps.
        Attack the heart of the problem early: the first step (15 min or less) should touch it, and steps that \
        reduce the biggest uncertainty come before polishing work. Mark steps on the heart of the problem as crux. \
        Each step belongs to one of the work areas. Give an honest time range (low-high minutes).

        Rules: 5-9 steps in order; each max 12 words starting with a verb; include a step to verify the result; \
        "why" max 10 words.
        Return {"steps": [{"step": "...", "area": "one of the work areas", "minutes_low": 20, "minutes_high": 40, \
        "crux": true, "why": "..."}]}
        """
        let raw = try await ask(system: system, user: user, json: true)
        guard let json = extractJSON(raw) else { throw CoachError.badResponse }
        let result = Self.steps(from: json)
        if result.isEmpty { throw CoachError.badResponse }
        return result
    }

    /// The flow broke on a step: diagnose and propose steps to get moving again.
    func mitigation(plan: Plan, stepIndex: Int, category: String?, reason: String, extra: String,
                    plans: PlanStore) async throws -> Mitigation {
        let chain = plan.steps.enumerated().map { i, s in
            "\(i + 1). [\(s.status.rawValue)] \(s.text)\(s.note.map { " (note: \($0))" } ?? "")"
        }.joined(separator: "\n")
        let earlier = plan.blockers.map { "- \($0.stepText): \($0.reason)" }.joined(separator: "\n")
        let system = """
        You are a calm, practical coach helping someone get unstuck mid-plan. Diagnose the real cause briefly \
        and propose the smallest steps that get the chain moving again. Output only valid JSON.
        """
        let user = """
        Goal: \(plan.goal)
        \(plan.brief.map { "Goal brief:\n\($0.asText)" } ?? "")
        Chain:
        \(chain)

        The flow broke on step \(stepIndex + 1): "\(plan.steps[stepIndex].text)"
        Type: \(category ?? "not given")
        What happened: \(reason)
        \(extra.isEmpty ? "" : "More context: \(extra)")
        \(earlier.isEmpty ? "" : "Earlier breaks in this plan:\n\(earlier)")

        Past plans and blockers:
        \(plans.lessonsContext())

        Relevant history:
        \(relevantHistory(for: plan.steps[stepIndex].text + " " + reason))

        Return {"diagnosis": "max 25 words: the likely real cause",
                "advice": "max 15 words, optional",
                "steps": [{"step": "max 12 words, starts with a verb", "minutes": 15}]}
        Give 2-4 steps to insert before retrying the blocked step. The first must take 15 minutes or less.
        """
        let raw = try await ask(system: system, user: user, json: true)
        guard let json = extractJSON(raw) else { throw CoachError.badResponse }
        let steps = Self.steps(from: json)
        guard !steps.isEmpty else { throw CoachError.badResponse }
        return Mitigation(diagnosis: (json["diagnosis"] as? String) ?? "Let's try a smaller way in.",
                          advice: json["advice"] as? String, steps: steps)
    }

    /// One-line lesson after a plan is completed or stopped.
    func planLesson(_ plan: Plan) async -> String? {
        let chain = plan.steps.map { "[\($0.status.rawValue)] \($0.text)" }.joined(separator: "\n")
        let breaks = plan.blockers.map { "- \($0.stepText): \($0.reason)\($0.resolved ? " (fixed)" : "")" }.joined(separator: "\n")
        let user = """
        Goal: \(plan.goal)
        Outcome: \(plan.status == .completed ? "completed" : "stopped before finishing")
        Their note: \(plan.outcomeNote ?? "(none)")
        Chain:
        \(chain)
        Flow breaks:
        \(breaks.isEmpty ? "(none)" : breaks)

        Write the single most useful lesson for planning similar goals next time.
        Return {"lesson": "max 20 words"}
        """
        guard let raw = try? await ask(system: "You extract practical planning lessons. Output only valid JSON.",
                                       user: user, json: true),
              let json = extractJSON(raw), let lesson = json["lesson"] as? String else { return nil }
        return lesson
    }
}
