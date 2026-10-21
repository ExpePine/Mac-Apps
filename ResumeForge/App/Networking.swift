import AppKit
import Foundation

// MARK: - Models

/// A person you might connect with (or already have) — usually found automatically when you apply.
struct Contact: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var headline = ""
    var company = ""
    var linkedinURL = ""
    var category = "other"          // hiringManager | recruiter | leader | peer | other
    var relevance = 0               // 0–100 for the job you found them for
    var why = ""
    var jobIDs: [UUID] = []
    var status = "suggested"        // suggested | requested | connected | replied | meeting | ignored
    var notes = ""
    var interactions: [Interaction] = []
    var drafts: [MessageDraft] = []
    var source = "search"           // search | screenshot | manual
    var createdAt = Date()
    var updatedAt = Date()

    var lastInteraction: Date? { interactions.map(\.date).max() }
}

/// One message in your history with a person (from a screenshot, pasted text, or a draft you sent).
struct Interaction: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var dateText = ""
    var fromMe = true
    var channel = "linkedin"
    var text = ""
    var source = "manual"           // screenshot | pasted | draft | manual
}

struct MessageDraft: Codable, Identifiable, Hashable {
    var id = UUID()
    var type = ""
    var tone = ""
    var notes: [String] = []        // connection-request notes (≤ 200 characters)
    var followUps: [String] = []    // messages to send after they accept
    var tip = ""
    var at = Date()
}

enum ContactCategory: String, CaseIterable, Identifiable {
    case hiringManager, recruiter, leader, peer, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hiringManager: return "Likely hiring manager"
        case .recruiter: return "Recruiter / HR"
        case .leader: return "Leadership"
        case .peer: return "Team / peer"
        case .other: return "Other"
        }
    }
    var icon: String {
        switch self {
        case .hiringManager: return "person.badge.key"
        case .recruiter: return "person.text.rectangle"
        case .leader: return "star.circle"
        case .peer: return "person.2"
        case .other: return "person"
        }
    }
}

enum ConnectionStatus: String, CaseIterable, Identifiable {
    case suggested, requested, connected, replied, meeting, ignored
    var id: String { rawValue }
    var label: String {
        switch self {
        case .suggested: return "Suggested"
        case .requested: return "Request sent"
        case .connected: return "Connected"
        case .replied: return "Replied"
        case .meeting: return "Call / meeting"
        case .ignored: return "Not pursuing"
        }
    }
}

/// The kinds of connection you can ask for — each gets its own message style.
enum ConnectionType: String, CaseIterable, Identifiable {
    case referral, hiringManager, recruiter, informational, commonGround, afterApplying, thankYou
    var id: String { rawValue }
    var label: String {
        switch self {
        case .referral: return "Ask for a referral"
        case .hiringManager: return "Introduce myself to the hiring manager"
        case .recruiter: return "Reach the recruiter about the role"
        case .informational: return "Informational chat (learn about team/role)"
        case .commonGround: return "Connect on common ground (domain, alumni, city)"
        case .afterApplying: return "I've applied — put my profile on their radar"
        case .thankYou: return "Thank you / keep in touch"
        }
    }
}

// MARK: - Web search providers (Google results)

enum SearchProvider: String, CaseIterable, Identifiable {
    case serper, tavily
    var id: String { rawValue }
    var title: String { self == .serper ? "Serper (Google results)" : "Tavily" }
    var keyURL: String { self == .serper ? "https://serper.dev" : "https://app.tavily.com" }
    var account: String { "search-key-\(rawValue)" }
    var key: String { Keychain.load(account: account) }
}

struct SearchHit: Hashable {
    var title: String
    var url: String
    var snippet: String
}

enum WebSearch {
    static var order: [SearchProvider] {
        let raw = UserDefaults.standard.stringArray(forKey: "searchOrder") ?? ["serper", "tavily"]
        let list = raw.compactMap(SearchProvider.init(rawValue:))
        return list + SearchProvider.allCases.filter { !list.contains($0) }
    }
    static var usable: [SearchProvider] { order.filter { !$0.key.isEmpty } }

