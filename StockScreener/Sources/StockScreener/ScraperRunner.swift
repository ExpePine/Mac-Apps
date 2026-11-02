import SwiftUI
import AppKit

// MARK: - Run your GitHub Actions scrapers from the app (several repositories)
//
// GitHub REST API with a personal access token (classic: the "repo" scope, plus "workflow" to be safe). One token
// is shared by all repositories; a repository can have its own token instead. Tokens live only in the Keychain.
//   list:  GET  /repos/{owner}/{repo}/actions/workflows
//   run:   POST /repos/{owner}/{repo}/actions/workflows/{id}/dispatches   {"ref": "main"}   (needs workflow_dispatch:)
//   runs:  GET  /repos/{owner}/{repo}/actions/runs?per_page=15

struct GHWorkflow: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let path: String
    let state: String
    var file: String { (path as NSString).lastPathComponent }
}

struct GHRun: Identifiable, Decodable {
    let id: Int
    let name: String?
    let status: String?
    let conclusion: String?
    let event: String?
    let created_at: String?
    let run_started_at: String?
    let html_url: String?
}

struct ScraperRepo: Identifiable, Codable, Equatable {
    var id = UUID()
    var repo = ""                    // owner/repo
    var ref = "main"
    var selected: [Int] = []         // workflow ids ticked
    var auto = false
    var at = 16 * 60 + 35            // minutes after midnight IST
    var ownToken = false             // use its own Keychain token instead of the shared one
    var lastAutoDay = ""
    var title: String { repo.isEmpty ? "New repository" : repo }

    /// "https://github.com/owner/repo.git", "github.com/owner/repo/", "owner/repo" → "owner/repo"
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www.", "github.com/"] where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        if t.hasSuffix(".git") { t = String(t.dropLast(4)) }
        let parts = t.split(separator: "/").map(String.init)
        return parts.count >= 2 ? parts[0] + "/" + parts[1] : t
    }
    var tokenAccount: String { ownToken ? "github.pat.\(id.uuidString)" : ScraperCenter.keychainAccount }
}

@MainActor final class ScraperCenter: ObservableObject {
    static let shared = ScraperCenter()
    static let keychainAccount = "github.pat"
    static let ist = TimeZone(identifier: "Asia/Kolkata")!

    @Published var repos: [ScraperRepo] = ScraperCenter.load() { didSet { save() } }
    @Published var workflows: [UUID: [GHWorkflow]] = [:]
    @Published var runs: [UUID: [GHRun]] = [:]
    @Published var status: [UUID: String] = [:]
    @Published var busy: Set<UUID> = []
    // chains (ScraperChains.swift)
    @Published var chains: [ScraperChain] = ScraperCenter.loadChains()
    @Published var live: [UUID: [UUID: StepLive]] = [:]
    @Published var chainRunning: Set<UUID> = []
    @Published var chainStatus: [UUID: String] = [:]
    @Published var chainGap: [UUID: (step: UUID, until: Date)] = [:]
    var chainTasks: [UUID: Task<Void, Never>] = [:]

