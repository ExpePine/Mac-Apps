import AppKit
import Foundation

// MARK: - Models

/// How well a job fits you. `local` = quick on-device estimate; otherwise the AI read the JD against your stories.
struct MatchResult: Codable, Hashable {
    var score = 0                       // 0–100
    var verdict = ""
    var hardConflicts: [String] = []    // likely deal-breakers
    var softGaps: [String] = []         // things a story or a cover note could address
    var strengths: [String] = []
    var why = ""
    var local = true
    var at = Date()
    var basis: String?                  // fingerprint of your profile + stories when checked (re-check when they change)
}

/// A job from the GitHub job collector's feed.
struct FeedJob: Codable, Identifiable, Hashable {
    var id: String
    var source = ""
    var publisher = ""
    var title = ""
    var company = ""
    var location = ""
    var url = ""
    var description = ""
    var posted = ""
    var salary = ""
    var experience = ""
    var snippet = true
    var firstSeen = ""
    var category: String?               // e.g. "Product-Manager" / "Edge-AI" from your Naukri sheet
    var tags: [String]?                 // auto-classification: role family, domain, seniority, work mode
    var liked: Bool?
    var appliedAt: Date?
    var status = "new"                  // new | added | dismissed
    var match: MatchResult?
    var jobID: UUID?

    var score: Int { match?.score ?? 0 }
    var conflicts: Int { match?.hardConflicts.count ?? 0 }

    init?(json d: [String: Any]) {
        let id = J.str(d, "id")
        guard !id.isEmpty, !J.str(d, "title").isEmpty else { return nil }
        self.id = id
        source = J.str(d, "source"); publisher = J.str(d, "publisher"); title = J.str(d, "title")
        company = J.str(d, "company"); location = J.str(d, "location"); url = J.str(d, "url")
        description = J.str(d, "description"); posted = J.str(d, "posted"); salary = J.str(d, "salary")
        experience = J.str(d, "experience"); firstSeen = J.str(d, "firstSeen")
        snippet = d["snippet"] as? Bool ?? true
    }
}

// MARK: - Settings

enum FeedSettings {
    static let defaultRepo = "ExpePine/Mac-Apps"
    static var repo: String {
        let r = UserDefaults.standard.string(forKey: "feedRepo") ?? ""
        return r.isEmpty ? defaultRepo : r
    }
    static var feedURL: URL? {
        URL(string: "https://github.com/\(repo)/releases/download/job-feed/jobs.json")
    }
    static var token: String { Keychain.load(account: "github-token") }

    static func register() {
        UserDefaults.standard.register(defaults: [
            "feedEnabled": true, "feedAIMatch": true, "feedAIPerDay": 200, "feedMinLocal": 45, "feedRecheck": true,
            "feedAutoAdd": false, "feedAutoAddScore": 80, "yearsExperience": 0
        ])
    }
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "feedEnabled") }
    static var aiMatch: Bool { UserDefaults.standard.bool(forKey: "feedAIMatch") }
    static var aiPerDay: Int { UserDefaults.standard.integer(forKey: "feedAIPerDay") }
    static var minLocal: Int { UserDefaults.standard.integer(forKey: "feedMinLocal") }
    static var autoAdd: Bool { UserDefaults.standard.bool(forKey: "feedAutoAdd") }
    static var autoAddScore: Int { UserDefaults.standard.integer(forKey: "feedAutoAddScore") }
    static var recheck: Bool { UserDefaults.standard.bool(forKey: "feedRecheck") }
    static var timeBudgetMinutesSetting: Int { UserDefaults.standard.integer(forKey: "feedTimeBudget") }
    static var timeBudgetMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: "feedTimeBudget")
        return v > 0 ? v : 60
    }
    /// Only re-check jobs that scored at least this well — low scorers won't change much.
    static var recheckMinScore: Int { 55 }

    /// Roles/locations last saved for the collector (used for local scoring).
    static var roles: [String] { UserDefaults.standard.stringArray(forKey: "feedRoles") ?? [] }
    static var locations: [String] { UserDefaults.standard.stringArray(forKey: "feedLocations") ?? [] }
}

// MARK: - Quick on-device fit estimate

