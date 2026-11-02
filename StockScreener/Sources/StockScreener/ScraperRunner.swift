import SwiftUI
import AppKit

// MARK: - Run your GitHub Actions scraper from the app
//
// Uses GitHub's REST API with your personal access token (classic: needs the "repo" scope — "workflow" too if you
// want to be safe). The token is kept in the macOS Keychain, never in a file or the repo.
//   list:  GET  /repos/{owner}/{repo}/actions/workflows
//   run:   POST /repos/{owner}/{repo}/actions/workflows/{id}/dispatches   {"ref": "main"}   (needs workflow_dispatch: in the file)
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
    let updated_at: String?
    let html_url: String?
    let workflow_id: Int?
}

@MainActor final class ScraperCenter: ObservableObject {
    static let shared = ScraperCenter()
    static let keychainAccount = "github.pat"

    @Published var workflows: [GHWorkflow] = []
    @Published var runs: [GHRun] = []
    @Published var status: String?
    @Published var busy = false

    private var d: UserDefaults { .standard }
    var repo: String { d.string(forKey: "gh.repo") ?? "" }
    var ref: String { let r = d.string(forKey: "gh.ref") ?? ""; return r.isEmpty ? "main" : r }
    var selected: Set<Int> { Set((d.array(forKey: "gh.selected") as? [Int]) ?? []) }
    var hasToken: Bool { !Keychain.get(Self.keychainAccount).isEmpty }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Data, Int) {
        let token = Keychain.get(Self.keychainAccount)
        guard !token.isEmpty else { throw YahooClient.Failure(message: "Add your GitHub token first.") }
        guard let url = URL(string: "https://api.github.com" + path) else { throw YahooClient.Failure(message: "Bad repository name") }
        var r = URLRequest(url: url, timeoutInterval: 25)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func explain(_ code: Int, _ data: Data) -> String {
        let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
        switch code {
        case 401: return "GitHub says the token is wrong or expired (401)."
        case 403: return "GitHub refused (403): the token needs the “repo” (and “workflow”) scope. \(msg)"
        case 404: return "Not found (404): check owner/repo, and that the token can see this repo. \(msg)"
        case 422: return "GitHub couldn't start it (422): the file needs “workflow_dispatch:” and the branch “\(ref)” must exist. \(msg)"
        default: return "GitHub answered \(code). \(msg)"
        }
    }

    func loadWorkflows() async {
        guard !repo.isEmpty else { status = "Type owner/repo first."; return }
        busy = true; defer { busy = false }
        do {
            let (data, code) = try await request("/repos/\(repo)/actions/workflows?per_page=100")
            guard code == 200 else { status = explain(code, data); return }
            struct L: Decodable { let workflows: [GHWorkflow] }
            workflows = try JSONDecoder().decode(L.self, from: data).workflows.sorted { $0.name < $1.name }
            status = "\(workflows.count) workflows in \(repo)."
            await loadRuns()
        } catch { status = error.localizedDescription }
    }

    func loadRuns() async {
        guard !repo.isEmpty else { return }
        do {
            let (data, code) = try await request("/repos/\(repo)/actions/runs?per_page=15")
            guard code == 200 else { status = explain(code, data); return }
            struct L: Decodable { let workflow_runs: [GHRun] }
            runs = try JSONDecoder().decode(L.self, from: data).workflow_runs
        } catch { status = error.localizedDescription }
    }

    /// Starts the workflows now (workflow_dispatch). Returns how many GitHub accepted.
    @discardableResult
    func run(_ ids: [Int]) async -> Int {
        guard !ids.isEmpty else { status = "Tick the workflows to run."; return 0 }
        busy = true; defer { busy = false }
        var ok = 0, errors: [String] = []
        for id in ids {
            do {
                let (data, code) = try await request("/repos/\(repo)/actions/workflows/\(id)/dispatches", method: "POST", body: ["ref": ref])
                if code == 204 { ok += 1 } else { errors.append(explain(code, data)) }
            } catch { errors.append(error.localizedDescription) }
        }
        let names = workflows.filter { ids.contains($0.id) }.map(\.name)
        status = ok == ids.count ? "Started \(ok) at \(Date().formatted(date: .omitted, time: .shortened)): \(names.joined(separator: ", "))"
                                 : "Started \(ok) of \(ids.count). \(errors.first ?? "")"
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await loadRuns()
        return ok
    }

    // MARK: Run at a set time (while the app is open)

    static let ist = TimeZone(identifier: "Asia/Kolkata")!
    var autoOn: Bool { d.bool(forKey: "gh.auto") }
    var autoAt: Int { let v = d.integer(forKey: "gh.at"); return v > 0 ? v : 16 * 60 + 35 }      // minutes after midnight IST

    /// Called from the app's refresh loop: on a weekday, once the set time has passed, starts the ticked workflows (once a day).
    func runIfDue() {
        guard autoOn, !busy, hasToken, !repo.isEmpty, !selected.isEmpty else { return }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.ist
        let c = cal.dateComponents([.weekday, .hour, .minute], from: Date())
        guard let wd = c.weekday, (2...6).contains(wd), let h = c.hour, let m = c.minute else { return }
        let today = AlertSchedule.today()
        guard h * 60 + m >= autoAt, h * 60 + m < autoAt + 180, d.string(forKey: "gh.autoDay") != today else { return }
        d.set(today, forKey: "gh.autoDay")
        Task { await run(Array(selected)) }
    }
}

