import SwiftUI
import AppKit

// MARK: - Chains: steps one after another with gaps; each step = one or more workflows started together
//
// For each step: start every workflow in it (workflow_dispatch), find the run each one created, and follow every run
// and every job inside it (e.g. each shard) until GitHub marks them completed. All succeeded (or "carry on") →
// wait the gap → next step.
//   GET /repos/{r}/actions/workflows/{id}/runs?event=workflow_dispatch&per_page=10   (find the new run)
//   GET /repos/{r}/actions/runs/{run_id}                                             (run status)
//   GET /repos/{r}/actions/runs/{run_id}/jobs?per_page=100                            (each job and its steps)
//   POST /repos/{r}/actions/runs/{run_id}/cancel                                      (Stop + cancel on GitHub)

struct ChainItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var repoID: UUID
    var workflowID: Int
    var workflowName: String
}

struct ChainStep: Identifiable, Codable, Equatable {
    var id = UUID()
    var items: [ChainItem] = []          // run together (in parallel)

    init(id: UUID = UUID(), items: [ChainItem]) { self.id = id; self.items = items }
    // older chains stored one workflow per step
    private enum K: String, CodingKey { case id, items, repoID, workflowID, workflowName }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        if let it = try? c.decode([ChainItem].self, forKey: .items) { items = it }
        else if let r = try? c.decode(UUID.self, forKey: .repoID), let w = try? c.decode(Int.self, forKey: .workflowID) {
            items = [ChainItem(repoID: r, workflowID: w, workflowName: (try? c.decode(String.self, forKey: .workflowName)) ?? "workflow")]
        }
    }
    func encode(to e: Encoder) throws { var c = e.container(keyedBy: K.self); try c.encode(id, forKey: .id); try c.encode(items, forKey: .items) }
}

struct ScraperChain: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "New chain"
    var steps: [ChainStep] = []
    var gapMinutes = 5
    var continueOnFailure = false
    var maxHours = 6
    var auto = false
    var at = 16 * 60 + 35
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

struct GHRunFull: Decodable {
    let id: Int
    let status: String?
    let conclusion: String?
    let created_at: String?
    let html_url: String?
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
    var active: Bool {
        switch self { case .starting, .finding, .queued, .running, .gap: return true; default: return false }
    }
}