enum MatchScorer {
    /// Total years of experience: your Settings value, else estimated from the earliest role in your Profile.
    static func years(_ p: Profile) -> Int {
        let set = UserDefaults.standard.integer(forKey: "yearsExperience")
        if set > 0 { return set }
        let thisYear = Calendar.current.component(.year, from: Date())
        let starts = p.roles.compactMap { r -> Int? in
            guard let m = r.start.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return nil }
            return Int(r.start[m])
        }
        guard let first = starts.min() else { return 0 }
        return max(0, thisYear - first)
    }

    /// "8-12 yrs", "10 to 15 years", "12+ years", "minimum 10 years"
    static func yearsRange(in text: String) -> (Int, Int)? {
        let t = text.lowercased()
        if let r = t.range(of: #"(\d{1,2})\s*(?:-|–|to)\s*(\d{1,2})\s*\+?\s*(?:yrs|years|yr|year)"#, options: .regularExpression) {
            let nums = t[r].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            if nums.count >= 2, nums[0] <= nums[1] { return (nums[0], nums[1]) }
        }
        if let r = t.range(of: #"(?:minimum|min\.?|at least|over)?\s*(\d{1,2})\s*\+\s*(?:yrs|years)"#, options: .regularExpression) {
            if let n = t[r].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init).first { return (n, n + 10) }
        }
        return nil
    }

    static func local(title: String, text: String, location: String, experience: String,
                      profile: Profile, stories: [Story]) -> MatchResult {
        var m = MatchResult()
        var hard: [String] = []
        var soft: [String] = []
        var strengths: [String] = []

        // Skills / domain overlap
        let mine = Prompts.words([profile.headline, profile.technicalSkills,
                                  profile.roles.map(\.title).joined(separator: " "),
                                  stories.map { $0.title + " " + $0.skills.joined(separator: " ") }.joined(separator: " ")]
            .joined(separator: " "))
        let jd = Prompts.words(title + " " + text)
        let overlap = jd.intersection(mine)
        let skill = min(1, Double(overlap.count) / Double(max(8, min(jd.count, 40)) ) * 1.6)
        if overlap.count >= 6 { strengths.append("Overlap: " + overlap.sorted().prefix(6).joined(separator: ", ")) }

        // Role/title fit vs the roles you search for (or your headline)
        let targets = FeedSettings.roles.isEmpty ? [profile.headline] + profile.roles.prefix(1).map(\.title) : FeedSettings.roles
        let titleWords = Prompts.words(title)
        let best = targets.map { t -> Double in
            let w = Prompts.words(t)
            return w.isEmpty ? 0 : Double(w.intersection(titleWords).count) / Double(w.count)
        }.max() ?? 0

        // Location
        var loc = 0.5
        let locText = location.lowercased()
        let wanted = FeedSettings.locations.map { $0.lowercased() }
        if !wanted.isEmpty && !locText.isEmpty {
            loc = wanted.contains { w in locText.contains(w) || (w == "remote" && (locText.contains("remote") || locText.contains("anywhere"))) } ? 1 : 0.15
            if loc < 0.5 { soft.append("Location: \(location)") }
        }

        // Experience
        var exp = 0.6
        let years = years(profile)
        if let (lo, hi) = yearsRange(in: experience + " " + text), years > 0 {
            if years >= lo && years <= hi + 2 { exp = 1; strengths.append("Experience \(lo)–\(hi) yrs fits your \(years)") }
            else if years < lo - 1 { exp = 0.1; hard.append("Asks for \(lo)+ years; you have about \(years)") }
            else if years > hi + 5 { exp = 0.3; hard.append("Pitched at \(lo)–\(hi) years; you have \(years)+ (likely too senior / pay band)") }
            else { exp = 0.6; soft.append("Experience range \(lo)–\(hi) yrs vs your \(years)") }
        }

        // Obvious seniority mismatch
        if years >= 8, title.range(of: #"\b(intern|trainee|fresher|junior|jr\.?|graduate|entry level)\b"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil {
            hard.append("Junior-level title")
        }

        let score = 40 * skill + 25 * best + 15 * loc + 20 * exp
        m.score = Int(min(100, max(0, hard.isEmpty ? score : min(score, 50))).rounded())
        m.hardConflicts = hard
        m.softGaps = soft
        m.strengths = strengths
        m.verdict = m.score >= 75 ? "Looks like a strong fit" : m.score >= 55 ? "Possible fit" : "Weak fit"
        m.why = "Quick estimate from keywords, title, location and experience. Run the AI check for a proper read."
        m.local = true
        return m
    }
}