    static var dailyCap: Int {
        let v = UserDefaults.standard.integer(forKey: "searchDailyCap")
        return v > 0 ? v : 30
    }
    private static var todayKey: String {
        "searches." + ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
    }
    static var usedToday: Int { UserDefaults.standard.integer(forKey: todayKey) }
    private static func count() {
        UserDefaults.standard.set(usedToday + 1, forKey: todayKey)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "searchesTotal") + 1, forKey: "searchesTotal")
    }

    /// Runs one Google-style query against the first provider that answers.
    static func search(_ q: String, num: Int = 10) async throws -> [SearchHit] {
        guard usedToday < dailyCap else {
            throw GroqError(message: "Daily search limit reached (\(dailyCap)). Change it in Settings ▸ Networking.")
        }
        guard !usable.isEmpty else {
            throw GroqError(message: "Add a Serper or Tavily key in Settings ▸ Networking to find people.")
        }
        var lastError: Error?
        for p in usable {
            do {
                let hits = try await run(p, q, num)
                count()
                return hits
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GroqError(message: "Search failed.")
    }

    private static func run(_ p: SearchProvider, _ q: String, _ num: Int) async throws -> [SearchHit] {
        var req: URLRequest
        switch p {
        case .serper:
            req = URLRequest(url: URL(string: "https://google.serper.dev/search")!)
            req.setValue(p.key, forHTTPHeaderField: "X-API-KEY")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["q": q, "num": num, "gl": "in"])
        case .tavily:
            req = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
            req.setValue("Bearer \(p.key)", forHTTPHeaderField: "Authorization")
            // Tavily doesn't take Google operators — drop site:, keep the words, restrict to LinkedIn.
            let words = q.replacingOccurrences(of: #"site:\S+"#, with: "", options: .regularExpression)
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": words.trimmingCharacters(in: .whitespaces), "max_results": min(num, 20),
                "include_domains": ["linkedin.com"], "search_depth": "basic"
            ])
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw GroqError(message: "\(p.title) error \(code): \(String(decoding: d.prefix(300), as: UTF8.self))")
        }
        switch p {
        case .serper:
            return J.dicts(obj, "organic").map { SearchHit(title: J.str($0, "title"), url: J.str($0, "link"), snippet: J.str($0, "snippet")) }
        case .tavily:
            return J.dicts(obj, "results").map { SearchHit(title: J.str($0, "title"), url: J.str($0, "url"), snippet: J.str($0, "content")) }
        }
    }

    /// "Priya Shah - Head of Product - Acme | LinkedIn" → ("Priya Shah", "Head of Product - Acme")
    static func parseLinkedIn(_ hit: SearchHit) -> (name: String, headline: String, url: String)? {
        guard let comps = URLComponents(string: hit.url), let host = comps.host?.lowercased(), host.hasSuffix("linkedin.com"),
              comps.path.hasPrefix("/in/") else { return nil }
        let slug = comps.path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
        guard !slug.isEmpty else { return nil }
        let url = "https://www.linkedin.com/in/\(slug)"
        var t = hit.title.replacingOccurrences(of: " | LinkedIn", with: "").replacingOccurrences(of: "| LinkedIn", with: "")
        t = t.trimmingCharacters(in: .whitespaces)
        let parts = t.components(separatedBy: CharacterSet(charactersIn: "-–|")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let name = parts.first, name.count >= 3, name.count <= 60 else { return nil }
        return (name, parts.dropFirst().joined(separator: " · "), url)
    }
}

// MARK: - Prompts

