import SwiftUI
import AppKit
import UserNotifications

// MARK: - Did today's scrapers all run? (checked after your set time, default 18:00 IST, weekdays)
//
// For every repository in the Scraper window and its ticked workflows (all workflows if none are ticked):
//   • disabled on GitHub                       → "disabled"   (Enable & run)
//   • no run today (IST)                       → "not run"    (Run now)
//   • today's latest run still queued / running → "incomplete" (Open)
//   • today's latest run failed / cancelled     → "failed"     (Run again)
// Problems show as a banner in the Filter and Daily Gainers windows, and once as a macOS notification.
//   GET /repos/{r}/actions/workflows                      (state: active / disabled_manually / disabled_inactivity)
//   GET /repos/{r}/actions/workflows/{id}/runs?per_page=5 (latest runs of that workflow)
//   PUT /repos/{r}/actions/workflows/{id}/enable

struct ScraperIssue: Identifiable, Equatable {
    enum Kind: Equatable { case disabled, notRun, running(String), failed(String) }
    let repoID: UUID
    let repo: String
    let workflowID: Int
    let workflow: String
    let kind: Kind
    let runURL: String?
    var id: String { "\(repoID.uuidString)|\(workflowID)" }

    var text: String {
        switch kind {
        case .disabled: return "disabled on GitHub"
        case .notRun: return "hasn't run today"
        case .running(let s): return "still \(s.replacingOccurrences(of: "_", with: " "))"
        case .failed(let c): return c.replacingOccurrences(of: "_", with: " ")
        }
    }
    var color: Color {
        switch kind {
        case .running: return .orange
        default: return .red
        }
    }
}

@MainActor final class ScraperHealth: ObservableObject {
    static let shared = ScraperHealth()
    @Published private(set) var issues: [ScraperIssue] = []
    @Published private(set) var checkedAt: Date?
    @Published private(set) var checking = false
    @Published var acting: Set<String> = []
    /// Set to open the Scraper window on this repository.
    @Published var focusRepo: UUID?

    var enabled: Bool { UserDefaults.standard.object(forKey: "health.on") as? Bool ?? true }
    var checkAt: Int { UserDefaults.standard.object(forKey: "health.at") as? Int ?? 18 * 60 }
    private var dismissedDay: String { UserDefaults.standard.string(forKey: "health.dismissed") ?? "" }
    private var notified: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "health.notified") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "health.notified") }
    }

    var showBanner: Bool { enabled && !issues.isEmpty && dismissedDay != AlertSchedule.today() }
    func dismissToday() { UserDefaults.standard.set(AlertSchedule.today(), forKey: "health.dismissed"); objectWillChange.send() }

    /// From the app's refresh loop: weekdays after the set time, every 20 minutes until midnight.
    func checkIfDue() {
        guard enabled, !checking else { return }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ScraperCenter.ist
        let c = cal.dateComponents([.weekday, .hour, .minute], from: Date())
        guard let wd = c.weekday, (2...6).contains(wd), let h = c.hour, let m = c.minute, h * 60 + m >= checkAt else {
            if !issues.isEmpty { issues = [] }       // a new day: yesterday's problems don't count
            return
        }
        if let t = checkedAt, Date().timeIntervalSince(t) < 20 * 60, cal.isDate(t, inSameDayAs: Date()) { return }
        Task { await check() }
    }

    func check() async {
        let sc = ScraperCenter.shared
        guard !checking else { return }
        checking = true; defer { checking = false; checkedAt = Date() }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ScraperCenter.ist
        let iso = ISO8601DateFormatter()
        var found: [ScraperIssue] = []
        for r in sc.repos where !r.repo.isEmpty && sc.hasToken(r) {
            struct WL: Decodable { let workflows: [GHWorkflow] }
            guard let res = try? await sc.request(r, "/repos/\(r.repo)/actions/workflows?per_page=100"), res.1 == 200,
                  let wfs = try? JSONDecoder().decode(WL.self, from: res.0).workflows else { continue }
            sc.workflows[r.id] = wfs.sorted { $0.name < $1.name }
            let shown = wfs.filter { !r.isHidden($0.id) }
            let watch = r.selected.isEmpty ? shown : shown.filter { r.selected.contains($0.id) }
            for w in watch {
                if w.state != "active" {
                    found.append(ScraperIssue(repoID: r.id, repo: r.repo, workflowID: w.id, workflow: w.name, kind: .disabled, runURL: nil))
                    continue
                }
                struct RL: Decodable { let workflow_runs: [GHRun] }
                guard let rr = try? await sc.request(r, "/repos/\(r.repo)/actions/workflows/\(w.id)/runs?per_page=5"), rr.1 == 200,
                      let runs = try? JSONDecoder().decode(RL.self, from: rr.0).workflow_runs else { continue }
                let today = runs.filter { $0.created_at.flatMap { iso.date(from: $0) }.map { cal.isDateInToday($0) } ?? false }
                guard let latest = today.first else {
                    found.append(ScraperIssue(repoID: r.id, repo: r.repo, workflowID: w.id, workflow: w.name, kind: .notRun, runURL: nil))
                    continue
                }
                if latest.status != "completed" {
                    found.append(ScraperIssue(repoID: r.id, repo: r.repo, workflowID: w.id, workflow: w.name, kind: .running(latest.status ?? "running"), runURL: latest.html_url))
                } else if latest.conclusion != "success" && latest.conclusion != "skipped" {
                    found.append(ScraperIssue(repoID: r.id, repo: r.repo, workflowID: w.id, workflow: w.name, kind: .failed(latest.conclusion ?? "failed"), runURL: latest.html_url))
                }
            }
        }
        issues = found
        notify(found)
    }

    /// One macOS notification per problem per day (not for runs that are merely still going).
    private func notify(_ found: [ScraperIssue]) {
        let today = AlertSchedule.today()
        let fresh = found.filter { if case .running = $0.kind { return false }; return !notified.contains(today + "|" + $0.id) }
        guard !fresh.isEmpty, Bundle.main.bundleIdentifier != nil else { return }
        notified = Set(notified.filter { $0.hasPrefix(today) }).union(fresh.map { today + "|" + $0.id })
        let body = fresh.prefix(4).map { "\($0.workflow) (\($0.repo)): \($0.text)" }.joined(separator: "\n")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = "Scraper: \(fresh.count) workflow\(fresh.count == 1 ? "" : "s") need attention"
            c.body = body
            c.sound = .default
            center.add(UNNotificationRequest(identifier: "scraper-health-" + today, content: c, trigger: nil))
        }
    }

    // MARK: Fixing

    func runNow(_ i: ScraperIssue) {
        acting.insert(i.id)
        Task {
            let sc = ScraperCenter.shared
            if i.kind == .disabled, let r = sc.repo(i.repoID) {
                _ = try? await sc.request(r, "/repos/\(r.repo)/actions/workflows/\(i.workflowID)/enable", method: "PUT")
            }
            await sc.run(i.repoID, [i.workflowID])
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            acting.remove(i.id)
            await check()
        }
    }

    func drop(_ i: ScraperIssue) { issues.removeAll { $0.id == i.id } }

    func runAll() { for i in issues { if case .running = i.kind { continue }; runNow(i) } }
}