extension Prompts {
    static func matchBatch(jobs: String, count: Int, profile: String, stories: String) -> String {
        """
        TASK: Judge how well the candidate fits EACH of the \(count) jobs below, like a sharp recruiter shortlisting. Be honest; don't flatter.

        Return: {"results": [{"i": 0, "score": 0-100, "verdict": "Strong fit | Good fit | Stretch | Poor fit",
                              "hardConflicts": ["likely deal-breakers"], "softGaps": ["gaps a story or note could cover"],
                              "strengths": ["best matching evidence"], "why": "max 25 words",
                              "company": "hiring company if the line shows '(company in text)', else ''",
                              "tags": ["role family", "domain", "seniority", "work mode"]}]}
        One result per job, using its [i]. Each list: at most 3 items, each at most 12 words. Keep it brief.
        tags: exactly 4 short tags — role family (e.g. Product Management, Program Management, Engineering, Hardware/Embedded, \
        AI/ML, Operations, Sales), domain (e.g. Fintech, IoT, Healthcare, SaaS, Consumer, Automotive, Biometrics), seniority \
        (Junior, Mid, Senior, Lead, Head/Director, VP+), work mode (Onsite, Hybrid, Remote, Unknown).

        CALIBRATION: 85+ = would shortlist, no hard conflicts. 70–84 good, minor gaps. 50–69 stretch. Any hard conflict caps \
        the score at 55. Hard conflict = a must-have the candidate clearly lacks or contradicts (mandatory degree/certification, \
        years far outside the range, a required domain they've never worked in, a different function). If something simply \
        isn't mentioned in the profile/stories, it's a soft gap, not a hard conflict.

        CANDIDATE PROFILE:
        \(profile)

        CANDIDATE STORIES (most relevant):
        \(stories)

        JOBS:
        \(jobs)
        """
    }

    static func match(title: String, company: String, location: String, description: String,
                      profile: Profile, stories: [Story], budget: Int) -> String {
        let prof = profileBlock(profile, maxChars: 1500)
        let jd = clip(description, max(1200, Int(Double(budget) * 0.4)))
        let storyList = storiesBlock(stories, relevantTo: title + " " + description, maxChars: max(1200, budget - prof.count - jd.count - 1500))
        return """
        TASK: Judge how well this candidate fits the job, like a sharp recruiter shortlisting for a call. \
        Be honest and specific; don't flatter.

        Return:
        {"score": 0-100, "verdict": "Strong fit | Good fit | Stretch | Poor fit",
         "hardConflicts": ["likely deal-breakers: a must-have the candidate clearly lacks or contradicts — mandatory degree/certification, years far outside the range, a required domain/industry they've never worked in, location/relocation impossibility, a different function altogether"],
         "softGaps": ["requirements not evidenced yet that a story, cover note or quick ramp-up could address"],
         "strengths": ["their strongest matching evidence, citing the story or role"],
         "why": "2 sentences: overall reasoning"}

        CALIBRATION: 85+ = would shortlist, no hard conflicts. 70–84 = good, minor gaps. 50–69 = stretch. \
        Any hard conflict caps the score at 55. Judge only from the profile and stories below; if something isn't mentioned, \
        treat it as a soft gap, not a hard conflict — unless the JD says it's mandatory.

        JOB: \(title) at \(company) — \(location)
        \(jd)

        CANDIDATE PROFILE:
        \(prof)

        CANDIDATE STORIES:
        \(storyList)
        """
    }
}

// MARK: - Engine

extension AppStore {

    var feed: [FeedJob] { data.feed ?? [] }

    func feedIndex(_ id: String) -> Int? { data.feed?.firstIndex { $0.id == id } }