    private static func load() -> [ScraperRepo] {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "gh.repos"), let r = try? JSONDecoder().decode([ScraperRepo].self, from: data) { return r }
        // one repository set up before several were possible
        if let old = d.string(forKey: "gh.repo"), !old.isEmpty {
            return [ScraperRepo(repo: old, ref: d.string(forKey: "gh.ref").flatMap { $0.isEmpty ? nil : $0 } ?? "main",
                                selected: (d.array(forKey: "gh.selected") as? [Int]) ?? [], auto: d.bool(forKey: "gh.auto"),
                                at: d.integer(forKey: "gh.at") > 0 ? d.integer(forKey: "gh.at") : 16 * 60 + 35)]
        }
        return []
    }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(repos), forKey: "gh.repos") }

    func repo(_ id: UUID) -> ScraperRepo? { repos.first { $0.id == id } }

    /// Repositories the shared token can see (yours and your organisations'), newest pushed first.
    func myRepos() async -> (names: [String], error: String?) {
        let probe = ScraperRepo(repo: "x/x")
        var out: [String] = []
        for page in 1...5 {
            guard let res = try? await request(probe, "/user/repos?per_page=100&sort=pushed&page=\(page)") else { return (out, "Couldn't reach GitHub.") }
            guard res.1 == 200 else { return (out, explain(res.1, res.0, ref: "main")) }
            let arr = (try? JSONSerialization.jsonObject(with: res.0) as? [[String: Any]]) ?? []
            out += arr.compactMap { $0["full_name"] as? String }
            if arr.count < 100 { break }
        }
        return (out, nil)
    }

    func addRepos(_ names: [String]) -> UUID? {
        var last: UUID?
        for n in names.map(ScraperRepo.clean) where !n.isEmpty && !repos.contains(where: { $0.repo.lowercased() == n.lowercased() }) {
            let r = ScraperRepo(repo: n); repos.append(r); last = r.id
        }
        return last
    }
    func update(_ id: UUID, _ f: (inout ScraperRepo) -> Void) { if let i = repos.firstIndex(where: { $0.id == id }) { f(&repos[i]) } }
    func hasToken(_ r: ScraperRepo) -> Bool { !Keychain.get(r.tokenAccount).isEmpty }

    func request(_ r: ScraperRepo, _ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Data, Int) {
        let token = Keychain.get(r.tokenAccount)
        guard !token.isEmpty else { throw YahooClient.Failure(message: r.ownToken ? "Save this repository's token first." : "Save your GitHub token first.") }
        let path = path.replacingOccurrences(of: "/repos/\(r.repo)/", with: "/repos/\(ScraperRepo.clean(r.repo))/")
        guard let url = URL(string: "https://api.github.com" + path) else { throw YahooClient.Failure(message: "Bad repository name") }
        var q = URLRequest(url: url, timeoutInterval: 25)
        q.httpMethod = method
        q.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        q.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        q.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            q.setValue("application/json", forHTTPHeaderField: "Content-Type")
            q.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: q)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func explain(_ code: Int, _ data: Data, ref: String) -> String {
        let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
        switch code {
        case 401: return "GitHub says the token is wrong or expired (401)."
        case 403: return "GitHub refused (403): the token needs the “repo” (and “workflow”) scope. \(msg)"
        case 404: return "Not found (404): check owner/repo, and that the token can see this repository. \(msg)"
        case 422: return "GitHub couldn't start it (422): the file needs “workflow_dispatch:” and the branch “\(ref)” must exist. \(msg)"
        default: return "GitHub answered \(code). \(msg)"
        }
    }

    func loadWorkflows(_ id: UUID) async {
        guard let r = repo(id), !r.repo.isEmpty else { status[id] = "Type owner/repo first."; return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            let (data, code) = try await request(r, "/repos/\(r.repo)/actions/workflows?per_page=100")
            guard code == 200 else { status[id] = explain(code, data, ref: r.ref); return }
            struct L: Decodable { let workflows: [GHWorkflow] }
            workflows[id] = try JSONDecoder().decode(L.self, from: data).workflows.sorted { $0.name < $1.name }
            status[id] = "\(workflows[id]?.count ?? 0) workflows in \(r.repo)."
            await loadRuns(id)
        } catch { status[id] = error.localizedDescription }
    }

    func loadRuns(_ id: UUID) async {
        guard let r = repo(id), !r.repo.isEmpty else { return }
        do {
            let (data, code) = try await request(r, "/repos/\(r.repo)/actions/runs?per_page=15")
            guard code == 200 else { status[id] = explain(code, data, ref: r.ref); return }
            struct L: Decodable { let workflow_runs: [GHRun] }
            runs[id] = try JSONDecoder().decode(L.self, from: data).workflow_runs
        } catch { status[id] = error.localizedDescription }
    }

    /// Starts workflows of one repository now (workflow_dispatch). Returns how many GitHub accepted.
    @discardableResult
    func run(_ id: UUID, _ ids: [Int]) async -> Int {
        guard let r = repo(id) else { return 0 }
        guard !ids.isEmpty else { status[id] = "Tick the workflows to run."; return 0 }
        busy.insert(id); defer { busy.remove(id) }
        var ok = 0, errors: [String] = []
        for w in ids {
            do {
                let (data, code) = try await request(r, "/repos/\(r.repo)/actions/workflows/\(w)/dispatches", method: "POST", body: ["ref": r.ref])
                if code == 204 { ok += 1 } else { errors.append(explain(code, data, ref: r.ref)) }
            } catch { errors.append(error.localizedDescription) }
        }
        status[id] = ok == ids.count ? "Started \(ok) at \(Date().formatted(date: .omitted, time: .shortened))."
                                     : "Started \(ok) of \(ids.count). \(errors.first ?? "")"
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await loadRuns(id)
        return ok
    }

    /// Every repository's ticked workflows.
    func runAll() async { for r in repos where !r.selected.isEmpty { await run(r.id, r.selected) } }

    /// From the app's refresh loop: weekdays, once the set time has passed (within 3 h), once a day per repository.
    func runIfDue() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.ist
        let c = cal.dateComponents([.weekday, .hour, .minute], from: Date())
        guard let wd = c.weekday, (2...6).contains(wd), let h = c.hour, let m = c.minute else { return }
        let now = h * 60 + m, today = AlertSchedule.today()
        chainsIfDue(now: now, today: today)
        for r in repos where r.auto && !r.repo.isEmpty && !r.selected.isEmpty && !busy.contains(r.id)
                            && now >= r.at && now < r.at + 180 && r.lastAutoDay != today && hasToken(r) {
            update(r.id) { $0.lastAutoDay = today }
            Task { await run(r.id, r.selected) }
        }
    }
}

