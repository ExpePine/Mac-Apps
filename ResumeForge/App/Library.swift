import AppKit
import Foundation

// MARK: - Auto-classification (free, on your Mac; the AI fit check refines it)

enum JobClassifier {
    static let dimensions = ["Role", "Domain", "Seniority", "Work mode"]

    private static let roles: [(String, String)] = [
        ("Product Management", #"\bproduct (manager|owner|lead|head|management)|\bapm\b|\bcpo\b|head of product"#),
        ("Program/Project Management", #"\b(program|project|delivery|pmo)\b.*\b(manager|lead|head)|\bscrum master\b"#),
        ("Hardware/Embedded", #"\b(embedded|firmware|hardware|electronics|pcb|rtos|fpga|asic|iot device)\b"#),
        ("AI/ML", #"\b(machine learning|ml engineer|data scien|computer vision|\bai\b|llm|deep learning|edge ai)"#),
        ("Engineering", #"\b(software|engineer|developer|sde|full stack|backend|frontend|devops)\b"#),
        ("Operations", #"\b(operations|supply chain|manufactur|production|quality|npi)\b"#),
        ("Sales/BD", #"\b(sales|business development|account manager|pre-?sales)\b"#),
    ]
    private static let domains: [(String, String)] = [
        ("Biometrics/Security", #"biometric|fingerprint|face recognition|identity|surveillance|security camera"#),
        ("IoT/Devices", #"\biot\b|connected device|wearable|sensor|smart home|consumer electronics"#),
        ("Fintech", #"fintech|payment|bank|lending|nbfc|insurance|wealth"#),
        ("Healthcare", #"health|medical|pharma|hospital|clinical|med ?tech"#),
        ("Automotive/EV", #"automotive|\bev\b|electric vehicle|mobility|car"#),
        ("SaaS/Enterprise", #"\bsaas\b|b2b|enterprise software|crm|erp"#),
        ("E-commerce/Consumer", #"e-?commerce|retail|d2c|consumer|marketplace"#),
        ("Semiconductors", #"semiconductor|silicon|chip design|vlsi"#),
    ]

    static func tags(title: String, text: String, location: String) -> [String] {
        let t = title.lowercased(), all = (title + " " + text.prefix(3000)).lowercased()
        let role = roles.first { t.range(of: $0.1, options: .regularExpression) != nil }?.0
            ?? roles.first { all.range(of: $0.1, options: .regularExpression) != nil }?.0 ?? "Other"
        let domain = domains.first { all.range(of: $0.1, options: .regularExpression) != nil }?.0 ?? "General"
        let seniority: String = {
            if t.range(of: #"\b(vp|vice president|chief|cxo|cto|cpo)\b"#, options: .regularExpression) != nil { return "VP+" }
            if t.range(of: #"\b(head|director|gm|general manager|agm)\b"#, options: .regularExpression) != nil { return "Head/Director" }
            if t.range(of: #"\b(lead|principal|staff|senior manager)\b"#, options: .regularExpression) != nil { return "Lead" }
            if t.range(of: #"\b(senior|sr\.?)\b"#, options: .regularExpression) != nil { return "Senior" }
            if t.range(of: #"\b(associate|junior|jr\.?|intern|trainee|graduate)\b"#, options: .regularExpression) != nil { return "Junior" }
            return "Mid"
        }()
        let l = (location + " " + text.prefix(2000)).lowercased()
        let mode = l.contains("remote") ? "Remote" : l.contains("hybrid") ? "Hybrid" : (location.isEmpty ? "Unknown" : "Onsite")
        return [role, domain, seniority, mode]
    }
}

extension FeedJob {
    /// AI tags when the fit check has run, otherwise the on-device classification.
    var classTags: [String] {
        if let t = tags, t.count == 4 { return t }
        return JobClassifier.tags(title: title, text: description, location: location)
    }
}

extension JobPosting {
    var classTags: [String] { tags ?? JobClassifier.tags(title: title, text: description, location: location) }
}

// MARK: - Lines (a bank of good sentences)

/// A sentence worth keeping: a resume bullet, a one-liner, a summary line or an opener.
struct LineItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text = ""
    var kind = "bullet"              // bullet | oneLiner | summary | opener
    var tags: [String] = []
    var storyIDs: [String] = []
    var jobID: UUID?
    var feedID: String?
    var context = ""                 // e.g. "From story: …" or "For: Senior PM at JLL"
    var starred = false
    var createdAt = Date()
}

enum LineKind: String, CaseIterable, Identifiable {
    case bullet, oneLiner, summary, opener
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bullet: return "Resume bullet"
        case .oneLiner: return "One-liner"
        case .summary: return "Summary line"
        case .opener: return "Opener / pitch"
        }
    }
}

extension Prompts {
    static func compressStories(_ stories: String) -> String {
        """
        TASK: Compress each of the candidate's stories into short, strong lines they can reuse.

        For EACH story return:
        - 2 resume bullets ("bullet"): one sentence, 18–30 words, strong past-tense verb + what they did + scale + result.
        - 1 one-liner ("oneLiner"): max 15 words, the headline of the achievement.
        - 1 opener ("opener"): max 25 words, how they'd say it in an intro message or interview ("I led…").

        Return: {"lines": [{"story": "<id in brackets>", "kind": "bullet|oneLiner|opener", "text": "", "tags": ["2–3 skill/domain tags"]}]}

        RULES: Use only facts in the story — never invent numbers, names or outcomes. Keep their numbers exactly. \
        Indian English. No clichés.

        STORIES:
        \(stories)
        """
    }

    static func linesForJD(title: String, company: String, jd: String, stories: String, profile: String) -> String {
        """
        TASK: The candidate is reacting to this job. Write lines they can reuse in the resume, cover note and outreach \
        for THIS job, using only their real stories.

        Return: {"lines": [{"kind": "bullet|summary|opener|oneLiner", "text": "", "story": "<id in brackets or ''>", "tags": ["2–3 tags"]}]}

        Write: 4 resume bullets that mirror this JD's top requirements (18–30 words each), 1 summary line for the top of \
        the resume (max 40 words), 2 openers for a message to the hiring manager (max 30 words each).

        RULES: Every claim must come from the stories/profile. Mirror the JD's vocabulary only where it honestly describes \
        the same thing. Never invent numbers, tools or outcomes.

        JOB: \(title) at \(company)
        \(clip(jd, 3500))

        CANDIDATE PROFILE:
        \(profile)

        CANDIDATE STORIES:
        \(stories)
        """
    }
}

extension AppStore {
    var lines: [LineItem] { data.lines ?? [] }

    func addLines(_ new: [LineItem]) {
        var list = data.lines ?? []
        let have = Set(list.map { Self.norm($0.text) })
        list.insert(contentsOf: new.filter { !have.contains(Self.norm($0.text)) }, at: 0)
        data.lines = list
    }

    /// Turns stories into reusable lines, several stories per AI request.
    func compressStories(_ ids: [UUID]? = nil) async throws -> Int {
        let pool = ids.map { set in data.stories.filter { set.contains($0.id) } } ?? data.stories
        guard !pool.isEmpty else { throw GroqError(message: "Add some stories first.") }
        var made = 0
        var i = 0
        while i < pool.count {
            let chunk = Array(pool[i..<min(pool.count, i + 6)])
            i += 6
            linesStatus = "Compressing stories \(min(i, pool.count))/\(pool.count)…"
            let block = chunk.map { "[\(Prompts.shortID($0))] \($0.title) | \($0.company) | \($0.period)\n\(Prompts.clip($0.text, 1800))\($0.metrics.isEmpty ? "" : "\nMetrics: " + $0.metrics.joined(separator: "; "))" }
                .joined(separator: "\n\n")
            let o = try await ask(output: 1600, temperature: 0.4) { _ in Prompts.compressStories(block) }
            let new: [LineItem] = J.dicts(o, "lines").compactMap { d in
                let t = J.str(d, "text"); guard !t.isEmpty else { return nil }
                var l = LineItem()
                l.text = t
                l.kind = LineKind(rawValue: J.str(d, "kind")) != nil ? J.str(d, "kind") : "bullet"
                l.tags = J.strings(d, "tags")
                l.storyIDs = resolveStoryIDs([J.str(d, "story")])
                if let sid = l.storyIDs.first, let st = data.stories.first(where: { $0.id.uuidString == sid }) { l.context = "From story: \(st.title)" }
                return l
            }
            addLines(new)
            made += new.count
        }
        linesStatus = nil
        return made
    }

    /// Lines written in reaction to a JD (from a feed item or a job).
    func linesFor(title: String, company: String, jd: String, jobID: UUID?, feedID: String?) async throws -> Int {
        linesStatus = "Writing lines for \(title)…"
        defer { linesStatus = nil }
        let profile = data.profile, stories = data.stories
        let o = try await ask(output: 1400, temperature: 0.5) { budget in
            Prompts.linesForJD(title: title, company: company, jd: jd,
                               stories: Prompts.storiesBlock(stories, relevantTo: title + " " + jd, maxChars: min(8000, max(2000, budget / 3))),
                               profile: Prompts.profileBlock(profile, maxChars: 1200))
        }
        let new: [LineItem] = J.dicts(o, "lines").compactMap { d in
            let t = J.str(d, "text"); guard !t.isEmpty else { return nil }
            var l = LineItem()
            l.text = t
            l.kind = LineKind(rawValue: J.str(d, "kind")) != nil ? J.str(d, "kind") : "bullet"
            l.tags = J.strings(d, "tags")
            l.storyIDs = resolveStoryIDs([J.str(d, "story")])
            l.jobID = jobID
            l.feedID = feedID
            l.context = "For: \(title)\(company.isEmpty ? "" : " at \(company)")"
            return l
        }
        addLines(new)
        return new.count
    }

    /// Starred lines, offered to the resume writer as preferred phrasing.
    var approvedLinesBlock: String {
        let s = lines.filter(\.starred).prefix(20).map { "- \($0.text)" }
        return s.isEmpty ? "" : s.joined(separator: "\n")
    }

    // MARK: Liked JDs

    func toggleLike(feedID: String) {
        guard let i = feedIndex(feedID) else { return }
        let on = !(feed[i].liked ?? false)
        data.feed?[i].liked = on
        if let jid = feed[i].jobID, let k = jobIndex(jid) { data.jobs[k].liked = on }
    }

    func toggleLike(jobID: UUID) {
        guard let k = jobIndex(jobID) else { return }
        let on = !(data.jobs[k].liked ?? false)
        data.jobs[k].liked = on
        if let fid = data.jobs[k].feedKey, let i = feedIndex(fid) { data.feed?[i].liked = on }
    }
}
