import SwiftUI
import AppKit

// MARK: - Chains: run workflows from several repositories one after another, with gaps
//
// For each step: start the workflow (workflow_dispatch), find the run it created, then watch the run and every job in
// it (e.g. each shard) until GitHub says it's completed. Success (or "continue on failure") → wait the gap → next step.
//   GET /repos/{r}/actions/workflows/{id}/runs?event=workflow_dispatch&per_page=10   (find the new run)
//   GET /repos/{r}/actions/runs/{run_id}                                             (run status)
//   GET /repos/{r}/actions/runs/{run_id}/jobs?per_page=100                            (each job and its steps)
//   POST /repos/{r}/actions/runs/{run_id}/cancel                                      (Stop + cancel on GitHub)

struct ChainStep: Identifiable, Codable, Equatable {
    var id = UUID()
    var repoID: UUID
    var workflowID: Int
    var workflowName: String
}

struct ScraperChain: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "New chain"
    var steps: [ChainStep] = []
    var gapMinutes = 5
    var continueOnFailure = false
    var maxHours = 6                 // give up waiting on one step after this long
    var auto = false
    var at = 16 * 60 + 35            // IST, weekdays
    var lastAutoDay = ""
}

struct GHJobStep: Decodable, Hashable { let name: String; let status: String?; let conclusion: String?; let number: Int }
struct GHJob: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?
    let started_at: String?
    let completed_at: String?
    let steps: [GHJobStep]?
}

enum StepPhase: Equatable {
    case waiting, starting, finding, queued, running, gap(until: Date), success, failed(String), skipped, stopped

    var label: String {
        switch self {
        case .waiting: return "waiting"
        case .starting: return "starting…"
        case .finding: return "finding the run…"
        case .queued: return "queued on GitHub"
        case .running: return "running"
        case .gap(let u): return "gap until \(u.formatted(date: .omitted, time: .shortened))"
        case .success: return "done ✓"
        case .failed(let m): return "failed: \(m)"
        case .skipped: return "skipped"
        case .stopped: return "stopped"
        }
    }
    var color: Color {
        switch self {
        case .success: return .green
        case .failed: return .red
        case .running, .queued, .starting, .finding: return .orange
        case .gap: return .blue
        default: return .secondary
        }
    }
}

struct StepLive: Equatable {
    var phase: StepPhase = .waiting
    var runID: Int?
    var runURL: String?
    var jobs: [GHJob] = []
    var started: Date?
    var ended: Date?
}

extension ScraperCenter {
    private static let iso = ISO8601DateFormatter()

    static func loadChains() -> [ScraperChain] {
        (UserDefaults.standard.data(forKey: "gh.chains")).flatMap { try? JSONDecoder().decode([ScraperChain].self, from: $0) } ?? []
    }
    func saveChains() { UserDefaults.standard.set(try? JSONEncoder().encode(chains), forKey: "gh.chains") }
    func chain(_ id: UUID) -> ScraperChain? { chains.first { $0.id == id } }
    func updateChain(_ id: UUID, _ f: (inout ScraperChain) -> Void) {
        if let i = chains.firstIndex(where: { $0.id == id }) { f(&chains[i]); saveChains() }
    }

    private func setStep(_ c: UUID, _ s: UUID, _ f: (inout StepLive) -> Void) {
        var m = live[c] ?? [:]
        var v = m[s] ?? StepLive()
        f(&v); m[s] = v; live[c] = m
    }

    func startChain(_ id: UUID) {
        guard let c = chain(id), !c.steps.isEmpty, !chainRunning.contains(id) else { return }
        chainRunning.insert(id)
        live[id] = Dictionary(uniqueKeysWithValues: c.steps.map { ($0.id, StepLive()) })
        chainStatus[id] = "Started \(Date().formatted(date: .omitted, time: .shortened))"
        chainTasks[id] = Task { [weak self] in
            await self?.execute(id)
            self?.chainRunning.remove(id)
        }
    }

    /// Stops watching; with `cancelOnGitHub` also cancels the run in progress.
    func stopChain(_ id: UUID, cancelOnGitHub: Bool) {
        chainTasks[id]?.cancel()
        chainRunning.remove(id)
        guard let c = chain(id) else { return }
        for s in c.steps {
            let l = live[id]?[s.id]
            switch l?.phase {
            case .starting?, .finding?, .queued?, .running?, .gap?:
                setStep(id, s.id) { $0.phase = .stopped; $0.ended = Date() }
                if cancelOnGitHub, let run = l?.runID, let r = repo(s.repoID) {
                    Task { _ = try? await request(r, "/repos/\(r.repo)/actions/runs/\(run)/cancel", method: "POST") }
                }
            case .waiting?: setStep(id, s.id) { $0.phase = .skipped }
            default: break
            }
        }
        chainStatus[id] = "Stopped \(Date().formatted(date: .omitted, time: .shortened))"
    }

