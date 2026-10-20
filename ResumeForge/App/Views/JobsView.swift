import SwiftUI

struct JobsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAdd = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selectedJobID) {
                    ForEach(store.data.jobs) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.title.isEmpty ? "Untitled job" : job.title).font(.headline).lineLimit(2)
                            if !job.company.isEmpty {
                                Text(job.company).font(.subheadline).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Pill(text: job.source)
                                if let st = job.stage, st != .done {
                                    StagePill(stage: st)
                                } else if job.tailored != nil {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Your resume is ready")
                                }
                                let open = job.gaps.filter { $0.status == .open }.count
                                if open > 0 { Pill(text: "\(open) gaps", color: .orange) }
                                Spacer()
                                Text(job.capturedAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(job.id)
                        .contextMenu {
                            Button("Run all steps in background") { store.enqueueAuto(job.id) }
                            Divider()
                            Button("Delete", role: .destructive) { store.deleteJob(job.id) }
                        }
                    }
                }
                Divider()
                AutoStatusBar()
                HStack {
                    Button { showAdd = true } label: { Label("Add job manually", systemImage: "plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text("Today: \(store.jobsCapturedToday)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Jobs captured today — matches the count on the Safari toolbar icon")
                }
                .padding(8)
            }
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)

            Group {
                if let id = store.selectedJobID, store.jobIndex(id) != nil {
                    JobDetailView(jobID: id).id(id)
                } else {
                    EmptyHint(icon: "safari",
                              title: store.data.jobs.isEmpty ? "No jobs yet" : "Pick a job",
                              message: "Open a job on Naukri or Wellfound in Safari, click the ResumeForge toolbar button, and press Send. It will appear here.")
                }
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showAdd) { AddJobSheet() }
    }
}

// MARK: - Job detail

struct JobDetailView: View {
    @EnvironmentObject var store: AppStore
    let jobID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case jd = "Job Description", benchmark = "Best Resume", gaps = "Missing Stories", mine = "My Resume"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .jd
    @State private var allowPlaceholders = UserDefaults.standard.bool(forKey: "allowPlaceholders")

    private var job: JobPosting? { store.jobIndex(jobID).map { store.data.jobs[$0] } }

    private func docBinding(_ kp: WritableKeyPath<JobPosting, ResumeDoc?>) -> Binding<ResumeDoc> {
        Binding(
            get: { store.jobIndex(jobID).flatMap { store.data.jobs[$0][keyPath: kp] } ?? ResumeDoc() },
            set: { v in if let i = store.jobIndex(jobID) { store.data.jobs[i][keyPath: kp] = v } })
    }