extension Prompts {
    static func peopleQueries(company: String, title: String, location: String, jd: String) -> String {
        """
        TASK: The candidate applied for "\(title)" at "\(company)" (\(location)). Write Google search queries that find the \
        most useful people at \(company) to connect with on LinkedIn: the likely hiring manager (the role this job reports to), \
        recruiters/talent acquisition for this function, senior leaders of the function, and 1–2 peers in a similar role.

        Return: {"queries": [{"q": "site:linkedin.com/in \\"\(company)\\" (\\"Head of Product\\" OR \\"Director Product\\")", "target": "hiring manager"}]}

        RULES: 3 queries max. Always start with site:linkedin.com/in and the exact company name in quotes (use the common short \
        name if it's long). Use OR between 2–4 job titles in quotes. Add the city only if the company is large and multi-location. \
        Infer the reporting line from the JD.

        JD (excerpt):
        \(clip(jd, 2500))
        """
    }

    static func rankPeople(company: String, title: String, people: String) -> String {
        """
        TASK: These LinkedIn search results were found for the candidate, who applied for "\(title)" at "\(company)". \
        Decide who is worth connecting with.

        Return: {"people": [{"i": 0, "keep": true, "category": "hiringManager|recruiter|leader|peer|other",
                             "currentlyAtCompany": true, "relevance": 0-100, "why": "max 12 words"}]}

        RULES: keep only people who currently appear to work at \(company) (or its parent/brand). hiringManager = the function's \
        manager/head the role likely reports to; recruiter = HR/talent acquisition; leader = VP/CXO/founder of the function or \
        company; peer = same or adjacent role. Relevance = how useful a connection is for getting this job.

        RESULTS:
        \(people)
        """
    }

    static func connectionMessages(contactName: String, contactHeadline: String, category: String,
                                   jobTitle: String, company: String, type: String, tone: String, goal: String,
                                   history: String, myHeadline: String, myHighlights: String) -> String {
        """
        TASK: Write LinkedIn messages from the candidate to \(contactName) (\(contactHeadline); \(category)) about the \
        "\(jobTitle)" role at \(company).

        CONNECTION TYPE: \(type)
        TONE: \(tone)
        \(goal.isEmpty ? "" : "WHAT THE CANDIDATE WANTS: \(goal)")
        CANDIDATE: \(myHeadline)
        CANDIDATE'S RELEVANT HIGHLIGHTS (true facts — use at most one per message):
        \(myHighlights)
        \(history.isEmpty ? "" : "PREVIOUS MESSAGES WITH THIS PERSON:\n\(history)")

        Return: {"notes": ["3 different connection-request notes, each 200 characters or fewer"],
                 "followUps": ["2 messages to send after they accept, 350–600 characters"],
                 "tip": "one practical tip for this person/type, max 20 words"}

        RULES: Use their first name. Be specific to their role and the job; one concrete reason to connect; a light, \
        easy ask (no attachments, no "please refer me" in the first note unless the type is referral). Never invent shared \
        history, mutual connections, or facts about them beyond their headline. Never invent facts about the candidate. \
        No emojis, no "I hope this finds you well". Notes MUST be ≤ 200 characters including spaces. \
        The candidate's name is added by LinkedIn — don't sign off with a name.
        """
    }

    static func readConversation() -> String {
        """
        TASK: The image is a screenshot of a LinkedIn conversation, invitation or profile from the candidate's account. \
        Extract who it is with and the messages, so the candidate can remember how they networked.

        Return: {"person": "the other person's full name", "headline": "their headline/title if visible", "company": "",
                 "messages": [{"fromMe": true, "date": "YYYY-MM-DD if visible, else the visible text like 'Tue' or ''", "text": "the message"}],
                 "status": "requested|connected|replied|meeting|none", "summary": "one line: what happened and what's next"}

        RULES: Copy message text exactly as shown. 'fromMe' is true for messages the account owner sent (usually on the right / \
        labelled with their name or 'You'). status: requested = invitation pending; connected = accepted, no real reply yet; \
        replied = they wrote back; meeting = a call/meeting was agreed.
        """
    }
}

// MARK: - Engine

extension AppStore {

    var contacts: [Contact] { data.contacts ?? [] }
    func contactIndex(_ id: UUID) -> Int? { data.contacts?.firstIndex { $0.id == id } }

