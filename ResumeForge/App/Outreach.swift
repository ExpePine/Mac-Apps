import AppKit
import Foundation

// MARK: - Model

enum OutreachKind: String, CaseIterable, Identifiable {
    case note, message, inmail, followUp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .note: return "Connection note"
        case .message: return "Direct message"
        case .inmail: return "InMail"
        case .followUp: return "Follow-up"
        }
    }
}

enum OutreachOutcome: String, CaseIterable, Identifiable {
    case waiting, accepted, replied, meeting, noReply, declined
    var id: String { rawValue }
    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .accepted: return "Accepted"
        case .replied: return "Replied"
        case .meeting: return "Call / meeting"
        case .noReply: return "No response"
        case .declined: return "Declined"
        }
    }
    var resolved: Bool { self != .waiting }
}

/// One message you sent, with what happened after it.
struct SentRecord: Identifiable {
    var id: UUID { msg.id }
    let contactID: UUID
    let name: String
    let headline: String
    let company: String
    let category: String
    let msg: Interaction
    let kind: String
    let outcome: OutreachOutcome
    let automatic: Bool            // outcome worked out by the app (not set by you)
    let replyAt: Date?
    let replyText: String
    let days: Int                  // days since sent

    /// A note "worked" if it was accepted; any other message "worked" if they answered.
    var worked: Bool {
        switch outcome {
        case .replied, .meeting: return true
        case .accepted: return kind == "note"
        default: return false
        }
    }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

struct OutreachPlaybook: Codable, Hashable {
    var working: [String] = []
    var notWorking: [String] = []
    var rules: [String] = []
    var experiments: [String] = []
    var templates: [PlaybookTemplate] = []
    var caution = ""
    var basedOn = 0
    var at = Date()
}

struct PlaybookTemplate: Codable, Hashable {
    var kind = ""
    var purpose = ""
    var text = ""
}

struct DraftReview {
    var score = 0
    var verdict = ""
    var good: [String] = []
    var fix: [String] = []
    var improved = ""
}

struct InsightRow: Identifiable {
    var id: String { label }
    let label: String
    let sent: Int
    let worked: Int
    var rate: Double { sent == 0 ? 0 : Double(worked) / Double(sent) }
}

// MARK: - Engine

extension AppStore {
    static var noReplyDays: Int { let v = UserDefaults.standard.integer(forKey: "outreachNoReplyDays"); return v > 0 ? v : 14 }
    static var followUpDays: Int { let v = UserDefaults.standard.integer(forKey: "outreachFollowUpDays"); return v > 0 ? v : 5 }

    /// Messages you sent count for tracking; notes you typed for yourself ("spoke on call…") don't.
    nonisolated static func isTracked(_ it: Interaction) -> Bool {
        it.fromMe && (it.kind != nil || ["draft", "screenshot", "pasted", "safari"].contains(it.source))
    }