    private func pause(seconds: Double) async -> Bool {
        var left = seconds
        while left > 0 {
            if Task.isCancelled { return false }
            let s = min(5, left)
            try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            left -= s
        }
        return !Task.isCancelled
    }

    private func execute(_ id: UUID) async {
        guard let c = chain(id) else { return }
        for (k, step) in c.steps.enumerated() {
            if Task.isCancelled { return }
            if k > 0 && c.gapMinutes > 0 {
                let until = Date().addingTimeInterval(Double(c.gapMinutes) * 60)
                setStep(id, step.id) { $0.phase = .gap(until: until) }
                chainStatus[id] = "Gap before step \(k + 1)…"
                guard await pause(seconds: Double(c.gapMinutes) * 60) else { return }
            }
            let ok = await runStep(id, step, chain: c)
            if Task.isCancelled { return }
            if !ok && !c.continueOnFailure {
                for later in c.steps.dropFirst(k + 1) { setStep(id, later.id) { $0.phase = .skipped } }
                chainStatus[id] = "Stopped at step \(k + 1) (\(step.workflowName)) — it didn't succeed."
                return
            }
        }
        chainStatus[id] = "Finished \(Date().formatted(date: .omitted, time: .shortened))"
    }

    /// Starts one workflow, finds its run, and follows it (and its jobs) to the end. true = succeeded.
    private func runStep(_ cid: UUID, _ step: ChainStep, chain c: ScraperChain) async -> Bool {
        guard let r = repo(step.repoID) else { setStep(cid, step.id) { $0.phase = .failed("repository removed") }; return false }
        chainStatus[cid] = "Step: \(r.repo) · \(step.workflowName)"
        setStep(cid, step.id) { $0.phase = .starting; $0.started = Date() }
        let t0 = Date().addingTimeInterval(-20)
        do {
            let (data, code) = try await request(r, "/repos/\(r.repo)/actions/workflows/\(step.workflowID)/dispatches", method: "POST", body: ["ref": r.ref])
            guard code == 204 else { setStep(cid, step.id) { $0.phase = .failed(explain(code, data, ref: r.ref)); $0.ended = Date() }; return false }
        } catch { setStep(cid, step.id) { $0.phase = .failed(error.localizedDescription); $0.ended = Date() }; return false }

        // find the run GitHub created for this start
        setStep(cid, step.id) { $0.phase = .finding }
        var runID: Int?
        for _ in 0..<30 {
            guard await pause(seconds: 4) else { return false }
            struct L: Decodable { let workflow_runs: [GHRunFull] }
            if let res = try? await request(r, "/repos/\(r.repo)/actions/workflows/\(step.workflowID)/runs?event=workflow_dispatch&per_page=10"),
               res.1 == 200, let l = try? JSONDecoder().decode(L.self, from: res.0) {
                let fresh = l.workflow_runs.filter { ($0.created_at.flatMap { Self.iso.date(from: $0) } ?? .distantPast) >= t0 }
                if let first = fresh.min(by: { ($0.created_at ?? "") < ($1.created_at ?? "") }) {
                    runID = first.id
                    setStep(cid, step.id) { $0.runID = first.id; $0.runURL = first.html_url }
                    break
                }
            }
        }
        guard let run = runID else { setStep(cid, step.id) { $0.phase = .failed("GitHub didn't show the new run within 2 minutes"); $0.ended = Date() }; return false }

        // follow the run and its jobs
        let deadline = Date().addingTimeInterval(Double(max(1, c.maxHours)) * 3600)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if let res = try? await request(r, "/repos/\(r.repo)/actions/runs/\(run)"), res.1 == 200,
               let info = try? JSONDecoder().decode(GHRunFull.self, from: res.0) {
                struct J: Decodable { let jobs: [GHJob] }
                if let jr = try? await request(r, "/repos/\(r.repo)/actions/runs/\(run)/jobs?per_page=100"), jr.1 == 200,
                   let j = try? JSONDecoder().decode(J.self, from: jr.0) {
                    setStep(cid, step.id) { $0.jobs = j.jobs }
                }
                if info.status == "completed" {
                    let good = info.conclusion == "success"
                    setStep(cid, step.id) { $0.phase = good ? .success : .failed(info.conclusion ?? "unknown"); $0.ended = Date() }
                    return good
                }
                setStep(cid, step.id) { $0.phase = info.status == "in_progress" ? .running : .queued }
            }
            guard await pause(seconds: 20) else { return false }
        }
        setStep(cid, step.id) { $0.phase = .failed("still not finished after \(c.maxHours) h"); $0.ended = Date() }
        return false
    }

    /// From runIfDue(): chains with a daily time, weekdays, once a day (within 3 hours of the time).
    func chainsIfDue(now: Int, today: String) {
        for c in chains where c.auto && !c.steps.isEmpty && !chainRunning.contains(c.id) && now >= c.at && now < c.at + 180 && c.lastAutoDay != today {
            updateChain(c.id) { $0.lastAutoDay = today }
            startChain(c.id)
        }
    }
}