    var body: some View {
        if let job {
            VStack(alignment: .leading, spacing: 0) {
                header(job)
                stageBanner(job)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16).padding(.bottom, 10)
                .onAppear { if job.tailored != nil { tab = .mine } }
                Divider()
                switch tab {
                case .jd: jdTab(job)
                case .benchmark: benchmarkTab(job)
                case .gaps: gapsTab(job)
                case .mine: mineTab(job)
                }
            }
        }
    }

    @ViewBuilder
    private func stageBanner(_ job: JobPosting) -> some View {
        if let st = job.stage, st.isActive {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(st == .queued ? "Queued — will run in the background" : "Working in the background: \(st.label)")
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.bottom, 8)
        } else if let err = job.autoError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: job.stage == .failed ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(job.stage == .failed ? .orange : .secondary)
                Text(err).lineLimit(3).textSelection(.enabled)
                Spacer()
                if job.stage == .failed {
                    Button("Retry") { store.enqueueAuto(jobID) }
                }
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    private func header(_ job: JobPosting) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title.isEmpty ? "Untitled job" : job.title).font(.title2.bold())
                Text([job.company, job.location, job.experience, job.salary].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let url = URL(string: job.url), !job.url.isEmpty {
                Link(destination: url) { Label("Open posting", systemImage: "safari") }
            }
        }
        .padding(16)
    }

    // MARK: Tabs

    private func jdTab(_ job: JobPosting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        store.run("Cleaning up job description…") { try await store.parseJob(jobID) }
                    } label: { Label(job.parsed ? "Re-clean with AI" : "Clean up with AI", systemImage: "wand.and.stars") }
                    Button {
                        tab = .benchmark
                        store.run("Writing the best resume for this job…") { try await store.generateBenchmark(jobID) }
                    } label: { Label("Next: build the best resume", systemImage: "arrow.right.circle") }
                    .buttonStyle(.borderedProminent)
                    .disabled(job.description.isEmpty)
                }
                if !job.skills.isEmpty {
                    Text("Skills: " + job.skills.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                }
                if !job.keywords.isEmpty {
                    Text("ATS keywords: " + job.keywords.joined(separator: " · ")).font(.callout)
                }
                TextEditor(text: Binding(
                    get: { store.jobIndex(jobID).map { store.data.jobs[$0].description } ?? "" },
                    set: { v in if let i = store.jobIndex(jobID) { store.data.jobs[i].description = v } }))
                    .font(.body)
                    .frame(minHeight: 420)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func benchmarkTab(_ job: JobPosting) -> some View {
        if job.benchmark != nil {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        store.run("Rewriting the best resume…") { try await store.generateBenchmark(jobID) }
                    } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    Spacer()
                    Button {
                        tab = .gaps
                        store.run("Finding your missing stories…") { try await store.analyzeGaps(jobID) }
                    } label: { Label("Next: find my missing stories", systemImage: "arrow.right.circle") }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 10).padding(.top, 8)
                ResumePreview(doc: docBinding(\.benchmark), fileName: "Benchmark - \(job.title)")
            }
        } else {
            cta(icon: "target",
                title: "See what the best resume for this job looks like",
                message: "Groq writes the resume of the ideal candidate for this JD, in your reference format. It's the yardstick your own resume is measured against.",
                button: "Generate best resume") {
                store.run("Writing the best resume for this job…") { try await store.generateBenchmark(jobID) }
            }
        }
    }

    @ViewBuilder
    private func gapsTab(_ job: JobPosting) -> some View {
        if job.gaps.isEmpty {
            cta(icon: "puzzlepiece.extension",
                title: "Find the stories you haven't told yet",
                message: "Compares your stories with the best resume and the JD, then lists the evidence you're missing — with questions to draw each one out.",
                button: "Find missing stories") {
                store.run("Finding your missing stories…") { try await store.analyzeGaps(jobID) }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(job.gaps.filter { $0.status == .open }.count) open · \(job.gaps.filter { $0.status == .answered }.count) answered")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.run("Re-checking your stories…") { try await store.analyzeGaps(jobID) }
                        } label: { Label("Re-analyse", systemImage: "arrow.clockwise") }
                        Button {
                            tab = .mine
                            store.run("Writing your resume…") { try await store.buildTailored(jobID, allowPlaceholders: allowPlaceholders) }
                        } label: { Label("Build my resume", systemImage: "doc.badge.gearshape") }
                        .buttonStyle(.borderedProminent)
                    }
                    if !job.strengths.isEmpty {
                        Label("Already strong: " + job.strengths.joined(separator: "; "), systemImage: "hand.thumbsup")
                            .font(.callout).foregroundStyle(.green)
                    }
                    ForEach(job.gaps) { gap in GapCard(jobID: jobID, gap: gap) }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func mineTab(_ job: JobPosting) -> some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Mode", selection: $allowPlaceholders) {
                    Text("Facts from my stories only").tag(false)
                    Text("Allow [VERIFY] placeholders").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
                Button {
                    store.run("Writing your resume…") { try await store.buildTailored(jobID, allowPlaceholders: allowPlaceholders) }
                } label: { Label(job.tailored == nil ? "Build my resume" : "Rebuild", systemImage: "doc.badge.gearshape") }
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
            if job.tailored != nil {
                ResumePreview(doc: docBinding(\.tailored),
                              fileName: "\(store.data.profile.name.isEmpty ? "Resume" : store.data.profile.name) - \(job.company)",
                              missing: job.tailoredMissing)
            } else {
                EmptyHint(icon: "doc.text",
                          title: "Your resume for this job",
                          message: store.data.stories.isEmpty
                            ? "Add your profile and a few stories first (or import your current CV in Profile). Every line is built from what you've told the app."
                            : "Built from your \(store.data.stories.count) stories, framed for this JD. Strict mode never adds anything you didn't say.")
            }
        }
    }

    private func cta(icon: String, title: String, message: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            EmptyHint(icon: icon, title: title, message: message).frame(maxHeight: 260)
            Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(store.busy != nil)
            Spacer()
        }
    }
}

