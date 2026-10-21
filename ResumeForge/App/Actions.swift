import AppKit
import Foundation

// MARK: - Models

/// Something you need to do about a job — usually added from Safari while looking at the JD.
struct ActionItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind = "custom"              // linkedin | whatsapp | call | email | apply | custom
    var text = ""                    // what you wrote / the preset
    var title = ""                   // short imperative version (AI), e.g. "Message Priya (ABC Search) on WhatsApp"
    var jobID: UUID?
    var company = ""
    var person = ""                  // consultant / recruiter / hiring manager
    var personRole = ""              // e.g. "Consultant, ABC Search Partners"
    var contact = ""                 // phone, email or LinkedIn URL found on the page
    var due: Date?
    var dueText = ""
    var status = "open"              // open | done | dropped
    var notes = ""
    var pageURL = ""
    var createdAt = Date()
    var doneAt: Date?
    var enriched = false
    var enrichError: String?

    var displayTitle: String { title.isEmpty ? (text.isEmpty ? ActionKind(rawValue: kind)?.label ?? "Action" : text) : title }
    var isOpen: Bool { status == "open" }
}

enum ActionKind: String, CaseIterable, Identifiable {
    case linkedin, whatsapp, call, email, apply, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .linkedin: return "Meet on LinkedIn"
        case .whatsapp: return "Message on WhatsApp"
        case .call: return "Call"
        case .email: return "Email follow-up"
        case .apply: return "Apply"
        case .custom: return "Other"
        }
    }
    var icon: String {
        switch self {
        case .linkedin: return "person.crop.square"
        case .whatsapp: return "message"
        case .call: return "phone"
        case .email: return "envelope"
        case .apply: return "paperplane"
        case .custom: return "checklist"
        }
    }
}

/// AI commentary on your whole workload.
struct Commentary: Codable, Hashable {
    var headline = ""
    var doNow: [String] = []
    var overdue: [String] = []
    var stalled: [String] = []
    var suggestions: [String] = []
    var generatedAt = Date()
}

// MARK: - Prompts

extension Prompts {
    static func enrichAction(kind: String, text: String, selection: String, pageTitle: String, pageURL: String,
                             jobTitle: String, jobCompany: String, jdOrPage: String, now: String) -> String {
        """
        TASK: The candidate added a to-do while looking at a job posting (or a recruiter's page). \
        Work out WHO it involves and WHEN, using only the text below.

        Return:
        {"title": "short imperative to-do, max 10 words, e.g. 'Message Priya (ABC Search) on WhatsApp'",
         "company": "the hiring company; if hidden and posted by a consultancy write 'Confidential (via <consultancy>)'",
         "person": "consultant / recruiter / hiring manager named on the page, or in the to-do text; '' if none",
         "personRole": "their role and firm, e.g. 'Consultant, ABC Search Partners'",
         "contact": "a phone number, email or LinkedIn URL for that person IF it appears in the text; '' otherwise",
         "due": "ISO date-time YYYY-MM-DDTHH:MM if the to-do or page implies one (e.g. 'tomorrow 3pm', 'by Friday', an application deadline); '' otherwise",
         "dueText": "the phrase you based the date on, '' if none"}

        RULES: Never invent names, numbers or dates. Prefer the person the to-do mentions; otherwise the recruiter/consultant \
        in the posting ("posted by", "contact", "recruiter", "reach out to"). Interpret dates relative to NOW (India time).

        NOW: \(now)
        TO-DO TYPE: \(kind)
        TO-DO TEXT: \(text.isEmpty ? "(none — use the type)" : text)
        SELECTED ON PAGE: \(selection.isEmpty ? "(nothing)" : clip(selection, 600))
        PAGE: \(pageTitle) — \(pageURL)
        JOB: \(jobTitle) at \(jobCompany)

        TEXT:
        \(jdOrPage)
        """
    }

    static func commentary(now: String, actions: String, jobs: String) -> String {
        """
        TASK: You are the candidate's job-search chief of staff. Look at their whole workload and write a short, \
        practical commentary. Be direct and specific (name the company/person). No fluff.

        Return:
        {"headline": "one sentence on where things stand today",
         "doNow": ["the 3–5 things to do next, in order, each with a few words on why"],
         "overdue": ["overdue or at-risk items"],
         "stalled": ["jobs going nowhere: e.g. resume ready but no application/outreach action, strong match with no action, actions open for 7+ days"],
         "suggestions": ["at most 3: reschedule, batch similar actions, drop low-fit jobs, etc."]}

        NOW: \(now)

        OPEN ACTIONS (due · action · company/person · job):
        \(actions)

        JOBS (title · company · fit score · progress · open actions):
        \(jobs)
        """
    }
}

