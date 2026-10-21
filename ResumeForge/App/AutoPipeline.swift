import Foundation

/// Runs new jobs through the steps automatically in the background, one job at a time:
/// clean up JD → Best Resume → Missing Stories → My Resume.
/// Stops at the depth chosen in Settings. Survives restarts (unfinished jobs resume on launch).
/// If Groq's daily allowance runs out, the queue pauses instead of failing every job.
enum AutoStage: String {
    case queued, cleaning, matching, benchmark, gaps, resume, done, failed

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .cleaning: return "Reading JD…"
        case .matching: return "Checking fit…"
        case .benchmark: return "Best resume…"
        case .gaps: return "Missing stories…"
        case .resume: return "Writing resume…"
        case .done: return "Ready"
        case .failed: return "Failed"
        }
    }

    var isActive: Bool { [.queued, .cleaning, .matching, .benchmark, .gaps, .resume].contains(self) }
}

/// How far automatic processing goes for each new job.
enum AutoDepth: Int, CaseIterable, Identifiable {
    case clean = 1, benchmark, gaps, resume
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .clean: return "Clean up the JD only"
        case .benchmark: return "…and write the Best Resume"
        case .gaps: return "…and find Missing Stories"
        case .resume: return "…and write My Resume (all steps)"
        }
    }
}

extension JobPosting {
    var stage: AutoStage? { autoStage.flatMap(AutoStage.init(rawValue:)) }
}

extension AppStore {

    static func registerAutoDefaults() {
        UserDefaults.standard.register(defaults: ["autoProcess": true, "autoDepth": AutoDepth.resume.rawValue])
    }

    var autoProcessEnabled: Bool { UserDefaults.standard.bool(forKey: "autoProcess") }
    var autoDepth: AutoDepth { AutoDepth(rawValue: UserDefaults.standard.integer(forKey: "autoDepth")) ?? .resume }

    var autoQueuedCount: Int { data.jobs.filter { $0.stage?.isActive == true }.count }

    // MARK: Queue

    func enqueueAuto(_ id: UUID) {
        guard let i = jobIndex(id) else { return }
        data.jobs[i].autoStage = AutoStage.queued.rawValue
        data.jobs[i].autoError = nil
        if !autoQueue.contains(id) { autoQueue.append(id) }
        startAutoWorker()
    }

    /// On launch: pick up jobs that were queued or mid-way when the app quit.
    func resumePendingAuto() {
        for j in data.jobs.reversed() where j.stage?.isActive == true && !autoQueue.contains(j.id) {
            autoQueue.append(j.id)
        }
        startAutoWorker()
    }

    func resumeAutoAfterPause() {
        autoPaused = nil
        resumePendingAuto()
    }

    func startAutoWorker() {
        guard autoWorker == nil, autoPaused == nil, !autoQueue.isEmpty else { return }
        guard ProviderSettings.anyKeyConfigured else {
            autoPaused = "Add an AI provider key in Settings to process jobs automatically."
            return
        }
        autoWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while let id = self.autoQueue.first {
                await self.processAuto(id)
                if self.autoPaused != nil { break }
                self.autoQueue.removeAll { $0 == id }
            }
            self.autoStatus = nil
            self.autoWorker = nil
        }
    }

    // MARK: One job

    private func setStage(_ id: UUID, _ stage: AutoStage, error: String? = nil) {
        guard let i = jobIndex(id) else { return }
        data.jobs[i].autoStage = stage.rawValue
        data.jobs[i].autoError = error
    }

    private func processAuto(_ id: UUID) async {
        let depth = autoDepth
        func job() -> JobPosting? { jobIndex(id).map { data.jobs[$0] } }
        func name() -> String { job().map { $0.title.isEmpty ? "job" : $0.title } ?? "job" }
        do {
            guard let j = job() else { return }

            // 1. Clean up the JD — skipped when the extension already got a full, labelled description.
            if !j.parsed {
                if j.description.count >= 600 && !j.title.isEmpty && !j.company.isEmpty {
                    if let i = jobIndex(id) { data.jobs[i].parsed = true }
                } else {
                    setStage(id, .cleaning); autoStatus = "Reading JD: \(name())"
                    try await parseJob(id)
                }
            }

            // 1b. Fit check (score + conflicts) — cheap, and tells you whether the rest is worth it.
            if job()?.match == nil {
                setStage(id, .matching); autoStatus = "Checking fit: \(name())"
                try await matchJob(id)
            }

            // 2. Best Resume
            if depth.rawValue >= AutoDepth.benchmark.rawValue, job()?.benchmark == nil {
                setStage(id, .benchmark); autoStatus = "Best resume: \(name())"
                try await generateBenchmark(id)
            }

            // 3. Missing Stories
            if depth.rawValue >= AutoDepth.gaps.rawValue, job()?.gaps.isEmpty == true {
                setStage(id, .gaps); autoStatus = "Missing stories: \(name())"
                try await analyzeGaps(id)
            }

            // 4. My Resume — needs your own material.
            if depth.rawValue >= AutoDepth.resume.rawValue, job()?.tailored == nil {
                if data.stories.isEmpty && data.profile.roles.isEmpty {
                    setStage(id, .done, error: "Add your profile or stories, then press Build my resume.")
                    return
                }
                setStage(id, .resume); autoStatus = "Writing your resume: \(name())"
                try await buildTailored(id, allowPlaceholders: allowPlaceholdersDefault)
            }
            setStage(id, .done)
        } catch {
            let msg = error.localizedDescription
            if msg.contains(AppStore.quotaMarker) {
                setStage(id, .queued)
                autoPaused = "Your AI providers are out of free quota — automatic processing is paused. It resumes when you relaunch the app or press Resume (or add another provider in Settings)."
            } else if msg.contains("Add an AI provider key") {
                setStage(id, .queued)
                autoPaused = "Add an AI provider key in Settings to process jobs automatically."
            } else if error is CancellationError {
                setStage(id, .queued)
            } else {
                setStage(id, .failed, error: msg)
            }
        }
    }
}