    static var autoFindOnApply: Bool { UserDefaults.standard.object(forKey: "findPeopleOnApply") as? Bool ?? true }
    static var peoplePerCompany: Int {
        let v = UserDefaults.standard.integer(forKey: "peoplePerCompany")
        return v > 0 ? v : 8
    }

    /// Finds key people at the job's company (Google search via Serper/Tavily), ranks them with the AI, adds them to Connections.
    func findPeople(jobID: UUID) async throws {
        guard let job = data.jobs.first(where: { $0.id == jobID }) else { return }
        guard !job.company.isEmpty else { throw GroqError(message: "This job has no company name yet, so there's no one to search for.") }
        peopleSearchStatus = "Finding people at \(job.company)…"
        defer { peopleSearchStatus = nil }

        // 1. Queries (AI writes them; simple fallback without AI)
        var queries: [String] = []
        if ProviderSettings.anyKeyConfigured {
            if let o = try? await ask(output: 500, temperature: 0.2, build: { _ in
                Prompts.peopleQueries(company: job.company, title: job.title, location: job.location, jd: job.description)
            }) {
                queries = J.dicts(o, "queries").map { J.str($0, "q") }.filter { $0.contains("linkedin.com") }
            }
        }
        if queries.isEmpty { queries = Self.fallbackQueries(company: job.company, title: job.title) }

        // 2. Search
        var hits: [(name: String, headline: String, url: String, snippet: String)] = []
        var seen = Set(contacts.map { $0.linkedinURL.lowercased() })
        for q in queries.prefix(3) {
            for h in try await WebSearch.search(q) {
                guard let p = WebSearch.parseLinkedIn(h), seen.insert(p.url.lowercased()).inserted else { continue }
                hits.append((p.name, p.headline, p.url, h.snippet))
            }
        }
        // People already in Connections: just link them to this job.
        linkExistingContacts(to: job)
        guard !hits.isEmpty else {
            peopleSearchStatus = "No new LinkedIn profiles found for \(job.company)."
            return
        }

        // 3. Rank (AI) — or keep everyone with a guessed category
        var ranked: [Contact] = hits.map { h in
            var c = Contact()
            c.name = h.name; c.headline = h.headline; c.company = job.company; c.linkedinURL = h.url
            c.category = Self.guessCategory(h.headline)
            c.relevance = 50
            c.jobIDs = [jobID]
            return c
        }
        if ProviderSettings.anyKeyConfigured {
            let list = hits.enumerated().map { "\($0.offset). \($0.element.name) — \($0.element.headline) — \(Prompts.clip($0.element.snippet, 160))" }
                .joined(separator: "\n")
            if let o = try? await ask(output: 1200, temperature: 0.1, build: { _ in
                Prompts.rankPeople(company: job.company, title: job.title, people: list)
            }) {
                var keep: [Contact] = []
                for p in J.dicts(o, "people") {
                    guard let i = Int(J.str(p, "i")), ranked.indices.contains(i), J.bool(p, "keep"),
                          (p["currentlyAtCompany"] as? Bool ?? true) else { continue }
                    var c = ranked[i]
                    let cat = J.str(p, "category")
                    if ContactCategory(rawValue: cat) != nil { c.category = cat }
                    c.relevance = min(100, max(0, Int(J.str(p, "relevance")) ?? 50))
                    c.why = J.str(p, "why")
                    keep.append(c)
                }
                if !keep.isEmpty { ranked = keep }
            }
        }
        ranked.sort { $0.relevance > $1.relevance }
        let chosen = Array(ranked.prefix(Self.peoplePerCompany))
        var list = data.contacts ?? []
        list.insert(contentsOf: chosen, at: 0)
        data.contacts = list
        peopleSearchStatus = "Found \(chosen.count) people at \(job.company)"
    }

    func findPeopleForFeed(_ feedID: String) {
        guard let jid = addFeedJobToJobs(feedID, process: false) else { return }
        run("Finding people…") { try await self.findPeople(jobID: jid) }
    }