struct ScraperView: View {
    @ObservedObject private var sc = ScraperCenter.shared
    @AppStorage("gh.repo") private var repo = ""
    @AppStorage("gh.ref") private var ref = "main"
    @AppStorage("gh.auto") private var auto = false
    @AppStorage("gh.at") private var at = 16 * 60 + 35
    @State private var token = ""
    @State private var picked = Set<Int>()
    @State private var hasToken = ScraperCenter.shared.hasToken

    private static let times: [Int] = Array(stride(from: 15 * 60 + 35, through: 23 * 60 + 30, by: 5))

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("GitHub") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SecureField(hasToken ? "Token saved in the Keychain — paste a new one to replace it" : "Personal access token (classic: ghp_…)", text: $token)
                            .textFieldStyle(.roundedBorder)
                        Button("Save token") {
                            Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: ScraperCenter.keychainAccount)
                            token = ""; hasToken = sc.hasToken
                            sc.status = hasToken ? "Token saved in the Keychain." : "Token removed."
                        }
                        .disabled(token.isEmpty && !hasToken)
                    }
                    Text("Classic token: tick the “repo” scope (and “workflow”). It's stored only in your Mac's Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("owner/repo", text: $repo).textFieldStyle(.roundedBorder).frame(width: 280)
                        Text("branch").font(.caption)
                        TextField("main", text: $ref).textFieldStyle(.roundedBorder).frame(width: 90)
                        Button { Task { await sc.loadWorkflows() } } label: { Label("Load workflows", systemImage: "arrow.clockwise") }
                            .disabled(repo.isEmpty || !hasToken)
                        if sc.busy { ProgressView().controlSize(.small) }
                    }
                }
                .padding(6)
            }

            GroupBox("Workflows") {
                VStack(alignment: .leading, spacing: 6) {
                    if sc.workflows.isEmpty {
                        Text("Press Load workflows.").foregroundStyle(.secondary)
                    }
                    ForEach(sc.workflows) { w in
                        HStack {
                            Toggle(isOn: Binding(get: { picked.contains(w.id) }, set: { on in
                                if on { picked.insert(w.id) } else { picked.remove(w.id) }
                                UserDefaults.standard.set(Array(picked), forKey: "gh.selected")
                            })) { Text(w.name).fontWeight(.medium) }
                            .toggleStyle(.checkbox)
                            Text(w.file).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if w.state != "active" { Text(w.state).font(.caption).foregroundStyle(.orange) }
                            Spacer()
                            Button("Run now") { Task { await sc.run([w.id]) } }.controlSize(.small).disabled(sc.busy)
                        }
                    }
                    if !sc.workflows.isEmpty {
                        Divider()
                        HStack {
                            Button { Task { await sc.run(Array(picked)) } } label: { Label("Run ticked (\(picked.count))", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent).disabled(picked.isEmpty || sc.busy)
                            Spacer()
                            Toggle("Run the ticked ones every weekday at", isOn: $auto).toggleStyle(.checkbox)
                            Picker("", selection: $at) {
                                ForEach(Self.times, id: \.self) { m in Text(String(format: "%02d:%02d IST", m / 60, m % 60)).tag(m) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Text("Exact-time start from the app — only while the app is open and the Mac is awake. Keep the workflow's own cron as a backup, or remove it to avoid running twice.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
            }

            GroupBox("Recent runs") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Spacer()
                        Button { Task { await sc.loadRuns() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                    }
                    ForEach(sc.runs) { r in
                        HStack(spacing: 8) {
                            Circle().fill(color(r)).frame(width: 8, height: 8)
                            Text(r.name ?? "—").lineLimit(1).frame(width: 220, alignment: .leading)
                            Text(r.event ?? "").font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text(label(r)).font(.caption).frame(width: 110, alignment: .leading)
                            Text("started " + local(r.run_started_at ?? r.created_at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            if let u = r.html_url.flatMap(URL.init(string:)) {
                                Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if sc.runs.isEmpty { Text("—").foregroundStyle(.secondary) }
                }
                .padding(6)
            }

            if let s = sc.status { Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
        }
        .padding(16)
        .navigationTitle("Scraper")
        .onAppear {
            picked = sc.selected
            hasToken = sc.hasToken
            if sc.workflows.isEmpty, hasToken, !repo.isEmpty { Task { await sc.loadWorkflows() } }
        }
    }

    private func label(_ r: GHRun) -> String {
        if r.status == "completed" { return r.conclusion ?? "completed" }
        return r.status ?? ""
    }
    private func color(_ r: GHRun) -> Color {
        if r.status != "completed" { return .orange }
        return r.conclusion == "success" ? .green : .red
    }
    private func local(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "—" }
        let f = DateFormatter(); f.timeZone = ScraperCenter.ist; f.dateFormat = "d MMM HH:mm 'IST'"
        return f.string(from: d)
    }
}