    /// Every message you've sent, with its outcome. Replies are detected from the conversation itself
    /// (a message from them after yours), from the person's status, or from what you set by hand.
    var sentRecords: [SentRecord] {
        var out: [SentRecord] = []
        let now = Date()
        for c in contacts {
            let ordered = c.interactions.enumerated()
                .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
                .map(\.element)
            let mine = ordered.indices.filter { Self.isTracked(ordered[$0]) }
            guard let lastMine = mine.last else { continue }
            for (n, k) in mine.enumerated() {
                let it = ordered[k]
                let kind = it.kind ?? ((n == 0 && it.text.count <= 300) ? "note" : "message")
                // Their first message after this one (and before my next message) is the reply to it.
                var reply: Interaction?
                for later in ordered[(k + 1)...] {
                    if Self.isTracked(later) { break }
                    if !later.fromMe { reply = later; break }
                }
                let laterMessage = mine.dropFirst(n + 1).contains { (ordered[$0].kind ?? "message") != "note" }
                let days = Calendar.current.dateComponents([.day], from: it.date, to: now).day ?? 0
                var oc: OutreachOutcome
                var auto = true
                if let set = it.outcome.flatMap(OutreachOutcome.init(rawValue:)) {
                    oc = set; auto = false
                } else if reply != nil {
                    oc = (k == lastMine && c.status == "meeting") ? .meeting : .replied
                } else if k == lastMine && (c.status == "replied" || c.status == "meeting") {
                    oc = c.status == "meeting" ? .meeting : .replied
                } else if kind == "note" && (Self.statusRank(c.status) >= 3 || laterMessage) {
                    oc = .accepted
                } else if c.status == "ignored" && k == lastMine && days >= 3 {
                    oc = .noReply
                } else {
                    oc = days >= Self.noReplyDays ? .noReply : .waiting
                }
                let replyAt = reply.flatMap { $0.date.timeIntervalSince(it.date) > 60 ? $0.date : nil } ?? it.outcomeAt
                out.append(SentRecord(contactID: c.id, name: c.name, headline: c.headline, company: c.company, category: c.category,
                                      msg: it, kind: kind, outcome: oc, automatic: auto, replyAt: replyAt,
                                      replyText: reply?.text ?? "", days: max(0, days)))
            }
        }
        return out.sorted { $0.msg.date > $1.msg.date }
    }

    // MARK: Logging

    /// Logs a message you sent yourself (typed in LinkedIn, or pasted here).
    @discardableResult
    func logSent(contactID: UUID?, name: String, company: String, headline: String, url: String,
                 kind: String, intent: String?, date: Date, text: String, replyText: String?, replyDate: Date?) -> UUID? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var cid = contactID
        if cid == nil {
            let key = Self.norm(name)
            cid = contacts.first { !key.isEmpty && Self.norm($0.name) == key }?.id
                ?? contacts.first { !url.isEmpty && Self.profileSlug($0.linkedinURL) == Self.profileSlug(url) }?.id
        }
        if cid == nil {
            var c = Contact()
            c.name = name.isEmpty ? "Unknown person" : name
            c.company = company
            c.headline = headline
            c.linkedinURL = url
            c.category = Self.guessCategory(headline)
            c.source = "manual"
            c.status = kind == "note" ? "requested" : "connected"
            if let job = data.jobs.first(where: { !company.isEmpty && Self.norm($0.company) == Self.norm(company) }) { c.jobIDs = [job.id] }
            var list = data.contacts ?? []
            list.insert(c, at: 0)
            data.contacts = list
            cid = c.id
        }
        guard let id = cid, let i = contactIndex(id) else { return nil }
        if !contacts[i].interactions.contains(where: { $0.fromMe && Self.norm($0.text) == Self.norm(t) }) {
            var it = Interaction()
            it.text = t
            it.date = date
            it.source = "manual-sent"
            it.kind = kind
            it.intent = intent
            it.jobID = contacts[i].jobIDs.first
            data.contacts?[i].interactions.append(it)
        }
        if kind == "note", contacts[i].status == "suggested" { data.contacts?[i].status = "requested" }
        if let r = replyText {
            var it = Interaction()
            it.fromMe = false
            it.text = r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(replied)" : r
            it.date = max(replyDate ?? Date(), date.addingTimeInterval(120))
            it.source = "manual"
            data.contacts?[i].interactions.append(it)
            if Self.statusRank(contacts[i].status) < 4 { data.contacts?[i].status = "replied" }
        }
        data.contacts?[i].updatedAt = Date()
        return id
    }