    private func linkExistingContacts(to job: JobPosting) {
        let co = Self.norm(job.company)
        guard !co.isEmpty, var list = data.contacts else { return }
        for i in list.indices where Self.norm(list[i].company) == co && !list[i].jobIDs.contains(job.id) {
            list[i].jobIDs.append(job.id)
        }
        data.contacts = list
    }

    static func guessCategory(_ headline: String) -> String {
        let h = headline.lowercased()
        if h.range(of: #"recruit|talent|hr\b|human resources|people partner|hiring"#, options: .regularExpression) != nil { return "recruiter" }
        if h.range(of: #"\b(ceo|cto|coo|cpo|founder|vp|vice president|chief)\b"#, options: .regularExpression) != nil { return "leader" }
        if h.range(of: #"\b(head|director|lead|manager)\b"#, options: .regularExpression) != nil { return "hiringManager" }
        return "peer"
    }

    static func fallbackQueries(company: String, title: String) -> [String] {
        let fn = title.lowercased().contains("product") ? "Product" : (title.split(separator: " ").last.map(String.init) ?? "")
        return [
            "site:linkedin.com/in \"\(company)\" (\"Head of \(fn)\" OR \"Director \(fn)\" OR \"VP \(fn)\")",
            "site:linkedin.com/in \"\(company)\" (\"Talent Acquisition\" OR \"Recruiter\" OR \"HR Business Partner\")",
            "site:linkedin.com/in \"\(company)\" \"\(title)\""
        ]
    }

    // MARK: Messages

    func draftMessages(contactID: UUID, type: ConnectionType, tone: String, goal: String) async throws {
        guard let i = contactIndex(contactID) else { return }
        let c = contacts[i]
        let job = c.jobIDs.compactMap { id in data.jobs.first { $0.id == id } }.first
        let highlights = Prompts.rank(data.stories, by: (job?.title ?? "") + " " + (job?.description ?? "") + " " + c.headline)
            .prefix(3)
            .map { "- \($0.title): \(Prompts.clip($0.text, 260))\($0.metrics.isEmpty ? "" : " (" + $0.metrics.prefix(2).joined(separator: "; ") + ")")" }
            .joined(separator: "\n")
        let history = c.interactions.sorted { $0.date < $1.date }.suffix(6)
            .map { "\($0.fromMe ? "Me" : "Them"): \(Prompts.clip($0.text, 300))" }.joined(separator: "\n")
        let headline = data.profile.headline.isEmpty ? (data.profile.roles.first.map { "\($0.title) at \($0.company)" } ?? "") : data.profile.headline
        let o = try await ask(output: 1200, temperature: 0.7) { _ in
            Prompts.connectionMessages(contactName: c.name, contactHeadline: c.headline,
                                       category: ContactCategory(rawValue: c.category)?.label ?? c.category,
                                       jobTitle: job?.title ?? "a role", company: c.company, type: type.label, tone: tone, goal: goal,
                                       history: history, myHeadline: headline, myHighlights: highlights.isEmpty ? "(none recorded)" : highlights)
        }
        var d = MessageDraft()
        d.type = type.label
        d.tone = tone
        d.notes = J.strings(o, "notes").map { Self.fit($0, 200) }
        d.followUps = J.strings(o, "followUps")
        d.tip = J.str(o, "tip")
        guard let k = contactIndex(contactID) else { return }
        data.contacts?[k].drafts.insert(d, at: 0)
        data.contacts?[k].updatedAt = Date()
    }

    /// Trims to LinkedIn's limit at a word boundary if the AI ran over.
    static func fit(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        var cut = String(s.prefix(n))
        if let r = cut.range(of: " ", options: .backwards) { cut = String(cut[..<r.lowerBound]) }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;—-")) + (cut.hasSuffix(".") ? "" : ".")
    }

    /// Copies the message, opens their profile, and logs it as sent.
    func useMessage(_ text: String, contactID: UUID, isNote: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard let i = contactIndex(contactID) else { return }
        if let url = URL(string: contacts[i].linkedinURL) { NSWorkspace.shared.open(url) }
        var it = Interaction()
        it.text = text
        it.source = "draft"
        data.contacts?[i].interactions.append(it)
        if isNote, contacts[i].status == "suggested" { data.contacts?[i].status = "requested" }
        data.contacts?[i].updatedAt = Date()
    }

    func setContactStatus(_ id: UUID, _ s: ConnectionStatus) {
        guard let i = contactIndex(id) else { return }
        data.contacts?[i].status = s.rawValue
        data.contacts?[i].updatedAt = Date()
    }

    // MARK: Screenshots / pasted conversations

    /// Reads a LinkedIn screenshot (or pasted text), finds or creates the person, and adds the messages to their history.
    @discardableResult
    func importConversation(image: Data?, text: String?) async throws -> UUID? {
        var o: [String: Any]
        if let image {
            guard let img = AIClient.preparedImage(image, maxSide: 1800) else { throw GroqError(message: "Couldn't read that image.") }
            o = try await ask(output: 1500, temperature: 0.1, images: [img]) { _ in Prompts.readConversation() }
        } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            o = try await ask(output: 1500, temperature: 0.1) { budget in
                Prompts.readConversation().replacingOccurrences(of: "The image is a screenshot of", with: "The text below is a copy of")
                    + "\n\nTEXT:\n" + Prompts.clip(text, max(2000, budget - 2000))
            }
        } else { return nil }

        let name = J.str(o, "person")
        guard !name.isEmpty else { throw GroqError(message: "Couldn't tell who this conversation is with.") }
        let msgs: [Interaction] = J.dicts(o, "messages").compactMap { m in
            let t = J.str(m, "text")
            guard !t.isEmpty else { return nil }
            var it = Interaction()
            it.text = t
            it.fromMe = m["fromMe"] as? Bool ?? (J.str(m, "fromMe") == "true")
            it.dateText = J.str(m, "date")
            if let d = Self.parseDue(it.dateText) { it.date = d }
            it.source = image != nil ? "screenshot" : "pasted"
            return it
        }
        var list = data.contacts ?? []
        let key = Self.norm(name)
        let idx = list.firstIndex { Self.norm($0.name) == key }
            ?? list.firstIndex { !key.isEmpty && (Self.norm($0.name).contains(key) || key.contains(Self.norm($0.name))) && !$0.name.isEmpty }
        var c = idx.map { list[$0] } ?? Contact()
        if idx == nil {
            c.name = name
            c.source = image != nil ? "screenshot" : "manual"
            c.company = J.str(o, "company")
            c.category = Self.guessCategory(J.str(o, "headline"))
            if let job = data.jobs.first(where: { !c.company.isEmpty && Self.norm($0.company) == Self.norm(c.company) }) { c.jobIDs = [job.id] }
        }
        if c.headline.isEmpty { c.headline = J.str(o, "headline") }
        if c.company.isEmpty { c.company = J.str(o, "company") }
        // Skip messages already recorded (same text).
        let have = Set(c.interactions.map { Self.norm($0.text) })
        c.interactions += msgs.filter { !have.contains(Self.norm($0.text)) }
        let st = J.str(o, "status")
        if let s = ConnectionStatus(rawValue: st), Self.statusRank(s.rawValue) > Self.statusRank(c.status) { c.status = s.rawValue }
        let summary = J.str(o, "summary")
        if !summary.isEmpty { c.notes = c.notes.isEmpty ? summary : c.notes + "\n" + summary }
        c.updatedAt = Date()
        if let idx { list[idx] = c } else { list.insert(c, at: 0) }
        data.contacts = list
        return c.id
    }

    static func statusRank(_ s: String) -> Int {
        ["ignored": 0, "suggested": 1, "requested": 2, "connected": 3, "replied": 4, "meeting": 5][s] ?? 1
    }
}
