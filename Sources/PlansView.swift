import AppKit
import SwiftUI

// MARK: - Plans (list + detail)

struct PlansView: View {
    let app: AppDelegate
    @ObservedObject var plans: PlanStore
    @ObservedObject var nav: Navigator

    var body: some View {
        HStack(spacing: 0) {
            PlanList(plans: plans, selection: $nav.selectedPlan) { app.startPlan(goal: "") }
                .frame(width: 270)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = nav.selectedPlan, let plan = plans.plan(id) {
            switch plan.status {
            case .drafting:
                PlanDraftView(app: app, plans: plans, nav: nav, planID: id).id(id)
            case .active:
                PlanRunView(app: app, plans: plans, planID: id).id(id)
            case .completed, .abandoned:
                PlanSummaryView(app: app, plans: plans, planID: id).id(id)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "checklist").font(.system(size: 44)).foregroundStyle(.tertiary)
                Text("Turn a goal into a chain of steps").font(.title3.weight(.semibold))
                Text("The coach suggests steps, you pick and add your own, then work through them.\nWhen the flow breaks, you'll find a way through together — and every outcome is remembered.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button { app.startPlan(goal: "") } label: { Label("New plan", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(40)
        }
    }
}

struct PlanList: View {
    @ObservedObject var plans: PlanStore
    @Binding var selection: UUID?
    let onNew: () -> Void

    private var active: [Plan] { plans.plans.filter { $0.status == .active }.sorted { $0.lastActivity > $1.lastActivity } }
    private var drafts: [Plan] { plans.plans.filter { $0.status == .drafting } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Plans").font(.title2.weight(.bold))
                Spacer()
                Button(action: onNew) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New plan")
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

            List(selection: $selection) {
                if !active.isEmpty {
                    Section("In progress") { ForEach(active) { PlanListRow(plan: $0).tag($0.id) } }
                }
                if !drafts.isEmpty {
                    Section("Drafts") { ForEach(drafts) { PlanListRow(plan: $0).tag($0.id) } }
                }
                if !plans.finished.isEmpty {
                    Section("Finished") { ForEach(plans.finished) { PlanListRow(plan: $0).tag($0.id) } }
                }
            }
            .listStyle(.inset)

            if !plans.finished.isEmpty || !plans.blockerStats.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    let done = plans.finished.filter { $0.status == .completed }.count
                    let stopped = plans.finished.count - done
                    Text("\(done) completed · \(stopped) stopped").font(.caption.weight(.semibold))
                    if let top = plans.blockerStats.first {
                        Text("Most common flow break: \(top.category) (\(top.count)×)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }
}

struct PlanListRow: View {
    let plan: Plan

    private var icon: (String, Color) {
        switch plan.status {
        case .drafting: return ("pencil.circle", .secondary)
        case .active: return (plan.steps.contains { $0.status == .blocked } ? "exclamationmark.circle.fill" : "play.circle.fill",
                              plan.steps.contains { $0.status == .blocked } ? .orange : .accentColor)
        case .completed: return ("checkmark.circle.fill", .green)
        case .abandoned: return ("xmark.circle", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.0).foregroundStyle(icon.1).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.goal.isEmpty ? "Untitled plan" : plan.goal).lineLimit(2)
                if plan.status != .drafting && !plan.steps.isEmpty {
                    ProgressView(value: plan.progress).controlSize(.small)
                    Text("\(plan.doneCount) of \(plan.steps.count) steps\(plan.blockers.isEmpty ? "" : " · \(plan.blockers.count) break\(plan.blockers.count == 1 ? "" : "s")")")
                        .font(.caption).foregroundStyle(.secondary)
                } else if plan.status == .drafting {
                    Text("Draft · \(plan.steps.filter { $0.status != .skipped }.count) steps picked")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 1. Draft: suggest, pick, add, order

struct DraftStep: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var minutes: Int?
    var why: String?
    var source: PlanStep.Source
    var included = true
}

struct PlanDraftView: View {
    let app: AppDelegate
    @ObservedObject var plans: PlanStore
    @ObservedObject var nav: Navigator
    let planID: UUID

    @State private var goal = ""
    @State private var drafts: [DraftStep] = []
    @State private var newStep = ""
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false

    private var picked: [DraftStep] { drafts.filter { $0.included && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
    private var totalMinutes: Int { picked.compactMap(\.minutes).reduce(0, +) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NEW PLAN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Goal", text: $goal, prompt: Text("What do you want to achieve?"), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.title.weight(.bold))
                    let suggestions = (app.goals.activeToday + app.goals.activeMonth).map(\.text)
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.self) { g in Button(g) { goal = g } }
                        } label: {
                            Label("Use one of my goals", systemImage: "target")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                stepGuide

                Card(title: "Steps", symbol: "list.number") {
                    if drafts.isEmpty && !loading {
                        Text("Ask the coach for a first breakdown, or add your own steps below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($drafts) { $d in
                        DraftRow(draft: $d,
                                 isFirst: d.id == drafts.first?.id,
                                 isLast: d.id == drafts.last?.id,
                                 onMove: { move(d.id, by: $0) },
                                 onDelete: { drafts.removeAll { $0.id == d.id } })
                    }
                    if loading {
                        HStack { ProgressView().controlSize(.small); Text("Breaking it down…").foregroundStyle(.secondary) }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    HStack {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        TextField("Add a missing step…", text: $newStep)
                            .textFieldStyle(.plain)
                            .onSubmit(addStep)
                        Button("Add", action: addStep)
                            .disabled(newStep.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 4)
                }

                HStack(spacing: 12) {
                    Button { Task { await suggest() } } label: {
                        Label(drafts.contains { $0.source == .ai } ? "Suggest again" : "Suggest steps", systemImage: "sparkles")
                    }
                    .disabled(loading || goal.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Delete draft", role: .destructive) {
                        plans.delete(planID)
                        nav.selectedPlan = nil
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text("\(picked.count) steps\(totalMinutes > 0 ? " · about \(durationText(Double(totalMinutes) * 60))" : "")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button { startPlan() } label: { Label("Start plan", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(picked.isEmpty || goal.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(28)
        }
        .onAppear(perform: load)
        .onChange(of: drafts) { _ in persist() }
        .onChange(of: goal) { _ in persist() }
    }

    private var stepGuide: some View {
        HStack(spacing: 18) {
            guideItem(1, "Suggest", "Coach proposes steps", active: drafts.isEmpty)
            guideItem(2, "Pick & add", "Untick what's not relevant, add what's missing", active: !drafts.isEmpty)
            guideItem(3, "Start", "Work the chain step by step", active: false)
        }
    }

    private func guideItem(_ n: Int, _ title: String, _ detail: String, active: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(active ? Color.accentColor : Color.secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func load() {
        guard !loaded, let plan = plans.plan(planID) else { return }
        loaded = true
        goal = plan.goal
        drafts = plan.steps.map {
            DraftStep(id: $0.id, text: $0.text, minutes: $0.minutes, why: $0.why, source: $0.source,
                      included: $0.status != .skipped)
        }
        if nav.autoSuggestPlan == planID {
            nav.autoSuggestPlan = nil
            Task { await suggest() }
        }
    }

    /// Drafts are saved on the plan: unticked steps are stored as "skipped".
    private func persist() {
        guard loaded else { return }
        plans.update(planID) { plan in
            plan.goal = goal
            plan.steps = drafts.map {
                PlanStep(id: $0.id, text: $0.text, minutes: $0.minutes, why: $0.why, source: $0.source,
                         status: $0.included ? .todo : .skipped)
            }
        }
    }

    private func suggest() async {
        let g = goal.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else { return }
        loading = true
        error = nil
        do {
            let mine = drafts.filter { $0.source == .user }
            let steps = try await app.coach.suggestPlanSteps(goal: g, existing: mine.map(\.text), plans: plans)
            // Replace previous AI suggestions, keep the user's own steps after them.
            drafts = steps.map { DraftStep(text: $0.text, minutes: $0.minutes, why: $0.why, source: .ai) } + mine
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func addStep() {
        let t = newStep.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        drafts.append(DraftStep(text: t, source: .user))
        newStep = ""
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < drafts.count else { return }
        drafts.swapAt(i, j)
    }

    private func startPlan() {
        let chosen = picked
        plans.update(planID) { plan in
            plan.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            plan.steps = chosen.map {
                PlanStep(id: $0.id, text: $0.text, minutes: $0.minutes, why: $0.why, source: $0.source)
            }
            plan.status = .active
            plan.startedAt = Date()
            let ai = chosen.filter { $0.source == .ai }.count
            plan.log(.started, "Started with \(chosen.count) steps (\(ai) suggested, \(chosen.count - ai) added by you)")
        }
    }
}

struct DraftRow: View {
    @Binding var draft: DraftStep
    let isFirst: Bool
    let isLast: Bool
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { draft.included.toggle() } label: {
                Image(systemName: draft.included ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(draft.included ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(draft.included ? "Not relevant — leave it out" : "Include this step")

            VStack(alignment: .leading, spacing: 2) {
                TextField("Step", text: $draft.text, prompt: Text("Describe the step"), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .foregroundStyle(draft.included ? Color.primary : Color.secondary)
                HStack(spacing: 6) {
                    if draft.source == .user {
                        Text("Added by you").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    if let why = draft.why, !why.isEmpty {
                        Text(why).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if let m = draft.minutes {
                Text("\(m)m").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 2) {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }.disabled(isFirst)
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }.disabled(isLast)
                Button(action: onDelete) { Image(systemName: "xmark") }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .opacity(draft.included ? 1 : 0.6)
    }
}

// MARK: - 2. Run: the chain

struct PlanRunView: View {
    let app: AppDelegate
    @ObservedObject var plans: PlanStore
    let planID: UUID

    @State private var blocked: StepRef?
    @State private var finishing: FinishRequest?
    @State private var newStep = ""
    @State private var stepNote = ""

    struct StepRef: Identifiable { let id: UUID }
    struct FinishRequest: Identifiable { let id = UUID(); let completed: Bool }

    var body: some View {
        if let plan = plans.plan(planID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(plan)
                    Card(title: "Chain", symbol: "point.3.connected.trianglepath.dotted") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { i, step in
                                ChainRow(step: step,
                                         number: i + 1,
                                         isCurrent: i == plan.currentIndex,
                                         isLast: i == plan.steps.count - 1,
                                         blockers: plan.blockers.filter { $0.stepID == step.id }) {
                                    if i == plan.currentIndex { controls(plan, step) }
                                }
                            }
                        }
                        HStack {
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            TextField("Add a step to the end…", text: $newStep)
                                .textFieldStyle(.plain)
                                .onSubmit { addStep() }
                            Button("Add") { addStep() }
                                .disabled(newStep.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.top, 6)
                    }

                    if !plan.blockers.isEmpty {
                        Card(title: "Flow breaks", symbol: "bolt.horizontal.circle") {
                            ForEach(plan.blockers.reversed()) { BlockerRow(blocker: $0) }
                        }
                    }

                    HStack {
                        Button("Stop plan…") { finishing = FinishRequest(completed: false) }
                        Spacer()
                        Button { finishing = FinishRequest(completed: true) } label: {
                            Label("Complete plan", systemImage: "flag.checkered")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(28)
            }
            .sheet(item: $blocked) { ref in
                BlockerSheet(app: app, plans: plans, planID: planID, stepID: ref.id)
            }
            .sheet(item: $finishing) { req in
                FinishSheet(app: app, plans: plans, planID: planID, completed: req.completed)
            }
        }
    }

    private func header(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IN PROGRESS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(plan.goal).font(.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                ProgressView(value: plan.progress).frame(width: 220)
                Text("\(plan.doneCount) of \(plan.steps.count) steps").monospacedDigit()
                if let s = plan.startedAt {
                    Text("· started \(s.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func controls(_ plan: Plan, _ step: PlanStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch step.status {
            case .todo:
                HStack {
                    Button { startStep(step) } label: { Label("Start this step", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    Button("Skip") { skip(step) }
                }
            case .doing:
                if let start = step.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Label("In progress · \(mmss(Int(Date().timeIntervalSince(start))))", systemImage: "timer")
                            .foregroundStyle(Color.accentColor)
                            .monospacedDigit()
                    }
                }
                TextField("Note (optional) — what you did or found", text: $stepNote)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button { done(step) } label: { Label("Done", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button { blocked = StepRef(id: step.id) } label: {
                        Label("Blocked…", systemImage: "exclamationmark.triangle")
                    }
                    Button("Skip") { skip(step) }
                }
            case .blocked:
                Label("Flow broke here.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HStack {
                    Button("Find a way through…") { blocked = StepRef(id: step.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Resume step") { resume(step) }
                    Button("Skip") { skip(step) }
                }
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
        .padding(.top, 6)
    }

    // MARK: Actions

    private func startStep(_ step: PlanStep) {
        plans.update(planID) { p in
            guard let i = p.steps.firstIndex(where: { $0.id == step.id }) else { return }
            p.steps[i].status = .doing
            p.steps[i].startedAt = Date()
            p.log(.stepStarted, "Started: \(step.text)", step: step.id)
        }
        stepNote = ""
    }

    private func done(_ step: PlanStep) {
        let note = stepNote.trimmingCharacters(in: .whitespacesAndNewlines)
        var allDone = false
        plans.update(planID) { p in
            guard let i = p.steps.firstIndex(where: { $0.id == step.id }) else { return }
            p.steps[i].status = .done
            p.steps[i].finishedAt = Date()
            if !note.isEmpty { p.steps[i].note = note }
            p.log(.stepDone, "Done: \(step.text)\(note.isEmpty ? "" : " — \(note)")", step: step.id)
            allDone = !p.steps.contains { $0.status == .todo || $0.status == .doing || $0.status == .blocked }
        }
        stepNote = ""
        if allDone { finishing = FinishRequest(completed: true) }
    }

    private func skip(_ step: PlanStep) {
        plans.update(planID) { p in
            guard let i = p.steps.firstIndex(where: { $0.id == step.id }) else { return }
            p.steps[i].status = .skipped
            p.steps[i].finishedAt = Date()
            p.log(.stepSkipped, "Skipped: \(step.text)", step: step.id)
        }
    }

    private func resume(_ step: PlanStep) {
        plans.update(planID) { p in
            guard let i = p.steps.firstIndex(where: { $0.id == step.id }) else { return }
            p.steps[i].status = .doing
            if p.steps[i].startedAt == nil { p.steps[i].startedAt = Date() }
            p.log(.resumed, "Resumed: \(step.text)", step: step.id)
        }
    }

    private func addStep() {
        let t = newStep.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        plans.update(planID) { p in
            let s = PlanStep(text: t, source: .user)
            p.steps.append(s)
            p.log(.stepAdded, "Added step: \(t)", step: s.id)
        }
        newStep = ""
    }
}

/// One node in the chain: status circle, connecting line, text, and any flow breaks.
struct ChainRow<Controls: View>: View {
    let step: PlanStep
    let number: Int
    let isCurrent: Bool
    let isLast: Bool
    let blockers: [Blocker]
    @ViewBuilder var controls: Controls

    private var node: (String, Color) {
        switch step.status {
        case .todo: return (isCurrent ? "circle.inset.filled" : "circle", isCurrent ? .accentColor : .secondary)
        case .doing: return ("play.circle.fill", .accentColor)
        case .done: return ("checkmark.circle.fill", .green)
        case .blocked: return ("exclamationmark.circle.fill", .orange)
        case .skipped: return ("arrow.uturn.forward.circle", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: node.0)
                    .font(.title2)
                    .foregroundStyle(node.1)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                if !isLast {
                    Rectangle()
                        .fill(step.status == .done ? Color.green.opacity(0.5) : Color.secondary.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(step.text)
                        .font(isCurrent ? .body.weight(.semibold) : .body)
                        .strikethrough(step.status == .skipped)
                        .foregroundStyle(step.status == .done || step.status == .skipped ? Color.secondary : Color.primary)
                    if step.source == .mitigation {
                        Text("FIX").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    } else if step.source == .user {
                        Text("YOURS").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                HStack(spacing: 8) {
                    if let m = step.minutes, step.status == .todo { Text("~\(m) min") }
                    if let s = step.startedAt, let f = step.finishedAt, step.status == .done {
                        Text("took \(durationText(f.timeIntervalSince(s)))")
                    }
                    if let note = step.note { Text(note).lineLimit(2) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(blockers) { b in
                    Label("\(b.category ?? "Blocked"): \(b.reason)", systemImage: "bolt.horizontal.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                controls
            }
            .padding(.bottom, isLast ? 0 : 16)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct BlockerRow: View {
    let blocker: Blocker

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: blocker.resolved ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(blocker.resolved ? Color.green : Color.orange)
                Text(blocker.stepText).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(blocker.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(blocker.category.map { "\($0) — " } ?? "")\(blocker.reason)").font(.callout)
            if let d = blocker.diagnosis {
                Label(d, systemImage: "stethoscope").font(.caption).foregroundStyle(.secondary)
            }
            if !blocker.addedStepIDs.isEmpty {
                Text("Added \(blocker.addedStepIDs.count) step\(blocker.addedStepIDs.count == 1 ? "" : "s") to get through")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 3. Flow break: report, discuss, mitigate

struct BlockerSheet: View {
    let app: AppDelegate
    @ObservedObject var plans: PlanStore
    let planID: UUID
    let stepID: UUID
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case asking, thinking
        case proposal(Mitigation)
        case failed(String)
    }

    @State private var phase: Phase = .asking
    @State private var category: String?
    @State private var reason = ""
    @State private var extra = ""
    @State private var picked: Set<UUID> = []
    @State private var skipOriginal = false

    private let categories = ["Missing information", "Waiting on someone", "Technical problem",
                              "Bigger than expected", "Lost focus / energy", "Interrupted"]

    private var step: PlanStep? { plans.plan(planID)?.steps.first { $0.id == stepID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("What broke the flow?").font(.title3.weight(.semibold))
                    Text(step?.text ?? "").foregroundStyle(.secondary)
                }
            }

            switch phase {
            case .asking:
                asking
            case .thinking:
                HStack { ProgressView().controlSize(.small); Text("Looking for a way through…").foregroundStyle(.secondary) }
                    .padding(.vertical, 16)
            case .proposal(let m):
                proposal(m)
            case .failed(let msg):
                Text(msg).foregroundStyle(.red)
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Log it without suggestions") { apply(nil) }
                    Button("Try again") { Task { await discuss() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: 12) {
            let rows = [Array(categories.prefix(3)), Array(categories.suffix(3))]
            ForEach(0..<2, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r], id: \.self) { c in
                        Button(c) { category = (category == c ? nil : c) }
                            .buttonStyle(.bordered)
                            .tint(category == c ? Color.orange : nil)
                            .controlSize(.small)
                    }
                }
            }
            TextField("What happened? What did you try?", text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Just log it") { apply(nil) }
                    .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty && category == nil)
                Button { Task { await discuss() } } label: { Label("Discuss with coach", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty && category == nil)
            }
        }
    }

    private func proposal(_ m: Mitigation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(m.diagnosis, systemImage: "stethoscope").fixedSize(horizontal: false, vertical: true)
            if let a = m.advice, !a.isEmpty {
                Label(a, systemImage: "lightbulb").foregroundStyle(.secondary)
            }
            Text("Add these before retrying the step:").font(.headline)
            ForEach(m.steps) { s in
                Button {
                    if picked.contains(s.id) { picked.remove(s.id) } else { picked.insert(s.id) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: picked.contains(s.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(picked.contains(s.id) ? Color.accentColor : Color.secondary)
                        Text(s.text)
                        Spacer()
                        if let min = s.minutes { Text("\(min)m").font(.caption).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Toggle("Skip the blocked step afterwards", isOn: $skipOriginal)
            HStack {
                TextField("Not quite? Add context and ask again…", text: $extra)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await discuss() } }
                Button("Ask again") { Task { await discuss() } }
                    .disabled(extra.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Just log it") { apply(nil) }
                Button("Add \(picked.count) step\(picked.count == 1 ? "" : "s")") { apply(m) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
        }
    }

    private func discuss() async {
        guard let plan = plans.plan(planID), let i = plan.steps.firstIndex(where: { $0.id == stepID }) else { return }
        phase = .thinking
        do {
            let m = try await app.coach.mitigation(plan: plan, stepIndex: i, category: category,
                                                   reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   extra: extra.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   plans: plans)
            picked = Set(m.steps.map(\.id))
            extra = ""
            phase = .proposal(m)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Records the flow break; inserts the chosen fix steps before the blocked step.
    private func apply(_ m: Mitigation?) {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = m?.steps.filter { picked.contains($0.id) } ?? []
        plans.update(planID) { p in
            guard let i = p.steps.firstIndex(where: { $0.id == stepID }) else { return }
            let original = p.steps[i]
            let newSteps = chosen.map { PlanStep(text: $0.text, minutes: $0.minutes, source: .mitigation) }
            var blocker = Blocker(stepID: original.id, stepText: original.text, category: category,
                                  reason: text.isEmpty ? (category ?? "Blocked") : text,
                                  diagnosis: m?.diagnosis)
            p.log(.blocked, "Flow broke on \"\(original.text)\": \(blocker.reason)", step: original.id)
            if newSteps.isEmpty {
                p.steps[i].status = .blocked
            } else {
                p.steps[i].status = skipOriginal ? .skipped : .todo
                p.steps[i].startedAt = skipOriginal ? p.steps[i].startedAt : nil
                p.steps.insert(contentsOf: newSteps, at: i)
                blocker.addedStepIDs = newSteps.map(\.id)
                blocker.resolved = true
                p.log(.mitigated, "Added \(newSteps.count) step(s) to get through: " + newSteps.map(\.text).joined(separator: "; "),
                      step: original.id)
            }
            p.blockers.append(blocker)
        }
        dismiss()
    }
}

// MARK: - 4. Finish: why it worked / why it stopped

struct FinishSheet: View {
    let app: AppDelegate
    @ObservedObject var plans: PlanStore
    let planID: UUID
    let completed: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    private var chips: [String] {
        completed
            ? ["Clear first step", "Small steps", "Had what I needed", "Protected focus time", "Help from someone"]
            : ["Priorities changed", "Blocked by others", "Underestimated effort", "Lost motivation", "No longer needed", "Missing skills / tools"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(completed ? "Plan complete" : "Stop this plan",
                  systemImage: completed ? "flag.checkered" : "stop.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(completed ? Color.green : Color.secondary)
            Text(completed ? "What made this work?" : "Why couldn't it be completed?")
                .font(.headline)
            HStack(spacing: 6) {
                ForEach(chips.prefix(3), id: \.self) { chip($0) }
            }
            HStack(spacing: 6) {
                ForEach(chips.dropFirst(3), id: \.self) { chip($0) }
            }
            TextField("A sentence or two — this is what future plans learn from", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(completed ? "Complete plan" : "Stop plan") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(completed ? .green : .gray)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func chip(_ text: String) -> some View {
        Button(text) { note = note.isEmpty ? text : note + "; " + text }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func save() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        plans.update(planID) { p in
            p.status = completed ? .completed : .abandoned
            p.finishedAt = Date()
            p.outcomeNote = text.isEmpty ? nil : text
            p.log(completed ? .completed : .stopped,
                  (completed ? "Completed" : "Stopped") + (text.isEmpty ? "" : ": \(text)"))
        }
        dismiss()
        let coach = app.coach
        let store = plans
        let id = planID
        Task {
            guard let plan = store.plan(id), let lesson = await coach.planLesson(plan) else { return }
            store.update(id) { $0.lesson = lesson }
        }
    }
}

// MARK: - 5. Summary of a finished plan

struct PlanSummaryView: View {
    let app: AppDelegate
    @ObservedObject var plans: PlanStore
    let planID: UUID

    var body: some View {
        if let plan = plans.plan(planID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(plan.status == .completed ? "COMPLETED" : "STOPPED",
                              systemImage: plan.status == .completed ? "checkmark.seal.fill" : "stop.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(plan.status == .completed ? Color.green : Color.secondary)
                        Text(plan.goal).font(.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 12) {
                        StatTile(value: "\(plan.doneCount)/\(plan.steps.count)", label: "Steps done",
                                 symbol: "checkmark.circle", tint: .green)
                        StatTile(value: "\(plan.blockers.count)", label: "Flow breaks",
                                 symbol: "bolt.horizontal.circle", tint: .orange)
                        StatTile(value: duration(plan), label: "Duration", symbol: "clock", tint: .accentColor)
                    }

                    Card(title: plan.status == .completed ? "Why it worked" : "Why it stopped",
                         symbol: plan.status == .completed ? "hand.thumbsup" : "questionmark.bubble") {
                        Text(plan.outcomeNote ?? "No note added.")
                            .foregroundStyle(plan.outcomeNote == nil ? Color.secondary : Color.primary)
                    }

                    Card(title: "Lesson for next time", symbol: "lightbulb") {
                        if let l = plan.lesson {
                            Text(l)
                        } else {
                            Text(app.coach.hasKey ? "Writing a lesson…" : "Add a Groq API key to get a lesson.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Card(title: "Chain", symbol: "point.3.connected.trianglepath.dotted") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { i, step in
                                ChainRow(step: step, number: i + 1, isCurrent: false,
                                         isLast: i == plan.steps.count - 1,
                                         blockers: plan.blockers.filter { $0.stepID == step.id }) { EmptyView() }
                            }
                        }
                    }

                    if !plan.blockers.isEmpty {
                        Card(title: "Flow breaks", symbol: "bolt.horizontal.circle") {
                            ForEach(plan.blockers) { BlockerRow(blocker: $0) }
                        }
                    }

                    Card(title: "Log", symbol: "list.bullet.rectangle") {
                        ForEach(plan.events) { e in
                            HStack(alignment: .top, spacing: 10) {
                                Text(e.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                    .font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                Text(e.text).font(.callout)
                            }
                        }
                    }

                    HStack {
                        Button("Delete", role: .destructive) { plans.delete(planID) }
                        Spacer()
                        Button("Use as template") { app.startPlan(goal: plan.goal, template: plan) }
                        Button("Reopen") {
                            plans.update(planID) { p in
                                p.status = .active
                                p.finishedAt = nil
                                p.log(.reopened, "Reopened")
                            }
                        }
                    }
                }
                .padding(28)
            }
        }
    }

    private func duration(_ plan: Plan) -> String {
        guard let s = plan.startedAt, let f = plan.finishedAt else { return "–" }
        let days = Calendar.current.dateComponents([.day], from: s, to: f).day ?? 0
        return days >= 1 ? "\(days) day\(days == 1 ? "" : "s")" : durationText(f.timeIntervalSince(s))
    }
}