    /// Downloads the collector's jobs.json and merges it (keeps your status, matches and links).
    func refreshFeed(manual: Bool = false) async {
        guard FeedSettings.enabled || manual, let url = FeedSettings.feedURL else { return }
        feedStatus = "Fetching job feed…"
        defer { if feedStatus == "Fetching job feed…" { feedStatus = nil } }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 60
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {
                feedError = "No job feed yet. Add API keys as GitHub secrets, then press Collect now (Settings ▸ Job Feed)."
                return
            }
            guard (200..<300).contains(code),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                feedError = "Couldn't read the job feed (HTTP \(code))."
                return
            }
            let items = J.dicts(obj, "items").compactMap(FeedJob.init(json:))
            let added = mergeFeed(items, owns: { $0.source != NaukriSheet.source })
            feedLastRefresh = Date()
            feedErrors = J.strings(obj, "errors")
            feedError = nil
            if manual || added > 0 { feedStatus = added > 0 ? "\(added) new job\(added == 1 ? "" : "s") in the feed" : "Feed is up to date" }
            scheduleFeedMatching()
        } catch {
            feedError = "Couldn't fetch the job feed: \(error.localizedDescription)"
        }
    }

    /// Adds new items, refreshes known ones, and forgets listings (from the same source) that have gone — unless you added them.
    @discardableResult
    func mergeFeed(_ items: [FeedJob], owns: (FeedJob) -> Bool) -> Int {
        var current = data.feed ?? []
        let known = Dictionary(current.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var added = 0
        for var it in items {
            if let i = known[it.id] {
                if it.description.count > current[i].description.count {
                    current[i].description = it.description
                    current[i].snippet = it.snippet
                }
            } else {
                it.match = MatchScorer.local(title: it.title, text: it.description, location: it.location,
                                             experience: it.experience, profile: data.profile, stories: data.stories)
                current.append(it)
                added += 1
            }
        }
        let live = Set(items.map(\.id))
        current.removeAll { owns($0) && !live.contains($0.id) && $0.status != "added" }
        data.feed = current
        return added
    }

    func startFeedTimer() {
        feedCheckTimer?.invalidate()
        feedCheckTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleFeedMatching() }
        }
        feedTimer?.invalidate()
        feedTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshFeed()
                await self?.refreshNaukriSheet()
                await self?.refreshGoogleSheets()
            }
        }
        Task {
            await refreshFeed()
            await refreshNaukriSheet()
            await refreshGoogleSheets()
        }
    }

    // MARK: Your Naukri sheet (rajakrishna.in/naukri)

    /// Pulls every page of your sheet (same data as "Sheet View") from your site, at most every 2 hours unless asked.
    func refreshNaukriSheet(manual: Bool = false) async {
        guard NaukriSheet.enabled, let url = URL(string: NaukriSheet.endpoint) else { return }
        if !manual, let last = naukriSheetLast, Date().timeIntervalSince(last) < 2 * 3600 { return }
        naukriSheetStatus = "Reading your Naukri sheet…"
        var items: [FeedJob] = []
        var page = 1, totalPages = 1, total = 0
        do {
            repeat {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 60
                req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                req.httpBody = "action=\(NaukriSheet.action)&page=\(page)".data(using: .utf8)
                let (d, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      (obj["success"] as? Bool) == true, let data = obj["data"] as? [String: Any] else {
                    throw GroqError(message: "Your Naukri sheet didn't answer as expected (HTTP \(code), page \(page)).")
                }
                totalPages = max(1, Int(J.str(data, "total_pages")) ?? 1)
                total = Int(J.str(data, "total_items")) ?? total
                items += J.dicts(data, "items").compactMap(NaukriSheet.feedJob)
                naukriSheetStatus = "Reading your Naukri sheet… page \(page) of \(totalPages)"
                page += 1
                if page <= totalPages { try await Task.sleep(nanoseconds: 300_000_000) }
            } while page <= totalPages && page <= 200
            // The sheet can list the same posting twice (e.g. under two categories) — keep one.
            var seen = Set<String>()
            items = items.filter { seen.insert($0.id).inserted }
            let added = mergeFeed(items, owns: { $0.source == NaukriSheet.source })
            naukriSheetLast = Date()
            naukriSheetCount = items.count
            naukriSheetStatus = "Naukri sheet: \(items.count) jobs\(added > 0 ? ", \(added) new" : "")"
            scheduleFeedMatching()
        } catch {
            naukriSheetStatus = "Naukri sheet: \(error.localizedDescription)"
        }
    }

    func rescoreFeedLocally() {
        guard var f = data.feed else { return }
        for i in f.indices where f[i].match?.local ?? true {
            f[i].match = MatchScorer.local(title: f[i].title, text: f[i].description, location: f[i].location,
                                           experience: f[i].experience, profile: data.profile, stories: data.stories)
        }
        data.feed = f
    }

    // MARK: AI fit check (top candidates only — saves your free quota)

    private var aiMatchesToday: Int {
        let key = "feedAIMatches." + ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        return UserDefaults.standard.integer(forKey: key)
    }
    private func countAIMatch() {
        let key = "feedAIMatches." + ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }

    /// Fingerprint of what the AI judges you on: which stories you have and your headline/roles.
    /// (Editing a story's wording doesn't trigger re-checks — adding or removing stories does.)
    var matchBasis: String {
        var s = data.profile.headline + "|" + data.profile.roles.map { $0.company + $0.title }.joined()
        for id in data.stories.map(\.id.uuidString).sorted() { s += "|" + String(id.prefix(8)) }
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    var feedChecksLeftToday: Int { max(0, FeedSettings.aiPerDay - aiMatchesToday) }
    var feedStaleCount: Int {
        let basis = matchBasis
        return feed.filter { $0.status != "dismissed" && $0.match?.local == false && $0.match?.basis != basis
                             && ($0.match?.score ?? 0) >= FeedSettings.recheckMinScore }.count
    }

    /// Jobs per minute the checker has actually achieved (moving average), or an estimate before the first batch.
    var feedThroughput: Double {
        if feedRate > 0 { return feedRate }
        let providers = ProviderSettings.usable.map(\.forBulk)
        return max(4, providers.reduce(0.0) { $0 + Double(Self.batchSize(for: $1)) * 1.5 })   // ~1.5 batches/min each
    }

    /// Minutes until the current queue is done at the measured speed.
    var feedETA: Int? {
        guard !feedMatchQueue.isEmpty else { return nil }
        return Int((Double(feedMatchQueue.count + feedInFlight.count) / feedThroughput).rounded(.up))
    }

    /// Queues AI fit checks: unchecked jobs (best quick score first), then re-checks of good matches judged on an older
    /// story set. The queue is capped so it finishes within your time budget (default 60 min) and the daily cap.
    func scheduleFeedMatching() {
        guard FeedSettings.aiMatch, ProviderSettings.anyKeyConfigured else { return }
        let budgetJobs = Int(feedThroughput * Double(FeedSettings.timeBudgetMinutes))
        let pending = feedMatchQueue.count + feedInFlight.count
        let room = max(0, min(FeedSettings.aiPerDay - aiMatchesToday, budgetJobs) - pending)
        guard room > 0 else { startFeedWorkers(); return }
        let basis = matchBasis
        let busy = Set(feedMatchQueue).union(feedInFlight)
        let live = feed.filter { $0.status != "dismissed" && $0.appliedAt == nil && !busy.contains($0.id) }
        // Same title + company listed twice (e.g. two sources) → check once.
        var seenKeys = Set<String>()
        let unchecked = live
            .filter { ($0.match?.local ?? true) && $0.score >= FeedSettings.minLocal && $0.conflicts == 0 }
            .sorted { ($0.liked == true ? 1 : 0, $0.score) > ($1.liked == true ? 1 : 0, $1.score) }
            .filter { seenKeys.insert(Self.norm($0.title) + "|" + Self.norm($0.company)).inserted }
        let stale = FeedSettings.recheck
            ? live.filter { $0.match?.local == false && $0.match?.basis != basis && ($0.match?.score ?? 0) >= FeedSettings.recheckMinScore }
                  .sorted { $0.score > $1.score }
            : []
        feedMatchQueue += (unchecked + stale).prefix(room).map(\.id)
        feedQueueSkipped = max(0, unchecked.count + stale.count - room)
        startFeedWorkers()
    }

    func queueFeedMatch(_ id: String) {
        if !feedMatchQueue.contains(id) && !feedInFlight.contains(id) { feedMatchQueue.insert(id, at: 0) }
        startFeedWorkers()
    }

    /// Jobs per request for a provider. JDs are sent as short digests (~700 chars), so batches can be large.
    static func batchSize(for p: ProviderConfig) -> Int {
        min(25, max(3, (AIClient.tpmLimit(for: p) - 2500) / 450))
    }

    /// One worker per AI provider, all pulling from the same queue — providers run in parallel.
    func startFeedWorkers() {
        guard !feedMatchQueue.isEmpty else { return }
        for p in ProviderSettings.usable.map(\.forBulk) where feedWorkers[p.kind] == nil {
            feedWorkers[p.kind] = Task { @MainActor [weak self] in
                await self?.runFeedWorker(p)
                self?.feedWorkers[p.kind] = nil
                if self?.feedWorkers.isEmpty == true { self?.feedWorkerFinished() }
            }
        }
    }

    private func feedWorkerFinished() {
        if feedStatus?.hasPrefix("Checking fit") == true || feedStatus?.hasPrefix("Per-minute") == true { feedStatus = nil }
        if !feedDailyStop { scheduleFeedMatching() }
    }

    private func runFeedWorker(_ p: ProviderConfig) async {
        while !feedMatchQueue.isEmpty && !feedDailyStop {
            let n = Self.batchSize(for: p)
            let ids = Array(feedMatchQueue.prefix(n))
            feedMatchQueue.removeFirst(ids.count)
            feedInFlight.formUnion(ids)
            let jobs = ids.compactMap { id in feedIndex(id).map { feed[$0] } }
            feedStatus = "Checking fit: \(feedInFlight.count) jobs in progress"
            let started = Date()
            do {
                let results = try await aiMatchBatch(jobs, provider: p)
                for (id, m, company, tags) in results {
                    if let k = feedIndex(id) {
                        data.feed?[k].match = m
                        if data.feed?[k].company.isEmpty == true, !company.isEmpty { data.feed?[k].company = company }
                        if !tags.isEmpty { data.feed?[k].tags = tags }
                    }
                    feedChecksDone += 1
                    countAIMatch()
                    autoAddIfStrong(id)
                }
                let perMin = Double(results.count) / max(0.2, Date().timeIntervalSince(started) / 60)
                feedRate = feedRate == 0 ? perMin * Double(max(1, feedWorkers.count)) : feedRate * 0.7 + perMin * Double(max(1, feedWorkers.count)) * 0.3
                feedInFlight.subtract(ids)
            } catch is AIClient.RateLimited {
                feedInFlight.subtract(ids)
                feedMatchQueue.insert(contentsOf: ids, at: 0)
                feedStatus = "\(p.kind.title): per-minute limit — continuing in a minute"
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                feedInFlight.subtract(ids)
                if error.localizedDescription.contains(AppStore.quotaMarker) {
                    // This provider is out for the day; others keep going.
                    feedMatchQueue.insert(contentsOf: ids, at: 0)
                    if feedWorkers.count <= 1 {
                        feedStatus = "Daily AI quota used up — fit checks resume tomorrow (or add another provider)"
                        feedDailyStop = true
                    }
                    return
                }
                // Skip this batch rather than loop on it.
            }
        }
    }

    /// Short version of a JD for bulk checks: the lines that carry requirements, ~700 characters.
    static func digest(_ jd: String, limit: Int = 700) -> String {
        let lines = jd.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 }
        let key = #"(?i)\b(\d+\s*\+?\s*(yrs|years)|experience|require|must|mandatory|qualification|degree|b\.?tech|b\.?e\b|m\.?tech|mba|skills?|responsib|lead|own|manage|hardware|firmware|embedded|iot|ai|ml|product|program|roadmap|stakeholder|domain|industry|location|relocat|remote|hybrid)"#
        var out = lines.prefix(2).joined(separator: " · ")
        for l in lines.dropFirst(2) where out.count < limit {
            if l.range(of: key, options: .regularExpression) != nil { out += " · " + l }
        }
        return Prompts.clip(out, limit)
    }

    /// One AI request judges several jobs (short JD digests; your profile and most relevant stories sent once).
    /// Also returns the company (when missing) and classification tags for each job.
    func aiMatchBatch(_ jobs: [FeedJob], provider: ProviderConfig? = nil) async throws -> [(String, MatchResult, String, [String])] {
        let profile = data.profile, stories = data.stories
        let n = jobs.count
        let o = try await ask(output: 170 * n + 300, temperature: 0.2, only: provider.map { [$0] }) { budget in
            let prof = Prompts.profileBlock(profile, maxChars: 1000)
            let context = jobs.map { $0.title + " " + Self.digest($0.description, limit: 400) }.joined(separator: " ")
            let storyList = Prompts.storiesBlock(stories, relevantTo: context, maxChars: min(3500, max(1200, budget / 6)))
            let per = max(350, min(900, (budget - prof.count - storyList.count - 2800) / max(1, n) - 120))
            let list = jobs.enumerated().map { i, f in
                "[\(i)] \(f.title) — \(f.company.isEmpty ? "(company in text)" : f.company) — \(f.location)\(f.experience.isEmpty ? "" : " — " + f.experience)\n\(Self.digest(f.description, limit: per))"
            }.joined(separator: "\n\n")
            return Prompts.matchBatch(jobs: list, count: n, profile: prof, stories: storyList)
        }
        let basis = matchBasis
        var out: [(String, MatchResult, String, [String])] = []
        for r in J.dicts(o, "results") {
            guard let i = Int(J.str(r, "i")), jobs.indices.contains(i) else { continue }
            var m = MatchResult()
            m.score = min(100, max(0, Int(J.str(r, "score")) ?? 0))
            m.verdict = J.str(r, "verdict")
            m.hardConflicts = J.strings(r, "hardConflicts")
            m.softGaps = J.strings(r, "softGaps")
            m.strengths = J.strings(r, "strengths")
            m.why = J.str(r, "why")
            if !m.hardConflicts.isEmpty { m.score = min(m.score, 55) }
            m.local = false
            m.basis = basis
            out.append((jobs[i].id, m, J.str(r, "company"), J.strings(r, "tags")))
        }
        return out
    }

    func aiMatch(title: String, company: String, location: String, description: String) async throws -> MatchResult {
        let profile = data.profile, stories = data.stories
        let o = try await ask(output: 900, temperature: 0.2) { budget in
            Prompts.match(title: title, company: company, location: location, description: description,
                          profile: profile, stories: stories, budget: max(3000, budget - 1800))
        }
        var m = MatchResult()
        m.score = min(100, max(0, Int(J.str(o, "score")) ?? 0))
        m.verdict = J.str(o, "verdict")
        m.hardConflicts = J.strings(o, "hardConflicts")
        m.softGaps = J.strings(o, "softGaps")
        m.strengths = J.strings(o, "strengths")
        m.why = J.str(o, "why")
        if !m.hardConflicts.isEmpty { m.score = min(m.score, 55) }
        m.local = false
        m.basis = matchBasis
        return m
    }

    /// Fit check for a job already in your Jobs list (part of background processing).
    func matchJob(_ id: UUID) async throws {
        guard let i = jobIndex(id) else { return }
        let j = data.jobs[i]
        let m = try await aiMatch(title: j.title, company: j.company, location: j.location, description: j.description)
        if let k = jobIndex(id) { data.jobs[k].match = m }
    }

    private func autoAddIfStrong(_ id: String) {
        guard FeedSettings.autoAdd, let i = feedIndex(id), let m = feed[i].match, !m.local,
              m.score >= FeedSettings.autoAddScore, m.hardConflicts.isEmpty, feed[i].status == "new" else { return }
        addFeedJobToJobs(id)
    }

    /// Moves a feed job into Jobs (and the background steps). The match result comes along.
    @discardableResult
    func addFeedJobToJobs(_ id: String, process: Bool = true) -> UUID? {
        guard let i = feedIndex(id) else { return nil }
        let f = feed[i]
        if let existing = f.jobID, jobIndex(existing) != nil { return existing }
        let keys = Set(Self.jobKeys(url: f.url, title: f.title, company: f.company))
        if let dupe = data.jobs.first(where: { !keys.isDisjoint(with: Self.jobKeys(url: $0.url, title: $0.title, company: $0.company)) }) {
            data.feed?[i].status = "added"
            data.feed?[i].jobID = dupe.id
            return dupe.id
        }
        var j = JobPosting()
        j.source = f.publisher.isEmpty ? f.source : f.publisher.lowercased()
        j.url = f.url; j.title = f.title; j.company = f.company; j.location = f.location
        j.experience = f.experience; j.salary = f.salary; j.description = f.description
        j.rawText = f.description
        j.parsed = !f.snippet && f.description.count > 600
        j.match = f.match?.local == false ? f.match : nil
        j.feedKey = f.id
        j.capturedAt = Date()
        data.jobs.insert(j, at: 0)
        data.feed?[i].status = "added"
        data.feed?[i].jobID = j.id
        updateDockBadge()
        if process && autoProcessEnabled { enqueueAuto(j.id) }
        return j.id
    }

    // MARK: Apply

    /// Opens the posting's link (from your sheet / the source) to apply, and records it:
    /// the job goes into Jobs as Applied, with a done "Applied" action and a follow-up in 5 days.
    func applyFeedJob(_ id: String) {
        guard let i = feedIndex(id) else { return }
        let f = feed[i]
        if let url = URL(string: f.url), !f.url.isEmpty { NSWorkspace.shared.open(url) }
        guard f.appliedAt == nil else { return }
        let jobID = addFeedJobToJobs(id, process: false)
        markApplied(jobID: jobID, feedID: id, company: f.company, title: f.title, url: f.url, via: f.publisher.isEmpty ? f.source : f.publisher)
    }

    func applyJob(_ jobID: UUID) {
        guard let j = data.jobs.first(where: { $0.id == jobID }) else { return }
        if let url = URL(string: j.url), !j.url.isEmpty { NSWorkspace.shared.open(url) }
        guard j.appliedAt == nil else { return }
        markApplied(jobID: jobID, feedID: j.feedKey, company: j.company, title: j.title, url: j.url, via: j.source)
    }

    private func markApplied(jobID: UUID?, feedID: String?, company: String, title: String, url: String, via _: String) {
        let now = Date()
        if let fid = feedID, let k = feedIndex(fid) { data.feed?[k].appliedAt = now }
        if let jid = jobID, let k = jobIndex(jid) { data.jobs[k].appliedAt = now }
        var done = ActionItem()
        done.kind = "apply"; done.text = "Applied"; done.title = "Applied to \(title)\(company.isEmpty ? "" : " at \(company)")"
        done.jobID = jobID; done.company = company; done.pageURL = url
        done.status = "done"; done.doneAt = now; done.enriched = true
        var follow = ActionItem()
        follow.kind = "custom"; follow.text = "Follow up on application"
        follow.title = "Follow up: \(title)\(company.isEmpty ? "" : " at \(company)")"
        follow.jobID = jobID; follow.company = company; follow.pageURL = url
        follow.due = Calendar.current.date(byAdding: .day, value: 5, to: now).flatMap { Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: $0) }
        follow.dueText = "5 days after applying"; follow.enriched = true
        var list = data.actions ?? []
        list.insert(contentsOf: [follow, done], at: 0)
        data.actions = list
        scheduleCommentary()
        if let jid = jobID, Self.autoFindOnApply, !WebSearch.usable.isEmpty {
            Task { @MainActor in
                do { try await self.findPeople(jobID: jid) }
                catch { self.peopleSearchStatus = nil }
            }
        }
    }

    // MARK: GitHub (save your search, run the collector)

    func githubRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        guard let url = URL(string: "https://api.github.com/repos/\(FeedSettings.repo)/\(path)") else { throw GroqError(message: "Bad repo name") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let token = FeedSettings.token
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:])
    }

    /// Reads JobCollector/config.json from the repo.
    func loadCollectorConfig() async throws -> [String: Any] {
        let (code, o) = try await githubRequest("contents/JobCollector/config.json")
        guard code == 200, let b64 = o["content"] as? String,
              let d = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")),
              let cfg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw GroqError(message: "Couldn't read the collector settings from GitHub (HTTP \(code)).")
        }
        return cfg
    }

    /// Writes your search to JobCollector/config.json (this also starts a collection run).
    func saveCollectorConfig(_ updates: [String: Any]) async throws {
        guard !FeedSettings.token.isEmpty else {
            throw GroqError(message: "Add a GitHub token first (Settings ▸ Job Feed). It needs Contents: Read and write and Actions: Read and write on \(FeedSettings.repo).")
        }
        let (code, o) = try await githubRequest("contents/JobCollector/config.json")
        guard code == 200, let sha = o["sha"] as? String, let b64 = o["content"] as? String,
              let d = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")),
              var cfg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw GroqError(message: "Couldn't read the current collector settings (HTTP \(code)). Check the token and repo.")
        }
        for (k, v) in updates { cfg[k] = v }
        let out = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
        let (put, resp) = try await githubRequest("contents/JobCollector/config.json", method: "PUT", body: [
            "message": "Job collector: update search from ResumeForge",
            "content": out.base64EncodedString(),
            "sha": sha
        ])
        guard (200..<300).contains(put) else {
            throw GroqError(message: "GitHub refused the update (HTTP \(put)): \(resp["message"] as? String ?? "")")
        }
    }

    func runCollectorNow() async throws {
        guard !FeedSettings.token.isEmpty else {
            throw GroqError(message: "Add a GitHub token first (Settings ▸ Job Feed).")
        }
        let (code, resp) = try await githubRequest("actions/workflows/job-collector.yml/dispatches", method: "POST", body: ["ref": "main"])
        guard code == 204 else {
            throw GroqError(message: "Couldn't start the collector (HTTP \(code)): \(resp["message"] as? String ?? "")")
        }
    }
}

