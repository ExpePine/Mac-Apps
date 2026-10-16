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
            return BreakdownStep(text: t, minutes: (s["minutes"] as? NSNumber)?.intValue, why: s["why"] as? String)
        }
    }

    /// First breakdown of a goal into a chain of steps.
    func suggestPlanSteps(goal: String, existing: [String], plans: PlanStore) async throws -> [BreakdownStep] {
        let system = "You turn goals into a short chain of concrete, ordered steps. Output only valid JSON."
        let user = """
        \(goalsContext())

        What happened in my past plans (use it: avoid steps that stalled before, add steps that fixed past blockers):
        \(plans.lessonsContext())

        Relevant history from my log:
        \(relevantHistory(for: goal))

        Goal: "\(goal)"
        \(existing.isEmpty ? "" : "Steps I already have (don't repeat them): \(existing.joined(separator: "; "))")

        Rules: 5-8 steps in order; each max 12 words starting with a verb; the first step takes 15 minutes or less; \
        include a step to verify the result; realistic minute estimates; "why" max 10 words.
        Return {"steps": [{"step": "...", "minutes": 20, "why": "..."}]}
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