    /// Records that they answered a message (optionally with what they said).
    func addReply(contactID: UUID, to msgID: UUID, text: String, date: Date) {
        guard let i = contactIndex(contactID), let k = contacts[i].interactions.firstIndex(where: { $0.id == msgID }) else { return }
        let sent = contacts[i].interactions[k]
        var it = Interaction()
        it.fromMe = false
        it.text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(replied)" : text
        it.date = max(date, sent.date.addingTimeInterval(120))
        it.source = "manual"
        data.contacts?[i].interactions.append(it)
        data.contacts?[i].interactions[k].outcome = nil      // the reply itself now decides it
        if Self.statusRank(contacts[i].status) < 4 { data.contacts?[i].status = "replied" }
        data.contacts?[i].updatedAt = Date()
    }

    func setOutcome(contactID: UUID, msgID: UUID, _ o: OutreachOutcome?) {
        guard let i = contactIndex(contactID), let k = contacts[i].interactions.firstIndex(where: { $0.id == msgID }) else { return }
        data.contacts?[i].interactions[k].outcome = o?.rawValue
        data.contacts?[i].interactions[k].outcomeAt = o == nil ? nil : Date()
        if let o, [.replied, .meeting].contains(o) {
            let s = o == .meeting ? "meeting" : "replied"
            if Self.statusRank(contacts[i].status) < Self.statusRank(s) { data.contacts?[i].status = s }
        } else if o == .accepted, Self.statusRank(contacts[i].status) < 3 {
            data.contacts?[i].status = "connected"
        }
    }

    func setMessageField(contactID: UUID, msgID: UUID, kind: String? = nil, intent: String?? = nil) {
        guard let i = contactIndex(contactID), let k = contacts[i].interactions.firstIndex(where: { $0.id == msgID }) else { return }
        if let kind { data.contacts?[i].interactions[k].kind = kind }
        if let intent { data.contacts?[i].interactions[k].intent = intent }
    }

    nonisolated static func profileSlug(_ url: String) -> String {
        guard let r = url.range(of: #"linkedin\.com/in/([^/?#]+)"#, options: [.regularExpression, .caseInsensitive]) else { return "" }
        return String(url[r]).lowercased().components(separatedBy: "/in/").last?.removingPercentEncoding ?? ""
    }

    // MARK: From Safari (right-click on LinkedIn)

    /// "Log the message I'm sending" — the selected (or typed) text on a LinkedIn profile, invitation or chat.
    func logSentFromSafari(_ a: ActionPayload) async {
        let text = a.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Nothing to log — select the message text on LinkedIn (or right-click inside the box while it still has your text), then try again."
            return
        }
        outreachStatus = "Logging your LinkedIn message…"
        defer { outreachStatus = nil }
        let slug = Self.profileSlug(a.pageURL)
        var name = "", company = "", headline = "", kind = ""
        let pageName = Self.pageField(a.pageText, "NAME ON PAGE")
        if !slug.isEmpty, let c = contacts.first(where: { Self.profileSlug($0.linkedinURL) == slug }) {
            name = c.name
        } else if ProviderSettings.anyKeyConfigured,
                  let o = try? await ask(output: 300, temperature: 0, build: { _ in Prompts.whoIsThisMessageTo(message: text, page: a.pageText, url: a.pageURL) }) {
            name = J.str(o, "person"); company = J.str(o, "company"); headline = J.str(o, "headline"); kind = J.str(o, "kind")
        }
        if name.isEmpty { name = pageName }
        if kind.isEmpty {
            let dialog = Self.pageField(a.pageText, "DIALOG").lowercased()
            kind = (dialog.contains("invitation") || dialog.contains("add a note")) ? "note"
                : a.pageURL.contains("/messaging") ? "message" : (text.count <= 300 && !slug.isEmpty ? "note" : "message")
        }
        if !["note", "message", "inmail"].contains(kind) { kind = "message" }
        let id = logSent(contactID: nil, name: name, company: company, headline: headline,
                         url: slug.isEmpty ? "" : "https://www.linkedin.com/in/\(slug)/",
                         kind: kind, intent: nil, date: Date(), text: text, replyText: nil, replyDate: nil)
        if let id, let i = contactIndex(id) {
            data.contacts?[i].interactions.indices.filter { Self.norm(data.contacts![i].interactions[$0].text) == Self.norm(text) }
                .forEach { data.contacts?[i].interactions[$0].source = "safari" }
        }
        outreachStatus = "Logged a \(OutreachKind(rawValue: kind)?.label.lowercased() ?? "message") to \(name.isEmpty ? "someone" : name)"
    }

