import AppKit
import SwiftUI

/// Jobs collected on GitHub, ranked by how well they fit you (with conflicts called out).
struct FeedView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: String?
    @State private var search = ""
    @State private var hideDismissed = true
    @State private var noConflictsOnly = false
    @State private var sourceFilter = "all"
    @AppStorage("feedSort") private var sortMode = "best"
    @AppStorage("feedHideApplied") private var hideApplied = false

    private var items: [FeedJob] {
        let q = search.lowercased()
        return store.feed
            .filter { !hideDismissed || $0.status != "dismissed" }
            .filter { !hideApplied || $0.appliedAt == nil }
            .filter { !noConflictsOnly || $0.conflicts == 0 }
            .filter { f in
                if sourceFilter == "all" { return true }
                if sourceFilter.hasPrefix("cat:") { return f.category == String(sourceFilter.dropFirst(4)) }
                return f.source == sourceFilter
            }
            .filter { q.isEmpty || ($0.title + " " + $0.company + " " + $0.location).lowercased().contains(q) }
            .sorted { a, b in
                // Re-sorted live: as background AI checks finish, jobs move to their new place.
                switch sortMode {
                case "newest":
                    return a.firstSeen != b.firstSeen ? a.firstSeen > b.firstSeen : a.score > b.score
                case "company":
                    return a.company.localizedCaseInsensitiveCompare(b.company) == .orderedAscending
                case "checked":
                    let ak = (a.match?.local ?? true) ? 0 : 1, bk = (b.match?.local ?? true) ? 0 : 1
                    if ak != bk { return ak > bk }
                    return a.score > b.score
                default:   // best match
                    return a.score != b.score ? a.score > b.score : a.firstSeen > b.firstSeen
                }
            }
    }

    private var sources: [String] { Array(Set(store.feed.map(\.source))).sorted() }
    private var categories: [String] { Array(Set(store.feed.compactMap(\.category))).sorted() }

    private func sourceName(_ s: String) -> String {
        if s == NaukriSheet.source { return "My Naukri sheet" }
        if let src = SheetSettings.sources.first(where: { $0.sourceKey == s }) { return "Sheet: \(src.label)" }
        return s
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                List(selection: $selected) {
                    ForEach(items) { f in
                        FeedRow(job: f).tag(f.id)
                            .contextMenu {
                                Button("Apply (open link)") { store.applyFeedJob(f.id) }.disabled(f.url.isEmpty)
                                Button("Add to my Jobs") { store.addFeedJobToJobs(f.id) }
                                Button("Check fit with AI") { store.queueFeedMatch(f.id) }
                                Divider()
                                Button(f.status == "dismissed" ? "Restore" : "Dismiss") { toggleDismiss(f.id) }
                            }
                    }
                }
                .searchable(text: $search, placement: .sidebar, prompt: "Search feed")
                Divider()
                HStack {
                    Toggle("Hide dismissed", isOn: $hideDismissed)
                    Toggle("Hide applied", isOn: $hideApplied)
                    Toggle("No conflicts", isOn: $noConflictsOnly)
                    Spacer()
                    Picker("", selection: $sourceFilter) {
                        Text("All sources").tag("all")
                        ForEach(sources, id: \.self) { Text(sourceName($0)).tag($0) }
                        if !categories.isEmpty {
                            Divider()
                            ForEach(categories, id: \.self) { Text("Category: \($0)").tag("cat:" + $0) }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(8)
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)

            Group {
                if let id = selected, let f = store.feed.first(where: { $0.id == id }) {
                    FeedDetail(job: f).id(id)
                } else if store.feed.isEmpty && store.naukriSheetStatus?.hasPrefix("Reading") == true {
                    VStack(spacing: 10) { ProgressView(); Text(store.naukriSheetStatus ?? "") }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.feed.isEmpty {
                    FeedEmptyState()
                } else {
                    EmptyHint(icon: "list.star", title: "Pick a job", message: "Best matches are at the top. Jobs the AI has checked show a solid score; quick estimates show a dashed one.")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Job Feed").font(.headline)
                Spacer()
                Picker("Sort", selection: $sortMode) {
                    Text("Best match").tag("best")
                    Text("AI-checked first").tag("checked")
                    Text("Newest").tag("newest")
                    Text("Company A–Z").tag("company")
                }
                .labelsHidden()
                .frame(width: 140)
                .help("The list re-sorts by itself as background fit checks finish")
                Button {
                    Task {
                        await store.refreshFeed(manual: true)
                        await store.refreshNaukriSheet(manual: true)
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Fetch the latest feed and your Naukri sheet")
                Button("Collect now") {
                    store.run("Starting the GitHub collector…") {
                        try await store.runCollectorNow()
                        store.feedStatus = "Collector started on GitHub — new jobs appear in a few minutes."
                    }
                }
                .help("Runs the job collector on GitHub right away")
            }
            if let s = store.feedStatus {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if let t = store.feedLastRefresh {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened)) · \(store.feed.count) jobs")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let s = store.naukriSheetStatus {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let s = store.sheetsStatus {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(s)
            }
            BackgroundCheckStatus()
            if let e = store.feedError, store.feed.isEmpty || !e.hasPrefix("No job feed yet") {
                Text(e).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            if !store.feedErrors.isEmpty {
                Text("Collector warnings: " + store.feedErrors.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .help(store.feedErrors.joined(separator: "\n"))
            }
        }
        .padding(10)
    }

    private func toggleDismiss(_ id: String) {
        guard let i = store.feedIndex(id) else { return }
        store.data.feed?[i].status = store.feed[i].status == "dismissed" ? "new" : "dismissed"
    }
}

struct ScoreBadge: View {
    let match: MatchResult?
    var body: some View {
        let s = match?.score ?? 0
        let local = match?.local ?? true
        let color: Color = (match?.hardConflicts.isEmpty == false) ? .red : s >= 75 ? .green : s >= 55 ? .orange : .gray
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(s) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: local ? [2, 3] : []))
                .rotationEffect(.degrees(-90))
            Text("\(s)").font(.system(size: 11, weight: .bold).monospacedDigit())
        }
        .frame(width: 34, height: 34)
        .help(local ? "Quick estimate — not yet checked by AI" : (match?.verdict ?? ""))
    }
}

struct FeedRow: View {
    let job: FeedJob
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScoreBadge(match: job.match)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Text(job.title).font(.headline).lineLimit(2)
                    Spacer(minLength: 4)
                    if job.liked == true { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
                }
                Text([job.company, job.location].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(job.classTags.prefix(3).joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                HStack(spacing: 6) {
                    Pill(text: job.publisher.isEmpty ? job.source : job.publisher, color: job.source == NaukriSheet.source ? .blue : .gray)
                    if let c = job.category { Pill(text: c, color: .purple) }
                    if job.conflicts > 0 { Pill(text: "\(job.conflicts) conflict\(job.conflicts == 1 ? "" : "s")", color: .red) }
                    if job.appliedAt != nil { Pill(text: "applied", color: .green) }
                    else if job.status == "added" { Pill(text: "in Jobs", color: .green) }
                    if job.status == "dismissed" { Pill(text: "dismissed", color: .gray) }
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(job.status == "dismissed" ? 0.5 : 1)
    }
}

struct MatchCard: View {
    let match: MatchResult
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ScoreBadge(match: match)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.verdict.isEmpty ? "Fit" : match.verdict).font(.headline)
                    Text(match.local ? "Quick estimate (keywords, title, location, experience)" : "AI fit check against your stories")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !match.hardConflicts.isEmpty {
                section("Conflicts", match.hardConflicts, "xmark.octagon.fill", .red)
            }
            if !match.softGaps.isEmpty {
                section("Gaps you could address", match.softGaps, "exclamationmark.triangle.fill", .orange)
            }
            if !match.strengths.isEmpty {
                section("Strengths", match.strengths, "checkmark.circle.fill", .green)
            }
            if !match.why.isEmpty { Text(match.why).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func section(_ title: String, _ items: [String], _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).font(.callout.bold()).foregroundStyle(color)
            ForEach(items, id: \.self) { Text("• " + $0).font(.callout) }
        }
    }
}

struct FeedDetail: View {
    @EnvironmentObject var store: AppStore
    let job: FeedJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title).font(.title2.bold())
                    Text([job.company, job.location, job.experience, job.salary].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .foregroundStyle(.secondary)
                    Text("via \(job.publisher.isEmpty ? job.source : job.publisher)\(job.posted.isEmpty ? "" : " · posted \(job.posted.prefix(10))")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                HStack {
                    if let applied = job.appliedAt {
                        Label("Applied \(applied.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    } else if !job.url.isEmpty {
                        Button { store.applyFeedJob(job.id) } label: { Label("Apply", systemImage: "paperplane.fill") }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .help("Opens the \(job.publisher.isEmpty ? "job" : job.publisher) link to apply, and tracks it: Jobs ▸ Applied, plus a follow-up action in 5 days")
                    }
                    if job.status == "added", let jid = job.jobID {
                        Button { store.section = .jobs; store.selectedJobID = jid } label: { Label("Open in Jobs", systemImage: "briefcase") }
                    } else {
                        Button { if let id = store.addFeedJobToJobs(job.id) { store.selectedJobID = id } } label: {
                            Label("Add to my Jobs", systemImage: "plus.circle")
                        }
                        .help("Adds it to Jobs, where the background steps write your resume")
                    }
                    if let url = URL(string: job.url), !job.url.isEmpty, job.appliedAt != nil {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open posting", systemImage: "safari") }
                    }
                    Button { store.toggleLike(feedID: job.id) } label: {
                        Label(job.liked == true ? "Liked" : "Like", systemImage: job.liked == true ? "heart.fill" : "heart")
                    }
                    .help("Keep this JD in Saved JDs (auto-classified)")
                    Button {
                        let j = job
                        store.run("Writing lines for \(j.title)…") {
                            _ = try await store.linesFor(title: j.title, company: j.company, jd: j.description, jobID: j.jobID, feedID: j.id)
                            store.section = .lines
                        }
                    } label: { Label("Lines", systemImage: "text.quote") }
                    .help("Write reusable resume bullets, a summary line and openers for this JD, from your stories")
                    Button { store.findPeopleForFeed(job.id) } label: { Label("Find people", systemImage: "person.2.wave.2") }
                        .help("Find the hiring manager, recruiters and leaders at \(job.company) on LinkedIn")
                    Button { store.queueFeedMatch(job.id) } label: { Label(job.match?.local == false ? "Re-check" : "Check fit", systemImage: "sparkles") }
                        .disabled(store.feedMatchQueue.contains(job.id) || store.feedInFlight.contains(job.id))
                        .help("Runs in the background — keep browsing")
                    Spacer()
                    Button(job.status == "dismissed" ? "Restore" : "Dismiss") {
                        if let i = store.feedIndex(job.id) {
                            store.data.feed?[i].status = job.status == "dismissed" ? "new" : "dismissed"
                        }
                    }
                }
                Text(job.classTags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if store.feedInFlight.contains(job.id) {
                    HStack { ProgressView().controlSize(.small); Text("Checking fit with AI…").font(.callout) }
                } else if store.feedMatchQueue.contains(job.id) {
                    Label("Queued for a background fit check", systemImage: "clock").font(.callout).foregroundStyle(.secondary)
                } else if let m = job.match, !m.local, m.basis != store.matchBasis {
                    Label("Your stories changed since this check — it'll be re-checked in the background", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let m = job.match { MatchCard(match: m) }
                Divider()
                if job.snippet {
                    Label("This source only provides a snippet. Open the posting for the full JD; on Naukri and Wellfound, the extension captures it.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(job.description.isEmpty ? "No description." : job.description)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
        }
    }
}

struct FeedEmptyState: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up the job collector").font(.title2.bold())
            Text("A GitHub workflow in \(FeedSettings.repo) collects jobs for your roles and locations three times a day. The app ranks them by fit.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Get free API keys: Adzuna, Jooble and/or JSearch (RapidAPI). For Naukri/Wellfound, turn on their job-alert emails and use an email app password.")
                Text("2. Add them as GitHub secrets: ADZUNA_APP_ID, ADZUNA_APP_KEY, JOOBLE_KEY, RAPIDAPI_KEY, IMAP_HOST, IMAP_USER, IMAP_PASSWORD.")
                Text("3. In Settings ▸ Job Feed, set your roles and locations, add a GitHub token, and press Save search.")
            }
            .font(.callout)
            HStack {
                if let u = URL(string: "https://github.com/\(FeedSettings.repo)/settings/secrets/actions") {
                    Link("Open GitHub secrets", destination: u)
                }
                Button("Fetch feed") { Task { await store.refreshFeed(manual: true) } }
            }
            if let e = store.feedError { Text(e).font(.callout).foregroundStyle(.orange) }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: - Settings ▸ Job Feed

struct FeedSettingsView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("feedEnabled") private var enabled = true
    @AppStorage("feedRepo") private var repo = FeedSettings.defaultRepo
    @AppStorage("feedAIMatch") private var aiMatch = true
    @AppStorage("feedAIPerDay") private var aiPerDay = 200
    @AppStorage("feedRecheck") private var recheck = true
    @AppStorage("feedTimeBudget") private var timeBudget = 60
    @AppStorage("feedMinLocal") private var minLocal = 45
    @AppStorage("feedAutoAdd") private var autoAdd = false
    @AppStorage("feedAutoAddScore") private var autoAddScore = 80
    @AppStorage("yearsExperience") private var years = 0
    @AppStorage("naukriSheetEnabled") private var sheetEnabled = true
    @AppStorage("naukriSheetURL") private var sheetURL = ""

    @State private var token = ""
    @State private var roles = ""
    @State private var locations = ""
    @State private var exclude = ""
    @State private var rssFeeds = ""
    @State private var maxAge = 7
    @State private var srcAdzuna = true
    @State private var srcJooble = true
    @State private var srcJSearch = true
    @State private var srcEmail = true
    @State private var mailNaukri = true
    @State private var mailWellfound = true
    @State private var mailLinkedIn = false
    @State private var status = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Use the job feed", isOn: $enabled)
                TextField("GitHub repo", text: $repo)
                SecureField("GitHub token", text: $token, prompt: Text("Fine-grained token: Contents + Actions read/write on this repo"))
                    .onSubmit { Keychain.save(token, account: "github-token") }
                HStack {
                    Button("Save token") { Keychain.save(token, account: "github-token"); status = "Token saved to Keychain." }
                    if let u = URL(string: "https://github.com/settings/personal-access-tokens/new") { Link("Create a token", destination: u) }
                    if let u = URL(string: "https://github.com/\(repo)/settings/secrets/actions") { Link("API-key secrets", destination: u) }
                }
            } header: {
                Text("GitHub collector")
            } footer: {
                Text("\(repo) is public, so your search terms and the collected listings are visible to anyone. Your API keys stay secret: GitHub never shows secrets, even in public repos.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SheetSourcesSection()

            Section {
                Toggle("Include my Naukri sheet (rajakrishna.in/naukri)", isOn: $sheetEnabled)
                TextField("Endpoint", text: $sheetURL, prompt: Text(NaukriSheet.defaultEndpoint))
                    .font(.callout.monospaced())
                HStack {
                    Button("Fetch now") { Task { await store.refreshNaukriSheet(manual: true) } }
                    if let s = store.naukriSheetStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("My Naukri sheet")
            } footer: {
                Text("Reads the same jobs as Sheet View on your page (full JD, company, experience, Naukri link). It's fetched from your Mac when the app opens and every 2 hours, then merged into the Job Feed and scored like everything else.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What to search") {
                LabeledContent("Roles (one per line)") {
                    TextEditor(text: $roles).frame(height: 70).font(.callout)
                }
                LabeledContent("Locations (one per line; \"Remote\" works)") {
                    TextEditor(text: $locations).frame(height: 54).font(.callout)
                }
                TextField("Exclude titles containing (comma-separated)", text: $exclude)
                Stepper("Only jobs posted in the last \(maxAge) days", value: $maxAge, in: 1...30)
                Toggle("Adzuna", isOn: $srcAdzuna)
                Toggle("Jooble", isOn: $srcJooble)
                Toggle("JSearch (Google for Jobs via RapidAPI)", isOn: $srcJSearch)
                Toggle("Job-alert emails", isOn: $srcEmail)
                if srcEmail {
                    HStack {
                        Toggle("Naukri", isOn: $mailNaukri)
                        Toggle("Wellfound", isOn: $mailWellfound)
                        Toggle("LinkedIn", isOn: $mailLinkedIn)
                    }
                    .toggleStyle(.checkbox)
                }
                LabeledContent("RSS/Atom feeds (one URL per line)") {
                    TextEditor(text: $rssFeeds).frame(height: 44).font(.callout.monospaced())
                }
                HStack {
                    Button("Load from GitHub") { Task { await load() } }
                    Button("Save search") { Task { await save() } }.buttonStyle(.borderedProminent)
                    Button("Collect now") {
                        Task {
                            do { try await store.runCollectorNow(); status = "Collector started — new jobs appear in a few minutes." }
                            catch { status = error.localizedDescription }
                        }
                    }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }

            Section {
                Stepper("Your total experience: \(years == 0 ? "from Profile (\(MatchScorer.years(store.data.profile)) yrs)" : "\(years) yrs")",
                        value: $years, in: 0...45)
                Toggle("Check the best matches with AI", isOn: $aiMatch)
                Stepper("Up to \(aiPerDay) AI fit checks a day", value: $aiPerDay, in: 0...500, step: 10).disabled(!aiMatch)
                Toggle("Re-check good matches (55+) when I add or remove stories", isOn: $recheck).disabled(!aiMatch)
                Stepper("Finish each round of checks within \(timeBudget) minutes", value: $timeBudget, in: 10...240, step: 10).disabled(!aiMatch)
                Stepper("Only if the quick score is at least \(minLocal)", value: $minLocal, in: 0...90, step: 5).disabled(!aiMatch)
                Toggle("Add strong matches to Jobs automatically", isOn: $autoAdd)
                Stepper("…when the AI scores \(autoAddScore)+ with no conflicts", value: $autoAddScore, in: 50...95, step: 5).disabled(!autoAdd)
                Button("Re-score feed") { store.rescoreFeedLocally() }
            } header: {
                Text("Matching")
            } footer: {
                Text("Every job gets a free quick score on your Mac. Only the top ones use your AI quota for a proper fit check (score, conflicts, gaps). Jobs you add go through the background steps to your resume.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            token = FeedSettings.token
            if !loaded { loaded = true; Task { await load() } }
        }
    }

    private func lines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func load() async {
        do {
            let c = try await store.loadCollectorConfig()
            roles = J.strings(c, "roles").joined(separator: "\n")
            locations = J.strings(c, "locations").joined(separator: "\n")
            exclude = J.strings(c, "exclude").joined(separator: ", ")
            rssFeeds = J.strings(c, "rss").joined(separator: "\n")
            maxAge = Int(J.str(c, "maxAgeDays")) ?? 7
            let s = J.dict(c, "sources")
            srcAdzuna = s?["adzuna"] as? Bool ?? true
            srcJooble = s?["jooble"] as? Bool ?? true
            srcJSearch = s?["jsearch"] as? Bool ?? true
            srcEmail = s?["email"] as? Bool ?? true
            let m = J.dict(c, "emailSites")
            mailNaukri = m?["naukri"] as? Bool ?? true
            mailWellfound = m?["wellfound"] as? Bool ?? true
            mailLinkedIn = m?["linkedin"] as? Bool ?? false
            UserDefaults.standard.set(lines(roles), forKey: "feedRoles")
            UserDefaults.standard.set(lines(locations), forKey: "feedLocations")
            status = "Loaded current search from GitHub."
        } catch {
            status = error.localizedDescription
        }
    }

    private func save() async {
        let r = lines(roles), l = lines(locations)
        UserDefaults.standard.set(r, forKey: "feedRoles")
        UserDefaults.standard.set(l, forKey: "feedLocations")
        do {
            try await store.saveCollectorConfig([
                "roles": r, "locations": l,
                "exclude": exclude.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                "maxAgeDays": maxAge,
                "rss": lines(rssFeeds),
                "sources": ["adzuna": srcAdzuna, "jooble": srcJooble, "jsearch": srcJSearch, "email": srcEmail, "rss": true],
                "emailSites": ["naukri": mailNaukri, "wellfound": mailWellfound, "linkedin": mailLinkedIn]
            ])
            status = "Saved. The collector runs now (saving triggers it) and then three times a day."
            store.rescoreFeedLocally()
        } catch {
            status = error.localizedDescription
        }
    }
}

/// "AI checks: 23 done · 12 queued · 37 left today" — the background fit-check worker's progress.
struct BackgroundCheckStatus: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if FeedSettings.aiMatch && ProviderSettings.anyKeyConfigured {
            HStack(spacing: 6) {
                if !store.feedMatchQueue.isEmpty || !store.feedInFlight.isEmpty { ProgressView().controlSize(.mini) }
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help("Fit checks run in the background, best quick scores first, then re-checks of jobs judged on older stories. Daily limit in Settings ▸ Job Feed.")
        }
    }
    private var text: String {
        var parts: [String] = []
        if store.feedChecksDone > 0 { parts.append("\(store.feedChecksDone) checked") }
        let pending = store.feedMatchQueue.count + store.feedInFlight.count
        if pending > 0 { parts.append("\(pending) queued") }
        if let eta = store.feedETA { parts.append("≈\(eta) min left") }
        if store.feedRate > 0 { parts.append("\(Int(store.feedRate.rounded()))/min") }
        if store.feedQueueSkipped > 0 { parts.append("\(store.feedQueueSkipped) held for the next round") }
        let stale = store.feedStaleCount
        if stale > 0 { parts.append("\(stale) to re-check") }
        parts.append("\(store.feedChecksLeftToday) left today")
        return "AI checks: " + parts.joined(separator: " · ")
    }
}

/// Settings ▸ Job Feed ▸ Google Sheets — tabs of a shared spreadsheet that list jobs.
struct SheetSourcesSection: View {
    @EnvironmentObject var store: AppStore
    @State private var sources = SheetSettings.sources
    @State private var newLink = ""
    @State private var newTab = ""
    @State private var newLabel = ""

    var body: some View {
        Section {
            ForEach($sources) { $src in
                HStack {
                    Toggle("", isOn: $src.enabled).labelsHidden()
                    TextField("Label", text: $src.label).frame(width: 110)
                    TextField("Tab name or gid", text: $src.tab).frame(width: 130)
                    Text(String(src.spreadsheetID.prefix(10)) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button { sources.removeAll { $0.id == src.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Sheet link (open the tab, copy the URL)", text: $newLink)
                TextField("Tab name (optional)", text: $newTab).frame(width: 130)
                TextField("Label", text: $newLabel).frame(width: 100)
                Button("Add") {
                    if let s = SheetSource.from(link: newLink, label: newLabel.isEmpty ? (newTab.isEmpty ? "Sheet" : newTab) : newLabel, tabName: newTab) {
                        sources.append(s); newLink = ""; newTab = ""; newLabel = ""
                    }
                }
                .disabled(!newLink.contains("/spreadsheets/d/"))
            }
            HStack {
                Button("Save & fetch now") {
                    SheetSettings.sources = sources
                    Task { await store.refreshGoogleSheets(manual: true) }
                }
                if let s = store.sheetsStatus { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
        } header: {
            Text("Google Sheets")
        } footer: {
            Text("Each row is a job. The app works out the columns (title, description, link, category, location, date) from the headers or the data, reads the sheets from your Mac every 2 hours, and merges them into the Job Feed. The sheet must be shared as \"anyone with the link can view\". Use a tab's exact name (e.g. Sheet3), or paste the link while that tab is open to use its gid.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: sources) { SheetSettings.sources = $0 }
    }
}