// MARK: - Gap card

struct GapCard: View {
    @EnvironmentObject var store: AppStore
    let jobID: UUID
    let gap: StoryGap

    private var color: Color {
        switch gap.priority { case "high": return .red; case "low": return .gray; default: return .orange }
    }

    private func setStatus(_ s: GapStatus) {
        guard let ji = store.jobIndex(jobID),
              let gi = store.data.jobs[ji].gaps.firstIndex(where: { $0.id == gap.id }) else { return }
        store.data.jobs[ji].gaps[gi].status = s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Pill(text: gap.priority, color: color)
                Text(gap.theme).font(.headline)
                Spacer()
                if gap.status != .open { Pill(text: gap.status.rawValue, color: gap.status == .answered ? .green : .gray) }
            }
            if !gap.whyItMatters.isEmpty { Text(gap.whyItMatters).font(.callout) }
            if !gap.benchmarkExample.isEmpty {
                Text("What strong looks like: " + gap.benchmarkExample)
                    .font(.callout).italic().foregroundStyle(.secondary)
            }
            if !gap.questions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(gap.questions, id: \.self) { Text("• " + $0).font(.callout) }
                }
            }
            HStack {
                Button {
                    store.startInterview(jobID: jobID, gapID: gap.id)
                } label: { Label("Answer in interview", systemImage: "bubble.left.and.bubble.right") }
                .buttonStyle(.borderedProminent)
                Button {
                    store.newStory(title: gap.theme)
                    store.section = .stories
                } label: { Label("Write it myself", systemImage: "square.and.pencil") }
                Spacer()
                if gap.status == .open {
                    Button("I don't have this") { setStatus(.skipped) }.buttonStyle(.borderless)
                } else {
                    Button("Reopen") { setStatus(.open) }.buttonStyle(.borderless)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .opacity(gap.status == .open ? 1 : 0.6)
    }
}

// MARK: - Manual add

struct AddJobSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var title = ""
    @State private var company = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a job").font(.title2.bold())
            Text("Paste the job description (or the JSON copied from the extension). Fields left empty are filled in by AI.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Job URL (optional)", text: $url)
            HStack {
                TextField("Title", text: $title)
                TextField("Company", text: $company)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func add() {
        var j = JobPosting()
        j.source = "manual"
        j.url = url
        j.title = title
        j.company = company
        // Accept the extension's "Copy as JSON" output too.
        if let d = text.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            let c = CapturedJob(dictionary: o)
            j.source = c.source; j.url = c.url.isEmpty ? url : c.url
            j.title = c.title.isEmpty ? title : c.title
            j.company = c.company.isEmpty ? company : c.company
            j.location = c.location; j.experience = c.experience; j.salary = c.salary
            j.skills = c.skills; j.description = c.description; j.rawText = c.rawText
        } else {
            j.rawText = text
            j.description = text
        }
        store.data.jobs.insert(j, at: 0)
        store.selectedJobID = j.id
        let id = j.id
        if store.autoProcessEnabled {
            store.enqueueAuto(id)
        } else {
            store.run("Cleaning up job description…") { try await store.parseJob(id) }
        }
        dismiss()
    }
}

// MARK: - Background status

struct StagePill: View {
    let stage: AutoStage
    var body: some View {
        HStack(spacing: 4) {
            if stage.isActive && stage != .queued { ProgressView().controlSize(.mini) }
            Pill(text: stage.label, color: stage == .failed ? .red : (stage == .queued ? .gray : .blue))
        }
    }
}

struct AutoStatusBar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if let paused = store.autoPaused {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                Text(paused).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Resume") { store.resumeAutoAfterPause() }.controlSize(.small)
            }
            .padding(8)
            Divider()
        } else if store.autoQueuedCount > 0 {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(store.autoQueuedCount) job\(store.autoQueuedCount == 1 ? "" : "s") processing in background")
                        .font(.caption.bold())
                    if let s = store.autoStatus {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(8)
            Divider()
        }
    }
}