/// Your own job list at rajakrishna.in/naukri ("Sheet View"), read through the site's fetch_stored_jobs endpoint.
enum NaukriSheet {
    static let source = "naukri-sheet"
    static let defaultEndpoint = "https://rajakrishna.in/wp-admin/admin-ajax.php"
    static let action = "fetch_stored_jobs"

    static var enabled: Bool { UserDefaults.standard.object(forKey: "naukriSheetEnabled") as? Bool ?? true }
    static var endpoint: String {
        let e = UserDefaults.standard.string(forKey: "naukriSheetURL") ?? ""
        return e.isEmpty ? defaultEndpoint : e
    }

    /// Stable id from the Naukri link (falls back to company + designation).
    static func id(_ link: String, _ company: String, _ title: String) -> String {
        let key = AppStore.urlKey(link).isEmpty ? AppStore.norm(company + " " + title) : AppStore.urlKey(link)
        var h: UInt64 = 0xcbf29ce484222325           // FNV-1a
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "nk-" + String(h, radix: 16)
    }

    static func feedJob(_ d: [String: Any]) -> FeedJob? {
        let title = J.str(d, "designation"), company = J.str(d, "company")
        guard !title.isEmpty else { return nil }
        let link = J.str(d, "link")
        var f = FeedJob(json: ["id": id(link, company, title), "title": title])!
        f.source = source
        f.publisher = "Naukri"
        f.company = company
        f.location = J.str(d, "location")
        f.experience = J.str(d, "experience")
        f.url = link
        let jd = J.str(d, "jd"), about = J.str(d, "about")
        f.description = [jd, about].filter { !$0.isEmpty }.joined(separator: "\n\n")
        f.snippet = jd.count < 400
        f.posted = J.str(d, "date")
        f.firstSeen = ISO8601DateFormatter().string(from: Date())
        let cat = J.str(d, "pos").replacingOccurrences(of: "-", with: " ")
        f.category = cat.isEmpty ? nil : cat
        return f
    }
}