    /// "Log this conversation" — reads the open LinkedIn thread, so replies are picked up automatically.
    func logThreadFromSafari(_ a: ActionPayload) async {
        guard ProviderSettings.anyKeyConfigured else {
            errorMessage = "Reading a conversation needs an AI key (Settings ▸ AI providers)."
            return
        }
        outreachStatus = "Reading the LinkedIn conversation…"
        defer { outreachStatus = nil }
        do {
            let page = Self.pageField(a.pageText, "THREAD").isEmpty ? a.pageText : Self.pageField(a.pageText, "THREAD")
            _ = try await importConversation(image: nil, text: page, source: "safari")
        } catch {
            errorMessage = "Couldn't read that conversation: \(error.localizedDescription)"
        }
    }

    /// Pulls one labelled block ("THREAD:\n…") out of the text the extension sends.
    nonisolated static func pageField(_ text: String, _ label: String) -> String {
        guard let r = text.range(of: label + ":") else { return "" }
        let rest = text[r.upperBound...]
        let end = rest.range(of: #"\n[A-Z][A-Z ]{2,}:"#, options: .regularExpression)?.lowerBound ?? rest.endIndex
        return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Insights

    func insightGroups(_ recs: [SentRecord]) -> [(String, [InsightRow])] {
        let done = recs.filter { $0.outcome.resolved }
        func group(_ title: String, _ key: (SentRecord) -> String?) -> (String, [InsightRow]) {
            var d: [String: (Int, Int)] = [:]
            for r in done { guard let k = key(r) else { continue }; let v = d[k] ?? (0, 0); d[k] = (v.0 + 1, v.1 + (r.worked ? 1 : 0)) }
            return (title, d.map { InsightRow(label: $0.key, sent: $0.value.0, worked: $0.value.1) }
                .sorted { ($0.rate, $0.sent) > ($1.rate, $1.sent) })
        }
        let groups: [(String, [InsightRow])] = [
            group("Type") { OutreachKind(rawValue: $0.kind)?.label ?? $0.kind },
            group("Purpose") { $0.msg.intent.flatMap { ConnectionType(rawValue: $0)?.label } ?? "Not set" },
            group("Who") { ContactCategory(rawValue: $0.category)?.label ?? "Other" },
            group("Angle") { $0.msg.angle },
            group("Length") { r in
                let n = r.msg.text.count
                return n < 120 ? "Under 120 characters" : n <= 200 ? "120–200" : n <= 400 ? "200–400" : "Over 400"
            },
            group("Ends with a question") { $0.msg.text.contains("?") ? "Has a question" : "No question" },
            group("Names their company") { r in
                let co = Self.norm(r.company)
                return co.isEmpty ? nil : (Self.norm(r.msg.text).contains(co.split(separator: " ").first.map(String.init) ?? co) ? "Mentions company" : "Doesn't")
            },
            group("Uses a number") { $0.msg.text.range(of: #"\d"#, options: .regularExpression) != nil ? "Has a number/metric" : "No numbers" },
            group("Mentions the job") { $0.msg.text.range(of: #"\b(role|position|opening|opportunit|applied|vacancy)"#, options: [.regularExpression, .caseInsensitive]) != nil ? "Mentions the role" : "Doesn't" },
            group("Day sent") { $0.msg.date.formatted(.dateTime.weekday(.wide)) },
            group("Tone") { $0.msg.tone },
        ]
        return groups.filter { $0.1.count > 1 }
    }

    /// Plain-text summary of the numbers, for the coach.
    func insightSummary(_ recs: [SentRecord]) -> String {
        insightGroups(recs).map { title, rows in
            title + ": " + rows.map { "\($0.label) \($0.worked)/\($0.sent)" }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    /// Hides who the message was to, so the AI learns the pattern, not the people.
    static func anonymise(_ r: SentRecord) -> String {
        var t = r.msg.text
        for part in [r.name] + r.name.split(separator: " ").map(String.init) where part.count > 2 {
            t = t.replacingOccurrences(of: part, with: "{name}", options: .caseInsensitive)
        }
        if r.company.count > 2 { t = t.replacingOccurrences(of: r.company, with: "{company}", options: .caseInsensitive) }
        return Redactor.mask(t)
    }

    /// What the draft writer is told: your playbook rules plus a few of your own messages that worked.
    func learnedBlock(category: String, intent: String) -> String {
        var parts: [String] = []
        if let p = data.outreachPlaybook, !p.rules.isEmpty {
            parts.append("Rules from the candidate's results:\n" + p.rules.prefix(6).map { "- \($0)" }.joined(separator: "\n"))
        }
        let worked = sentRecords.filter(\.worked)
        let best = (worked.filter { $0.kind == "note" && ($0.category == category || $0.msg.intent == intent) }
                    + worked.filter { $0.kind == "note" }).uniqued(by: \.id).prefix(3)
        if !best.isEmpty {
            parts.append("Notes of theirs that were accepted or answered:\n" + best.map { "- \(Self.anonymise($0))" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Coach

    func coachOutreach() async throws {
        let recs = sentRecords.filter { $0.outcome.resolved }
        guard recs.count >= 5 else {
            throw GroqError(message: "Log at least 5 messages that have an outcome (answered or not) first — right now there are \(recs.count).")
        }
        outreachStatus = "Studying your messages…"
        defer { outreachStatus = nil }
        let worked = recs.filter(\.worked).prefix(15)
        let didnt = recs.filter { !$0.worked }.prefix(15)
        func line(_ r: SentRecord) -> String {
            "[\(OutreachKind(rawValue: r.kind)?.label ?? r.kind) to \(ContactCategory(rawValue: r.category)?.label ?? "other")\(r.msg.intent.flatMap { ConnectionType(rawValue: $0) }.map { "; " + $0.label } ?? "")] \(Self.anonymise(r))"
        }
        let headline = data.profile.headline
        let stats = insightSummary(recs)
        let o = try await ask(output: 1800, temperature: 0.3) { budget in
            Prompts.outreachCoach(headline: headline, total: recs.count, workedCount: recs.filter(\.worked).count, stats: stats,
                                  worked: Prompts.clip(worked.map(line).joined(separator: "\n"), max(1500, budget / 3)),
                                  didnt: Prompts.clip(didnt.map(line).joined(separator: "\n"), max(1500, budget / 3)))
        }
        var p = OutreachPlaybook()
        p.working = J.strings(o, "working")
        p.notWorking = J.strings(o, "notWorking")
        p.rules = J.strings(o, "rules")
        p.experiments = J.strings(o, "experiments")
        p.caution = J.str(o, "caution")
        p.templates = J.dicts(o, "templates").map { PlaybookTemplate(kind: J.str($0, "kind"), purpose: J.str($0, "purpose"), text: J.str($0, "text")) }
            .filter { !$0.text.isEmpty }
        p.basedOn = recs.count
        data.outreachPlaybook = p
    }

    func reviewDraft(_ text: String, kind: String, intent: String?, category: String) async throws -> DraftReview {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw GroqError(message: "Paste or write the message first.") }
        let learned = learnedBlock(category: category, intent: intent ?? "")
        let o = try await ask(output: 900, temperature: 0.3) { _ in
            Prompts.reviewOutreach(text: Redactor.mask(t), kind: OutreachKind(rawValue: kind)?.label ?? kind,
                                   purpose: intent.flatMap { ConnectionType(rawValue: $0)?.label } ?? "not given",
                                   who: ContactCategory(rawValue: category)?.label ?? "someone", learned: learned)
        }
        var r = DraftReview()
        r.score = min(10, max(0, Int(J.str(o, "score")) ?? 0))
        r.verdict = J.str(o, "verdict")
        r.good = J.strings(o, "good")
        r.fix = J.strings(o, "fix")
        r.improved = J.str(o, "improved")
        if kind == "note" { r.improved = Self.fit(r.improved, 200) }
        return r
    }
}

extension Sequence {
    func uniqued<K: Hashable>(by key: KeyPath<Element, K>) -> [Element] {
        var seen = Set<K>()
        return filter { seen.insert($0[keyPath: key]).inserted }
    }
}

// MARK: - Prompts

extension Prompts {
    static func whoIsThisMessageTo(message: String, page: String, url: String) -> String {
        """
        TASK: The candidate just sent (or is about to send) this LinkedIn message. From the page text, work out who it is to.

        MESSAGE: \(clip(message, 800))
        PAGE URL: \(url)
        PAGE TEXT:
        \(clip(page, 5000))

        Return: {"person": "full name of the recipient", "headline": "their title if visible", "company": "their current company if visible",
                 "kind": "note|message|inmail"}
        kind: note = sent with an invitation ("Add a note" / invitation dialog); inmail = InMail; otherwise message.
        If the recipient can't be identified, return an empty person. Never guess a name that isn't on the page.
        """
    }

    static func outreachCoach(headline: String, total: Int, workedCount: Int, stats: String, worked: String, didnt: String) -> String {
        """
        TASK: You are coaching a job seeker (\(headline.isEmpty ? "senior professional" : headline)) on their LinkedIn outreach, \
        using ONLY their real results below. Find what separates the messages that worked from the ones that didn't.

        RESULTS: \(workedCount) of \(total) messages worked (a note "worked" if accepted; other messages if they got an answer).
        NUMBERS BY FEATURE (worked/sent):
        \(stats)

        MESSAGES THAT WORKED:
        \(worked.isEmpty ? "(none yet)" : worked)

        MESSAGES THAT DIDN'T:
        \(didnt.isEmpty ? "(none yet)" : didnt)

        Return: {"working": ["3–5 specific patterns in the ones that worked, quoting short phrases"],
                 "notWorking": ["3–5 specific patterns in the ones that didn't"],
                 "rules": ["5 short, concrete rules for their next messages"],
                 "experiments": ["2–3 A/B tests to try next, each naming what to compare"],
                 "templates": [{"kind": "note|message", "purpose": "", "text": "a template using {name}, {company}, {role}; notes ≤ 200 characters"}],
                 "caution": "one line on how far to trust this (sample size), or ''"}

        RULES: Base every claim on the examples or numbers — no generic LinkedIn advice unless the data supports it. \
        With fewer than ~10 examples in a group, call the pattern tentative. Give 2–3 templates. No emojis.
        """
    }

    static func reviewOutreach(text: String, kind: String, purpose: String, who: String, learned: String) -> String {
        """
        TASK: Review this LinkedIn \(kind) a job seeker is about to send to a \(who). Purpose: \(purpose).

        MESSAGE:
        \(text)

        \(learned.isEmpty ? "" : "WHAT HAS WORKED FOR THEM BEFORE:\n\(learned)\n")
        Return: {"score": 1-10, "verdict": "one line", "good": ["what works, max 3"], "fix": ["specific changes, max 4"],
                 "improved": "the improved message, same facts, \(kind == "Connection note" ? "200 characters or fewer" : "under 600 characters")"}

        RULES: Judge on: specific reason to connect, relevance to the person, a light and clear ask, brevity, no clichés, \
        nothing that sounds templated. Keep every fact as written — never add achievements, mutual connections or details.
        """
    }
}