/// Live state of one workflow (item) in a running chain; a step's gap is kept on its first item.
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

    fileprivate func setItem(_ c: UUID, _ s: UUID, _ f: (inout StepLive) -> Void) {
        var m = live[c] ?? [:]
        var v = m[s] ?? StepLive()
        f(&v); m[s] = v; live[c] = m
    }

    func startChain(_ id: UUID) {
        guard let c = chain(id), !c.steps.isEmpty, !chainRunning.contains(id) else { return }
        chainRunning.insert(id)
        live[id] = Dictionary(uniqueKeysWithValues: c.steps.flatMap(\.items).map { ($0.id, StepLive()) })
        chainGap[id] = nil
        chainStatus[id] = "Started \(Date().formatted(date: .omitted, time: .shortened))"
        chainTasks[id] = Task { [weak self] in
            await self?.execute(id)
            self?.chainRunning.remove(id)
            self?.chainGap[id] = nil
        }
    }

    func stopChain(_ id: UUID, cancelOnGitHub: Bool) {
        chainTasks[id]?.cancel()
        chainRunning.remove(id)
        chainGap[id] = nil
        guard let c = chain(id) else { return }
        for it in c.steps.flatMap(\.items) {
            let l = live[id]?[it.id]
            if l?.phase.active == true {
                setItem(id, it.id) { $0.phase = .stopped; $0.ended = Date() }
                if cancelOnGitHub, let run = l?.runID, let r = repo(it.repoID) {
                    Task { _ = try? await request(r, "/repos/\(r.repo)/actions/runs/\(run)/cancel", method: "POST") }
                }
            } else if l?.phase == .waiting { setItem(id, it.id) { $0.phase = .skipped } }
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
                chainGap[id] = (step.id, Date().addingTimeInterval(Double(c.gapMinutes) * 60))
                chainStatus[id] = "Gap before step \(k + 1)…"
                guard await pause(seconds: Double(c.gapMinutes) * 60) else { return }
                chainGap[id] = nil
            }
            chainStatus[id] = "Step \(k + 1) of \(c.steps.count): \(step.items.map(\.workflowName).joined(separator: " + "))"
            let ok = await runStep(id, step, chain: c)
            if Task.isCancelled { return }
            if !ok && !c.continueOnFailure {
                for later in c.steps.dropFirst(k + 1) { for it in later.items { setItem(id, it.id) { $0.phase = .skipped } } }
                chainStatus[id] = "Stopped at step \(k + 1) — it didn't fully succeed."
                return
            }
        }
        chainStatus[id] = "Finished \(Date().formatted(date: .omitted, time: .shortened))"
    }

    /// Starts every workflow of the step together, then follows all their runs to the end. true = all succeeded.
    private func runStep(_ cid: UUID, _ step: ChainStep, chain c: ScraperChain) async -> Bool {
        var runs: [UUID: Int] = [:]           // item → run id
        var allOK = true
        // start them all
        var t0: [UUID: Date] = [:]
        for it in step.items {
            guard let r = repo(it.repoID) else { setItem(cid, it.id) { $0.phase = .failed("repository removed") }; allOK = false; continue }
            setItem(cid, it.id) { $0.phase = .starting; $0.started = Date() }
            t0[it.id] = Date().addingTimeInterval(-20)
            do {
                let (data, code) = try await request(r, "/repos/\(r.repo)/actions/workflows/\(it.workflowID)/dispatches", method: "POST", body: ["ref": r.ref])
                if code == 204 { setItem(cid, it.id) { $0.phase = .finding } }
                else { setItem(cid, it.id) { $0.phase = .failed(explain(code, data, ref: r.ref)); $0.ended = Date() }; allOK = false }
            } catch { setItem(cid, it.id) { $0.phase = .failed(error.localizedDescription); $0.ended = Date() }; allOK = false }
        }
        // find each run
        for _ in 0..<30 {
            let missing = step.items.filter { runs[$0.id] == nil && live[cid]?[$0.id]?.phase == .finding }
            if missing.isEmpty { break }
            guard await pause(seconds: 4) else { return false }
            for it in missing {
                guard let r = repo(it.repoID) else { continue }
                struct L: Decodable { let workflow_runs: [GHRunFull] }
                if let res = try? await request(r, "/repos/\(r.repo)/actions/workflows/\(it.workflowID)/runs?event=workflow_dispatch&per_page=10"),
                   res.1 == 200, let l = try? JSONDecoder().decode(L.self, from: res.0) {
                    let since = t0[it.id] ?? .distantPast
                    let fresh = l.workflow_runs.filter { ($0.created_at.flatMap { Self.iso.date(from: $0) } ?? .distantPast) >= since && !runs.values.contains($0.id) }
                    if let first = fresh.min(by: { ($0.created_at ?? "") < ($1.created_at ?? "") }) {
                        runs[it.id] = first.id
                        setItem(cid, it.id) { $0.runID = first.id; $0.runURL = first.html_url; $0.phase = .queued }
                    }
                }
            }
        }
        for it in step.items where runs[it.id] == nil && live[cid]?[it.id]?.phase == .finding {
            setItem(cid, it.id) { $0.phase = .failed("GitHub didn't show the new run within 2 minutes"); $0.ended = Date() }
            allOK = false
        }
        // follow every run and its jobs
        let deadline = Date().addingTimeInterval(Double(max(1, c.maxHours)) * 3600)
        var open = Set(runs.keys)
        while !open.isEmpty && Date() < deadline {
            if Task.isCancelled { return false }
            for itemID in open {
                guard let it = step.items.first(where: { $0.id == itemID }), let r = repo(it.repoID), let run = runs[itemID] else { open.remove(itemID); continue }
                guard let res = try? await request(r, "/repos/\(r.repo)/actions/runs/\(run)"), res.1 == 200,
                      let info = try? JSONDecoder().decode(GHRunFull.self, from: res.0) else { continue }
                struct J: Decodable { let jobs: [GHJob] }
                if let jr = try? await request(r, "/repos/\(r.repo)/actions/runs/\(run)/jobs?per_page=100"), jr.1 == 200,
                   let j = try? JSONDecoder().decode(J.self, from: jr.0) {
                    setItem(cid, itemID) { $0.jobs = j.jobs }
                }
                if info.status == "completed" {
                    let good = info.conclusion == "success"
                    if !good { allOK = false }
                    setItem(cid, itemID) { $0.phase = good ? .success : .failed(info.conclusion ?? "unknown"); $0.ended = Date() }
                    open.remove(itemID)
                } else {
                    setItem(cid, itemID) { $0.phase = info.status == "in_progress" ? .running : .queued }
                }
            }
            if open.isEmpty { break }
            guard await pause(seconds: 20) else { return false }
        }
        for itemID in open {
            setItem(cid, itemID) { $0.phase = .failed("still not finished after \(c.maxHours) h"); $0.ended = Date() }
            allOK = false
        }
        return allOK
    }

    func chainsIfDue(now: Int, today: String) {
        for c in chains where c.auto && !c.steps.isEmpty && !chainRunning.contains(c.id) && now >= c.at && now < c.at + 180 && c.lastAutoDay != today {
            updateChain(c.id) { $0.lastAutoDay = today }
            startChain(c.id)
        }
    }
}