struct GHRunFull: Decodable {
    let id: Int
    let status: String?
    let conclusion: String?
    let created_at: String?
    let html_url: String?
}

// MARK: - Window: Chains tab

struct ChainsView: View {
    @ObservedObject private var sc = ScraperCenter.shared
    @State private var current: UUID?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $current) {
                    ForEach(sc.chains) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).fontWeight(.medium).lineLimit(1)
                                Text("\(c.steps.count) steps · \(c.gapMinutes) min gaps" + (c.auto ? String(format: " · %02d:%02d IST", c.at / 60, c.at % 60) : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if sc.chainRunning.contains(c.id) { ProgressView().controlSize(.mini) }
                        }
                        .tag(c.id)
                    }
                }
                Divider()
                HStack {
                    Button { let c = ScraperChain(); sc.chains.append(c); sc.saveChains(); current = c.id } label: { Image(systemName: "plus") }
                    Button {
                        if let id = current { sc.stopChain(id, cancelOnGitHub: false); sc.chains.removeAll { $0.id == id }; sc.saveChains(); current = sc.chains.first?.id }
                    } label: { Image(systemName: "minus") }.disabled(current == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)

            Group {
                if let id = current, sc.chain(id) != nil { ChainPanel(id: id).id(id) }
                else {
                    Text(sc.chains.isEmpty ? "Click + to make a chain: workflows from your repositories, run one after another." : "Pick a chain.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 640)
        }
        .onAppear { if current == nil { current = sc.chains.first?.id } }
    }
}

private struct ChainPanel: View {
    let id: UUID
    @ObservedObject private var sc = ScraperCenter.shared
    @State private var addRepo: UUID?
    @State private var addWorkflow: Int?
    private static let times: [Int] = Array(stride(from: 6 * 60, through: 23 * 60 + 55, by: 5))

    private var c: ScraperChain { sc.chain(id) ?? ScraperChain() }
    private func bind<T>(_ k: WritableKeyPath<ScraperChain, T>) -> Binding<T> {
        Binding(get: { c[keyPath: k] }, set: { v in sc.updateChain(id) { $0[keyPath: k] = v } })
    }
    private var running: Bool { sc.chainRunning.contains(id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Chain name", text: bind(\.name)).textFieldStyle(.roundedBorder).font(.title3).frame(width: 300)
                    Spacer()
                    if running {
                        Button { sc.stopChain(id, cancelOnGitHub: false) } label: { Label("Stop", systemImage: "stop.fill") }
                            .help("Stop the chain here (the run in progress on GitHub carries on)")
                        Button(role: .destructive) { sc.stopChain(id, cancelOnGitHub: true) } label: { Label("Stop + cancel run", systemImage: "xmark.octagon") }
                            .help("Stop the chain and cancel the run in progress on GitHub")
                    } else {
                        Button { sc.startChain(id) } label: { Label("Run chain now", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).disabled(c.steps.isEmpty)
                    }
                }

                GroupBox("Steps — one after another") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(c.steps.enumerated()), id: \.element.id) { k, s in
                            stepRow(k, s)
                            if k < c.steps.count - 1 {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down").foregroundStyle(.secondary)
                                    Text("when it finishes\(c.continueOnFailure ? "" : " successfully"), wait \(c.gapMinutes) min").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.leading, 26)
                            }
                        }
                        if c.steps.isEmpty { Text("Add steps below.").foregroundStyle(.secondary) }
                        Divider()
                        HStack {
                            Picker("Repository", selection: $addRepo) {
                                Text("Repository…").tag(UUID?.none)
                                ForEach(sc.repos) { r in Text(r.title).tag(UUID?.some(r.id)) }
                            }
                            .fixedSize()
                            if let rid = addRepo {
                                let wfs = sc.workflows[rid] ?? []
                                if wfs.isEmpty {
                                    Button("Load its workflows") { Task { await sc.loadWorkflows(rid) } }
                                } else {
                                    Picker("Workflow", selection: $addWorkflow) {
                                        Text("Workflow…").tag(Int?.none)
                                        ForEach(wfs) { w in Text(w.name).tag(Int?.some(w.id)) }
                                    }
                                    .fixedSize()
                                    Button { add(rid, wfs) } label: { Label("Add step", systemImage: "plus") }.disabled(addWorkflow == nil)
                                    Button("Add all \(wfs.count)") { for w in wfs { addStep(rid, w) } }
                                }
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Rules") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Gap between steps")
                            Stepper("\(c.gapMinutes) min", value: bind(\.gapMinutes), in: 0...240, step: 1).fixedSize()
                            ForEach([0, 2, 5, 10, 15, 30], id: \.self) { m in Button("\(m)") { sc.updateChain(id) { $0.gapMinutes = m } }.controlSize(.small) }
                        }
                        Toggle("Carry on to the next step even if one fails", isOn: bind(\.continueOnFailure)).toggleStyle(.checkbox)
                        HStack {
                            Text("Give up waiting on a step after")
                            Stepper("\(c.maxHours) h", value: bind(\.maxHours), in: 1...24).fixedSize()
                        }
                        HStack {
                            Toggle("Run this chain every weekday at", isOn: bind(\.auto)).toggleStyle(.checkbox)
                            Picker("", selection: bind(\.at)) {
                                ForEach(Self.times, id: \.self) { m in Text(String(format: "%02d:%02d IST", m / 60, m % 60)).tag(m) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Text("A step counts as finished when GitHub marks its run completed (every job in it). The app checks every 20 s; it has to stay open with the Mac awake while a chain runs.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                }

                if let s = sc.chainStatus[id] { Text(s).font(.callout).foregroundStyle(.secondary) }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func stepRow(_ k: Int, _ s: ChainStep) -> some View {
        let l = sc.live[id]?[s.id] ?? StepLive()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(k + 1)").font(.caption.bold().monospacedDigit()).frame(width: 18)
                Circle().fill(l.phase.color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.workflowName).fontWeight(.medium)
                    Text(sc.repo(s.repoID)?.title ?? "removed repository").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(l.phase.label).font(.caption).foregroundStyle(l.phase.color).lineLimit(1)
                if let st = l.started {
                    Text(duration(st, l.ended ?? Date())).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let u = l.runURL.flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless)
                }
                if !running {
                    Button { move(k, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(k == 0)
                    Button { move(k, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(k == c.steps.count - 1)
                    Button { sc.updateChain(id) { $0.steps.remove(at: k) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            if !l.jobs.isEmpty {
                let done = l.jobs.filter { $0.status == "completed" }.count
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jobs: \(done) of \(l.jobs.count) finished").font(.caption2.bold()).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6, lineSpacing: 4) {
                        ForEach(l.jobs) { j in
                            HStack(spacing: 4) {
                                Circle().fill(jobColor(j)).frame(width: 7, height: 7)
                                Text(j.name).font(.caption2).lineLimit(1)
                                Text(jobLabel(j)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.1)))
                            .help(j.steps.map { st in st.map { "\($0.number). \($0.name): \($0.conclusion ?? $0.status ?? "")" }.joined(separator: "\n") } ?? j.name)
                        }
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(.vertical, 3)
    }

    private func add(_ rid: UUID, _ wfs: [GHWorkflow]) {
        guard let wid = addWorkflow, let w = wfs.first(where: { $0.id == wid }) else { return }
        addStep(rid, w)
        addWorkflow = nil
    }
    private func addStep(_ rid: UUID, _ w: GHWorkflow) {
        sc.updateChain(id) { $0.steps.append(ChainStep(repoID: rid, workflowID: w.id, workflowName: w.name)) }
    }
    private func move(_ k: Int, _ d: Int) {
        sc.updateChain(id) { ch in let j = k + d; guard ch.steps.indices.contains(j) else { return }; ch.steps.swapAt(k, j) }
    }
    private func duration(_ a: Date, _ b: Date) -> String {
        let s = Int(b.timeIntervalSince(a)); return s >= 3600 ? String(format: "%dh %02dm", s / 3600, s % 3600 / 60) : String(format: "%dm %02ds", s / 60, s % 60)
    }
    private func jobLabel(_ j: GHJob) -> String {
        if j.status == "completed" { return j.conclusion ?? "done" }
        if j.status == "in_progress", let cur = j.steps?.first(where: { $0.status == "in_progress" }) { return cur.name }
        return j.status ?? ""
    }
    private func jobColor(_ j: GHJob) -> Color {
        if j.status != "completed" { return j.status == "in_progress" ? .orange : .secondary }
        return j.conclusion == "success" ? .green : .red
    }
}