// MARK: - Engine

extension AppStore {

    var actions: [ActionItem] { data.actions ?? [] }
    func actionIndex(_ id: UUID) -> Int? { data.actions?.firstIndex { $0.id == id } }

    static let nowFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return f
    }()

    /// From Safari: link/create the job, store the action, then let the AI fill in person/company/date.
    func ingestAction(_ a: ActionPayload) {
        var jobID: UUID?
        if let c = a.job, !c.title.isEmpty || c.description.count >= 200 {
            let keys = Set(Self.jobKeys(url: c.url, title: c.title, company: c.company))
            if let existing = data.jobs.first(where: { !keys.isDisjoint(with: Self.jobKeys(url: $0.url, title: $0.title, company: $0.company)) }) {
                jobID = existing.id
            } else {
                ingest(c)                                   // adds the JD like a normal capture
                jobID = data.jobs.first(where: { !keys.isDisjoint(with: Self.jobKeys(url: $0.url, title: $0.title, company: $0.company)) })?.id
            }
        }
        var item = ActionItem()
        item.kind = ActionKind(rawValue: a.kind) == nil ? "custom" : a.kind
        item.text = a.text
        item.jobID = jobID
        item.pageURL = a.pageURL
        if let j = jobID.flatMap({ id in data.jobs.first { $0.id == id } }) { item.company = j.company }
        addAction(item, pageTitle: a.pageTitle, pageText: a.pageText, selection: a.selection)
    }

    func addAction(_ item: ActionItem, pageTitle: String = "", pageText: String = "", selection: String = "") {
        var list = data.actions ?? []
        list.insert(item, at: 0)
        data.actions = list
        let id = item.id
        if ProviderSettings.anyKeyConfigured {
            Task { @MainActor in await self.enrichAction(id, pageTitle: pageTitle, pageText: pageText, selection: selection) }
        }
        scheduleCommentary()
    }

    func enrichAction(_ id: UUID, pageTitle: String = "", pageText: String = "", selection: String = "") async {
        guard let i = actionIndex(id) else { return }
        let item = actions[i]
        let job = item.jobID.flatMap { jid in data.jobs.first { $0.id == jid } }
        let source = (job?.description.isEmpty == false ? job!.description : "") + (pageText.isEmpty ? "" : "\n\nPAGE TEXT:\n" + pageText)
        let now = Self.nowFormatter.string(from: Date())
        do {
            let o = try await ask(output: 600, temperature: 0.1) { budget in
                Prompts.enrichAction(kind: ActionKind(rawValue: item.kind)?.label ?? item.kind, text: item.text, selection: selection,
                                     pageTitle: pageTitle, pageURL: item.pageURL, jobTitle: job?.title ?? "", jobCompany: job?.company ?? "",
                                     jdOrPage: Prompts.clip(source, max(1500, budget - 2000)), now: now)
            }
            guard let k = actionIndex(id) else { return }
            var a = actions[k]
            let t = J.str(o, "title"); if !t.isEmpty { a.title = t }
            let c = J.str(o, "company"); if !c.isEmpty && (a.company.isEmpty || c.contains("Confidential")) { a.company = c }
            let p = J.str(o, "person"); if !p.isEmpty { a.person = p }
            let r = J.str(o, "personRole"); if !r.isEmpty { a.personRole = r }
            let ct = J.str(o, "contact"); if !ct.isEmpty { a.contact = ct }
            if a.due == nil, let d = Self.parseDue(J.str(o, "due")) { a.due = d; a.dueText = J.str(o, "dueText") }
            // Link to a job by company when added from a non-JD page (e.g. a recruiter's profile).
            if a.jobID == nil, !a.company.isEmpty {
                let co = Self.norm(a.company)
                a.jobID = data.jobs.first { !co.isEmpty && (Self.norm($0.company).contains(co) || co.contains(Self.norm($0.company))) && !$0.company.isEmpty }?.id
            }
            a.enriched = true
            a.enrichError = nil
            data.actions?[k] = a
        } catch {
            if let k = actionIndex(id) { data.actions?[k].enrichError = error.localizedDescription }
        }
    }

    static func parseDue(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = fmt
            if let d = f.date(from: t) {
                return fmt == "yyyy-MM-dd" ? Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: d) : d
            }
        }
        return nil
    }

    func setActionStatus(_ id: UUID, _ status: String) {
        guard let i = actionIndex(id) else { return }
        data.actions?[i].status = status
        data.actions?[i].doneAt = status == "done" ? Date() : nil
        scheduleCommentary()
    }

    func deleteAction(_ id: UUID) {
        data.actions?.removeAll { $0.id == id }
        scheduleCommentary()
    }

    // MARK: Opening the right app

    func open(_ a: ActionItem) {
        let digits = a.contact.filter(\.isNumber)
        var url: URL?
        switch a.kind {
        case "whatsapp":
            if digits.count >= 10 {
                let num = digits.count == 10 ? "91" + digits : digits     // assume India if no country code
                url = URL(string: "https://wa.me/\(num)")
            } else {
                url = URL(string: "whatsapp://")
            }
        case "linkedin":
            if a.contact.lowercased().contains("linkedin.com") {
                url = URL(string: a.contact.hasPrefix("http") ? a.contact : "https://" + a.contact)
            } else {
                let q = [a.person, a.personRole.isEmpty ? a.company : a.personRole].filter { !$0.isEmpty }.joined(separator: " ")
                url = URL(string: "https://www.linkedin.com/search/results/people/?keywords=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))
            }
        case "email":
            if a.contact.contains("@") { url = URL(string: "mailto:\(a.contact)") }
        case "call":
            if digits.count >= 10 { url = URL(string: "tel:+\(digits.count == 10 ? "91" + digits : digits)") }
        default:
            break
        }
        if url == nil, let jid = a.jobID, let j = data.jobs.first(where: { $0.id == jid }), !j.url.isEmpty { url = URL(string: j.url) }
        if url == nil, !a.pageURL.isEmpty { url = URL(string: a.pageURL) }
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: Workload commentary

    /// Refreshes commentary after changes (at most every 20 minutes), or right away when asked.
    func scheduleCommentary(force: Bool = false) {
        guard ProviderSettings.anyKeyConfigured, !actions.isEmpty || !data.jobs.isEmpty else { return }
        if !force, let c = data.commentary, Date().timeIntervalSince(c.generatedAt) < 20 * 60 { commentaryStale = true; return }
        commentaryTask?.cancel()
        commentaryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: force ? 0 : 8_000_000_000)   // let a burst of changes settle
            guard !Task.isCancelled else { return }
            await self.refreshCommentary()
        }
    }

    func refreshCommentary() async {
        commentaryBusy = true
        defer { commentaryBusy = false }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_IN")
        df.dateFormat = "EEE d MMM HH:mm"
        let open = actions.filter(\.isOpen).sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let jobName: (UUID?) -> String = { id in
            guard let id, let j = self.data.jobs.first(where: { $0.id == id }) else { return "—" }
            return "\(j.title) @ \(j.company)"
        }
        let actionLines = open.prefix(60).map { a in
            let due = a.due.map { (Date() > $0 ? "OVERDUE " : "") + df.string(from: $0) } ?? "no date"
            let who = [a.person, a.company].filter { !$0.isEmpty }.joined(separator: ", ")
            let age = Int(Date().timeIntervalSince(a.createdAt) / 86400)
            return "- \(due) · \(a.displayTitle) · \(who) · \(jobName(a.jobID)) · added \(age)d ago"
        }.joined(separator: "\n")
        let jobLines = data.jobs.prefix(40).map { j in
            let n = open.filter { $0.jobID == j.id }.count
            let progress = j.tailored != nil ? "resume ready" : (j.stage?.label ?? "captured")
            let fit = j.match.map { "fit \($0.score)\($0.hardConflicts.isEmpty ? "" : " (conflicts)")" } ?? "fit ?"
            return "- \(j.title) · \(j.company) · \(fit) · \(progress) · \(n) open action(s) · captured \(Int(Date().timeIntervalSince(j.capturedAt) / 86400))d ago"
        }.joined(separator: "\n")
        let now = Self.nowFormatter.string(from: Date())
        do {
            let o = try await ask(output: 900, temperature: 0.3) { budget in
                Prompts.commentary(now: now, actions: Prompts.clip(actionLines.isEmpty ? "(none)" : actionLines, budget / 2),
                                   jobs: Prompts.clip(jobLines.isEmpty ? "(none)" : jobLines, budget / 2 - 1500))
            }
            var c = Commentary()
            c.headline = J.str(o, "headline")
            c.doNow = J.strings(o, "doNow")
            c.overdue = J.strings(o, "overdue")
            c.stalled = J.strings(o, "stalled")
            c.suggestions = J.strings(o, "suggestions")
            data.commentary = c
            commentaryStale = false
            commentaryError = nil
        } catch {
            commentaryError = error.localizedDescription
        }
    }
}