// MARK: - Chains tab

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
                            Spacer(minLength: 0)
                            if sc.chainRunning.contains(c.id) { ProgressView().controlSize(.mini) }
                        }
                        .tag(c.id)
                    }
                }
                Divider()
                HStack {
                    Button { let c = ScraperChain(); sc.chains.append(c); sc.saveChains(); current = c.id } label: { Label("New chain", systemImage: "plus") }
                    Spacer()
                    Button {
                        if let id = current { sc.stopChain(id, cancelOnGitHub: false); sc.chains.removeAll { $0.id == id }; sc.saveChains(); current = sc.chains.first?.id }
                    } label: { Label("Delete", systemImage: "minus") }.disabled(current == nil)
                }
                .buttonStyle(.borderless).controlSize(.small).padding(8)
            }
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 360)

            Group {
                if let id = current, sc.chain(id) != nil { ChainPanel(id: id).id(id) }
                else {
                    VStack(spacing: 10) {
                        Text(sc.chains.isEmpty ? "A chain runs workflows from your repositories one step after another — each step can start several at once." : "Pick a chain.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                        if sc.chains.isEmpty {
                            Button { let c = ScraperChain(); sc.chains.append(c); sc.saveChains(); current = c.id } label: { Label("New chain", systemImage: "plus") }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if current == nil { current = sc.chains.first?.id } }
    }
}

private struct ChainPanel: View {
    let id: UUID
    @ObservedObject private var sc = ScraperCenter.shared
    @State private var addRepo: UUID?
    @State private var addPicked = Set<Int>()
    @State private var addTo = -1               // -1 = new step, else that step's index (run together)
    private static let times: [Int] = Array(stride(from: 6 * 60, through: 23 * 60 + 55, by: 5))

    private var c: ScraperChain { sc.chain(id) ?? ScraperChain() }
    private func bind<T>(_ k: WritableKeyPath<ScraperChain, T>) -> Binding<T> {
        Binding(get: { c[keyPath: k] }, set: { v in sc.updateChain(id) { $0[keyPath: k] = v } })
    }
    private var running: Bool { sc.chainRunning.contains(id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    TextField("Chain name", text: bind(\.name)).textFieldStyle(.roundedBorder).font(.title3).frame(width: 260)
                    if running {
                        Button { sc.stopChain(id, cancelOnGitHub: false) } label: { Label("Stop", systemImage: "stop.fill") }
                            .help("Stop the chain here (runs in progress on GitHub carry on)")
                        Button(role: .destructive) { sc.stopChain(id, cancelOnGitHub: true) } label: { Label("Stop + cancel runs", systemImage: "xmark.octagon") }
                            .help("Stop the chain and cancel the runs in progress on GitHub")
                    } else {
                        Button { sc.startChain(id) } label: { Label("Run chain now", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).disabled(c.steps.isEmpty)
                    }
                }
                if let s = sc.chainStatus[id] { Text(s).font(.callout).foregroundStyle(.secondary) }

                GroupBox("Steps — one after another") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(c.steps.enumerated()), id: \.element.id) { k, s in
                            stepBox(k, s)
                            if k < c.steps.count - 1 {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down").foregroundStyle(.secondary)
                                    if let g = sc.chainGap[id], g.step == c.steps[k + 1].id {
                                        Text("gap until \(g.until.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.blue)
                                    } else {
                                        Text("when all of step \(k + 1) finish\(c.continueOnFailure ? "" : " successfully"), wait \(c.gapMinutes) min").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, 10)
                            }
                        }
                        if c.steps.isEmpty { Text("Add workflows below.").foregroundStyle(.secondary) }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !running { adder }

                GroupBox("Rules") {
                    VStack(alignment: .leading, spacing: 8) {
                        FlowLayout(spacing: 8, lineSpacing: 6) {
                            Text("Gap between steps")
                            Stepper("\(c.gapMinutes) min", value: bind(\.gapMinutes), in: 0...240).fixedSize()
                            ForEach([0, 2, 5, 10, 15, 30], id: \.self) { m in Button("\(m)") { sc.updateChain(id) { $0.gapMinutes = m } }.controlSize(.small) }
                        }
                        Toggle("Carry on to the next step even if something fails", isOn: bind(\.continueOnFailure)).toggleStyle(.checkbox)
                        FlowLayout(spacing: 8, lineSpacing: 6) {
                            Text("Give up waiting on a step after")
                            Stepper("\(c.maxHours) h", value: bind(\.maxHours), in: 1...24).fixedSize()
                        }
                        FlowLayout(spacing: 8, lineSpacing: 6) {
                            Toggle("Run this chain every weekday at", isOn: bind(\.auto)).toggleStyle(.checkbox)
                            Picker("", selection: bind(\.at)) {
                                ForEach(Self.times, id: \.self) { m in Text(String(format: "%02d:%02d IST", m / 60, m % 60)).tag(m) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Text("A step is finished when GitHub marks every run in it completed (all their jobs). The app checks every 20 s and has to stay open, with the Mac awake, while a chain runs.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Adding workflows

    private var adder: some View {
        GroupBox("Add workflows") {
            VStack(alignment: .leading, spacing: 8) {
                if sc.repos.isEmpty {
                    Text("Add your repositories in the Repositories tab first.").foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    Picker("Repository", selection: $addRepo) {
                        Text("Pick…").tag(UUID?.none)
                        ForEach(sc.repos) { r in Text(r.title).tag(UUID?.some(r.id)) }
                    }
                    .fixedSize()
                    Picker("Add as", selection: $addTo) {
                        Text("a new step").tag(-1)
                        ForEach(Array(c.steps.indices), id: \.self) { k in Text("together with step \(k + 1)").tag(k) }
                    }
                    .fixedSize()
                }
                if let rid = addRepo {
                    let wfs = sc.workflows[rid] ?? []
                    if wfs.isEmpty {
                        HStack {
                            Button("Load its workflows") { Task { await sc.loadWorkflows(rid) } }
                            if sc.busy.contains(rid) { ProgressView().controlSize(.small) }
                            if let s = sc.status[rid] { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    } else {
                        Text("Tick one or more — ticked ones start together (in parallel):").font(.caption).foregroundStyle(.secondary)
                        FlowLayout(spacing: 10, lineSpacing: 4) {
                            ForEach(wfs) { w in
                                Toggle(w.name, isOn: Binding(get: { addPicked.contains(w.id) }, set: { on in if on { addPicked.insert(w.id) } else { addPicked.remove(w.id) } }))
                                    .toggleStyle(.checkbox)
                            }
                        }
                        HStack {
                            Button { add(rid, wfs) } label: { Label(addTo < 0 ? "Add as a new step" : "Add to step \(addTo + 1)", systemImage: "plus") }
                                .buttonStyle(.borderedProminent).disabled(addPicked.isEmpty)
                            Button("Tick all") { addPicked = Set(wfs.map(\.id)) }
                            Button("None") { addPicked = [] }
                        }
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: addRepo) { _ in addPicked = [] }
    }

    private func add(_ rid: UUID, _ wfs: [GHWorkflow]) {
        let items = wfs.filter { addPicked.contains($0.id) }.map { ChainItem(repoID: rid, workflowID: $0.id, workflowName: $0.name) }
        guard !items.isEmpty else { return }
        sc.updateChain(id) { ch in
            if addTo >= 0, ch.steps.indices.contains(addTo) { ch.steps[addTo].items += items }
            else { ch.steps.append(ChainStep(items: items)) }
        }
        addPicked = []
    }

    // MARK: A step and its workflows

    @ViewBuilder private func stepBox(_ k: Int, _ s: ChainStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Step \(k + 1)").font(.callout.bold())
                if s.items.count > 1 { Text("\(s.items.count) together").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if !running {
                    Button { move(k, -1) } label: { Image(systemName: "chevron.up") }.disabled(k == 0)
                    Button { move(k, 1) } label: { Image(systemName: "chevron.down") }.disabled(k == c.steps.count - 1)
                    Button { sc.updateChain(id) { $0.steps.remove(at: k) } } label: { Image(systemName: "trash") }.help("Remove this step")
                }
            }
            .buttonStyle(.borderless)
            ForEach(s.items) { it in itemRow(k, it) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    @ViewBuilder private func itemRow(_ k: Int, _ it: ChainItem) -> some View {
        let l = sc.live[id]?[it.id] ?? StepLive()
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(l.phase.color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(it.workflowName).fontWeight(.medium).lineLimit(1)
                    Text(sc.repo(it.repoID)?.title ?? "removed repository").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(l.phase.label).font(.caption).foregroundStyle(l.phase.color).lineLimit(1).truncationMode(.tail)
                if let st = l.started { Text(duration(st, l.ended ?? Date())).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if let u = l.runURL.flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless)
                }
                if !running {
                    Button {
                        sc.updateChain(id) { ch in
                            ch.steps[k].items.removeAll { $0.id == it.id }
                            if ch.steps[k].items.isEmpty { ch.steps.remove(at: k) }
                        }
                    } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove this workflow from the step")
                }
            }
            if !l.jobs.isEmpty {
                let done = l.jobs.filter { $0.status == "completed" }.count
                Text("Jobs: \(done) of \(l.jobs.count) finished").font(.caption2.bold()).foregroundStyle(.secondary).padding(.leading, 17)
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    ForEach(l.jobs) { j in
                        HStack(spacing: 4) {
                            Circle().fill(jobColor(j)).frame(width: 7, height: 7)
                            Text(j.name).font(.caption2).lineLimit(1)
                            Text(jobLabel(j)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .help(j.steps.map { st in st.map { "\($0.number). \($0.name): \($0.conclusion ?? $0.status ?? "")" }.joined(separator: "\n") } ?? j.name)
                    }
                }
                .padding(.leading, 17)
            }
        }
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