// MARK: - Banner

struct ScraperHealthBanner: View {
    @ObservedObject private var h = ScraperHealth.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if h.showBanner {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Scraper: \(h.issues.count) workflow\(h.issues.count == 1 ? "" : "s") need attention today").font(.callout.bold())
                    if let t = h.checkedAt { Text("checked \(t.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if h.issues.contains(where: { if case .running = $0.kind { return false }; return true }) {
                        Button("Run all of them") { h.runAll() }
                    }
                    Button { Task { await h.check() } } label: { if h.checking { ProgressView().controlSize(.mini) } else { Text("Recheck") } }
                    Button { h.dismissToday() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide until tomorrow")
                }
                // one grid: each row's buttons sit right after its status, in a column that lines up
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(h.issues) { i in
                        GridRow {
                            Circle().fill(i.color).frame(width: 7, height: 7)
                            Text(i.workflow).fontWeight(.medium).lineLimit(1)
                            Text(i.repo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(i.text).font(.caption).foregroundStyle(i.color).lineLimit(1)
                            HStack(spacing: 6) {
                                switch i.kind {
                                case .disabled: Button("Enable & run") { h.runNow(i) }.disabled(h.acting.contains(i.id))
                                case .notRun: Button("Run now") { h.runNow(i) }.disabled(h.acting.contains(i.id))
                                case .failed: Button("Run again") { h.runNow(i) }.disabled(h.acting.contains(i.id))
                                case .running: EmptyView()
                                }
                                Button("Open") { h.focusRepo = i.repoID; openWindow(id: "scraper") }
                                    .help("Open this repository in the Scraper window")
                                if let u = i.runURL.flatMap(URL.init(string:)) {
                                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Open the run on GitHub")
                                }
                                Button { ScraperCenter.shared.hide(i.repoID, i.workflowID); h.drop(i) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .help("Not needed: remove this workflow from the app (stays on GitHub; restore in the Scraper window)")
                                if h.acting.contains(i.id) { ProgressView().controlSize(.mini) }
                            }
                            .gridColumnAlignment(.leading)
                        }
                        .controlSize(.small)
                    }
                }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }
}

/// Settings row.
struct ScraperHealthSettings: View {
    @AppStorage("health.on") private var on = true
    @AppStorage("health.at") private var at = 18 * 60
    private static let times = Array(stride(from: 15 * 60, through: 23 * 60 + 30, by: 15))
    var body: some View {
        HStack {
            Toggle("After", isOn: $on).toggleStyle(.checkbox)
            Picker("", selection: $at) { ForEach(Self.times, id: \.self) { m in Text(String(format: "%02d:%02d IST", m / 60, m % 60)).tag(m) } }
                .labelsHidden().fixedSize().disabled(!on)
            Text("on weekdays, check that every repository's ticked workflows ran today — banner + notification if one didn't, failed or is disabled")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