// MARK: - Window

struct ScraperView: View {
    @ObservedObject private var sc = ScraperCenter.shared
    @AppStorage("gh.tab") private var tab = 0
    @State private var sharedToken = ""
    @State private var hasShared = !Keychain.get(ScraperCenter.keychainAccount).isEmpty

    var body: some View {
        VStack(spacing: 0) {
            FlowLayout(spacing: 10, lineSpacing: 6) {
                Picker("", selection: $tab) {
                    Text("Repositories").tag(0)
                    Text("Chains").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Image(systemName: hasShared ? "key.fill" : "key").foregroundStyle(hasShared ? .green : .orange)
                SecureField(hasShared ? "GitHub token saved — paste a new one to replace" : "Paste your GitHub token (classic, “repo” scope)", text: $sharedToken)
                    .textFieldStyle(.roundedBorder).frame(width: 330)
                Button("Save token") {
                    Keychain.set(sharedToken.trimmingCharacters(in: .whitespacesAndNewlines), for: ScraperCenter.keychainAccount)
                    sharedToken = ""; hasShared = !Keychain.get(ScraperCenter.keychainAccount).isEmpty
                }
                .disabled(sharedToken.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if tab == 1 { ChainsView() } else { RepositoriesView(hasShared: hasShared) }
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity)
        .navigationTitle("Scraper")
    }
}

private struct RepositoriesView: View {
    let hasShared: Bool
    @ObservedObject private var sc = ScraperCenter.shared
    @State private var current: UUID?
    @State private var picking = false
    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $current) {
                    ForEach(sc.repos) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                Text(r.auto ? String(format: "%d ticked · daily %02d:%02d IST", r.selected.count, r.at / 60, r.at % 60) : "\(r.selected.count) ticked")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if sc.busy.contains(r.id) { ProgressView().controlSize(.mini) }
                        }
                        .tag(r.id)
                        .contextMenu { Button("Remove", role: .destructive) { remove(r.id) } }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Button { picking = true } label: { Label("Add from my GitHub…", systemImage: "plus.circle.fill") }
                        .disabled(!hasShared)
                        .help(hasShared ? "Pick from the repositories your token can see" : "Save your token first (top of the window)")
                    Button { typing = true } label: { Label("Add by name or link…", systemImage: "link") }
                    HStack {
                        Button { if let c = current { remove(c) } } label: { Label("Remove", systemImage: "minus") }.disabled(current == nil)
                        Spacer()
                        Button { Task { await sc.runAll() } } label: { Label("Run all ticked", systemImage: "play.fill") }
                            .disabled(sc.repos.allSatisfy { $0.selected.isEmpty })
                    }
                }
                .buttonStyle(.borderless).controlSize(.small).padding(8)
            }
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 360)

            Group {
                if let id = current, sc.repo(id) != nil {
                    RepoPanel(id: id).id(id)
                } else {
                    VStack(spacing: 10) {
                        Text(sc.repos.isEmpty ? "No repositories yet." : "Pick a repository on the left.").foregroundStyle(.secondary)
                        if sc.repos.isEmpty {
                            Button { picking = true } label: { Label("Add from my GitHub…", systemImage: "plus.circle.fill") }
                                .buttonStyle(.borderedProminent).disabled(!hasShared)
                            if !hasShared { Text("Paste and save your token at the top first.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if current == nil { current = sc.repos.first?.id } }
        .sheet(isPresented: $picking) { RepoPicker { names in if let id = sc.addRepos(names) { current = id } } }
        .sheet(isPresented: $typing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add a repository").font(.headline)
                TextField("owner/repo or https://github.com/owner/repo", text: $typed).textFieldStyle(.roundedBorder).frame(width: 380)
                    .onSubmit { addTyped() }
                HStack { Spacer(); Button("Cancel") { typing = false }; Button("Add") { addTyped() }.keyboardShortcut(.defaultAction).disabled(typed.isEmpty) }
            }
            .padding(16)
        }
    }

    private func addTyped() {
        if let id = sc.addRepos([typed]) { current = id }
        typed = ""; typing = false
    }
    private func remove(_ id: UUID) {
        if let r = sc.repo(id), r.ownToken { Keychain.set("", for: r.tokenAccount) }
        sc.repos.removeAll { $0.id == id }
        current = sc.repos.first?.id
    }
}

/// Tick repositories from the ones your token can see.
private struct RepoPicker: View {
    let onAdd: ([String]) -> Void
    @ObservedObject private var sc = ScraperCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = []
    @State private var picked = Set<String>()
    @State private var search = ""
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add repositories").font(.headline)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            if loading { ProgressView("Asking GitHub…").frame(maxWidth: .infinity) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            List(names.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { n in
                let have = sc.repos.contains { $0.repo.lowercased() == n.lowercased() }
                Toggle(isOn: Binding(get: { picked.contains(n) || have }, set: { on in if on { picked.insert(n) } else { picked.remove(n) } })) {
                    Text(n)
                }
                .toggleStyle(.checkbox).disabled(have)
            }
            .frame(minHeight: 260)
            HStack {
                Text("\(picked.count) ticked").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { onAdd(Array(picked).sorted()); dismiss() }.keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460, height: 460)
        .task {
            let r = await sc.myRepos()
            names = r.names; error = r.error; loading = false
        }
    }
}

private struct RepoPanel: View {
    let id: UUID
    @ObservedObject private var sc = ScraperCenter.shared
    @State private var token = ""
    private static let times: [Int] = Array(stride(from: 6 * 60, through: 23 * 60 + 55, by: 5))

    private var r: ScraperRepo { sc.repo(id) ?? ScraperRepo() }
    private func bind<T>(_ k: WritableKeyPath<ScraperRepo, T>) -> Binding<T> {
        Binding(get: { r[keyPath: k] }, set: { v in sc.update(id) { $0[keyPath: k] = v } })
    }

    var body: some View {
        let wfs = sc.workflows[id] ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Repository") {
                    VStack(alignment: .leading, spacing: 8) {
                        FlowLayout(spacing: 8, lineSpacing: 6) {
                            TextField("owner/repo", text: bind(\.repo)).textFieldStyle(.roundedBorder).frame(width: 260)
                                .onSubmit { sc.update(id) { $0.repo = ScraperRepo.clean($0.repo) } }
                            HStack(spacing: 4) {
                                Text("branch").font(.caption)
                                TextField("main", text: bind(\.ref)).textFieldStyle(.roundedBorder).frame(width: 90)
                            }
                            Button { sc.update(id) { $0.repo = ScraperRepo.clean($0.repo) }; Task { await sc.loadWorkflows(id) } } label: {
                                Label("Load workflows", systemImage: "arrow.clockwise")
                            }
                            .disabled(r.repo.isEmpty || !sc.hasToken(r))
                            if sc.busy.contains(id) { ProgressView().controlSize(.small) }
                        }
                        FlowLayout(spacing: 8, lineSpacing: 6) {
                            Toggle("Use its own token", isOn: bind(\.ownToken)).toggleStyle(.checkbox)
                            if r.ownToken {
                                SecureField(sc.hasToken(r) ? "Saved — paste to replace" : "Token for this repository", text: $token)
                                    .textFieldStyle(.roundedBorder).frame(width: 240)
                                Button("Save") { Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: r.tokenAccount); token = "" }
                                    .disabled(token.isEmpty)
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Workflows") {
                    VStack(alignment: .leading, spacing: 6) {
                        if wfs.isEmpty { Text(sc.hasToken(r) ? "Press Load workflows." : "Save a token first.").foregroundStyle(.secondary) }
                        ForEach(wfs) { w in
                            HStack {
                                Toggle(isOn: Binding(get: { r.selected.contains(w.id) }, set: { on in
                                    sc.update(id) { if on { $0.selected.append(w.id) } else { $0.selected.removeAll { $0 == w.id } } }
                                })) { Text(w.name).fontWeight(.medium).lineLimit(1) }
                                .toggleStyle(.checkbox)
                                Text(w.file).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if w.state != "active" { Text(w.state).font(.caption).foregroundStyle(.orange) }
                                Spacer(minLength: 4)
                                Button("Run now") { Task { await sc.run(id, [w.id]) } }.controlSize(.small).disabled(sc.busy.contains(id))
                            }
                        }
                        if !wfs.isEmpty {
                            Divider()
                            FlowLayout(spacing: 10, lineSpacing: 6) {
                                Button { Task { await sc.run(id, r.selected) } } label: { Label("Run ticked (\(r.selected.count))", systemImage: "play.fill") }
                                    .buttonStyle(.borderedProminent).disabled(r.selected.isEmpty || sc.busy.contains(id))
                                Toggle("Run the ticked ones every weekday at", isOn: bind(\.auto)).toggleStyle(.checkbox)
                                Picker("", selection: bind(\.at)) {
                                    ForEach(Self.times, id: \.self) { m in Text(String(format: "%02d:%02d IST", m / 60, m % 60)).tag(m) }
                                }
                                .labelsHidden().fixedSize()
                            }
                            Text("Starts at that time while the app is open and the Mac is awake (catches up within 3 hours). To run repositories one after another, use Chains.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(4)
                }

                GroupBox("Recent runs") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Spacer(); Button { Task { await sc.loadRuns(id) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless) }
                        ForEach(sc.runs[id] ?? []) { run in
                            HStack(spacing: 8) {
                                Circle().fill(runColor(run)).frame(width: 8, height: 8)
                                Text(run.name ?? "—").lineLimit(1)
                                Text(run.event ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(runLabel(run)).font(.caption)
                                Spacer(minLength: 4)
                                Text(istTime(run.run_started_at ?? run.created_at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if let u = run.html_url.flatMap(URL.init(string:)) {
                                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless)
                                }
                            }
                        }
                        if (sc.runs[id] ?? []).isEmpty { Text("—").foregroundStyle(.secondary) }
                    }
                    .padding(4)
                }
                if let s = sc.status[id] { Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if (sc.workflows[id] ?? []).isEmpty, !r.repo.isEmpty, sc.hasToken(r) { Task { await sc.loadWorkflows(id) } } }
    }
}

func runLabel(_ r: GHRun) -> String { r.status == "completed" ? (r.conclusion ?? "completed") : (r.status ?? "") }
func runColor(_ r: GHRun) -> Color { r.status != "completed" ? .orange : (r.conclusion == "success" ? .green : .red) }
func istTime(_ iso: String?) -> String {
    guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "—" }
    let f = DateFormatter(); f.timeZone = ScraperCenter.ist; f.dateFormat = "d MMM HH:mm 'IST'"
    return f.string(from: d)
}
