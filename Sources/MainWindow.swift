import AppKit
import SwiftUI

enum MainSection: String, Hashable, CaseIterable, Identifiable {
    case today, goals, insights, stuck, reports, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .goals: return "Goals"
        case .insights: return "Insights"
        case .stuck: return "Stuck"
        case .reports: return "Reports"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .goals: return "target"
        case .insights: return "chart.line.uptrend.xyaxis"
        case .stuck: return "lifepreserver"
        case .reports: return "doc.richtext"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class Navigator: ObservableObject {
    @Published var section: MainSection? = .today
}

struct MainWindowView: View {
    let app: AppDelegate
    @ObservedObject var nav: Navigator

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.section) {
                Section {
                    ForEach([MainSection.today, .goals, .insights, .stuck]) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
                Section("Records") {
                    ForEach([MainSection.reports, .history, .settings]) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 620)
    }

    @ViewBuilder private var detail: some View {
        switch nav.section ?? .today {
        case .today:
            TodayView(app: app, goals: app.goals, store: app.store, tracker: app.tracker)
        case .goals:
            GoalsView(goals: app.goals, coach: app.coach)
        case .insights:
            InsightsView(coach: app.coach, store: app.store)
        case .stuck:
            StuckView(coach: app.coach, stuckStore: app.stuckStore)
        case .reports:
            ReportsView(reports: app.reports, archive: app.archive)
        case .history:
            HistoryView(store: app.store, settings: app.settings)
        case .settings:
            EmailSettingsView(settings: app.settings, reports: app.reports, tracker: app.tracker)
        }
    }
}

// MARK: - Shared building blocks

struct Card<Content: View>: View {
    let title: String
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                Text(title).font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.largeTitle.weight(.bold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

/// Renders **bold** and keeps line breaks.
func richText(_ s: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return Text((try? AttributedString(markdown: s, options: options)) ?? AttributedString(s))
}

// MARK: - Today

struct TodayView: View {
    let app: AppDelegate
    @ObservedObject var goals: GoalsStore
    @ObservedObject var store: EntryStore
    @ObservedObject var tracker: UsageTracker

    private var entries: [Entry] {
        store.entries(on: Date())
            .filter { $0.status != .missed && $0.status != .skipped }
            .sorted { $0.periodStart < $1.periodStart }
    }

    private var onPlanText: String {
        let checked = entries.filter { $0.goalAligned != nil }
        guard !checked.isEmpty else { return "–" }
        let on = checked.filter { $0.goalAligned == true }.count
        return "\(Int((Double(on) / Double(checked.count) * 100).rounded()))%"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    PageHeader(title: "Today",
                               subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    Spacer()
                    Button { app.showMain(.stuck) } label: { Label("I'm Stuck", systemImage: "lifepreserver") }
                        .controlSize(.large)
                    Button { app.logNow() } label: { Label("Log now", systemImage: "square.and.pencil") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }

                let g = goals.activeToday
                HStack(spacing: 12) {
                    StatTile(value: g.isEmpty ? "–" : "\(g.filter(\.done).count)/\(g.count)",
                             label: "Goals done", symbol: "target", tint: .accentColor)
                    StatTile(value: onPlanText, label: "Check-ins on plan", symbol: "scope", tint: .green)
                    StatTile(value: durationText(tracker.today.activeSeconds), label: "Active screen time",
                             symbol: "desktopcomputer", tint: .orange)
                }

                Card(title: "Today's goals", symbol: "target") {
                    if g.isEmpty {
                        HStack {
                            Text("No goals set yet. What would make today a good day?").foregroundStyle(.secondary)
                            Spacer()
                            Button("Set goals") { app.showMain(.goals) }
                        }
                    } else {
                        ForEach(g) { goal in
                            Button {
                                goals.toggleToday(goal.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: goal.done ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(goal.done ? Color.green : Color.secondary)
                                    Text(goal.text)
                                        .foregroundStyle(goal.done ? Color.secondary : Color.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Card(title: "Check-ins", symbol: "clock") {
                    if entries.isEmpty {
                        Text("Nothing logged yet today.").foregroundStyle(.secondary)
                    } else {
                        ForEach(entries) { e in CheckinRow(entry: e) }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct CheckinRow: View {
    let entry: Entry

    private var symbol: (String, Color) {
        switch entry.goalAligned {
        case .some(true): return ("checkmark.seal.fill", .green)
        case .some(false): return ("arrow.triangle.branch", .orange)
        case .none: return ("circle.dashed", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol.0).foregroundStyle(symbol.1).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.timeRangeText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if let g = entry.alignedGoal, entry.goalAligned == true {
                        Text(g).font(.caption).foregroundStyle(.green)
                    }
                }
                Text(CoachService.text(of: entry)).lineLimit(3)
                if entry.goalAligned == false {
                    if let ex = entry.explanation {
                        Label(ex, systemImage: entry.explanationAccepted == true ? "checkmark.bubble" : "exclamationmark.bubble")
                            .font(.callout)
                            .foregroundStyle(entry.explanationAccepted == true ? Color.secondary : Color.orange)
                    } else if let note = entry.deviationNote {
                        Text(note).font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Goals

struct GoalsView: View {
    @ObservedObject var goals: GoalsStore
    let coach: CoachService

    @State private var today: [Goal] = []
    @State private var month: [Goal] = []
    @State private var breakdownGoal: Goal?

    var body: some View {
        Form {
            if goals.activeToday.isEmpty {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Plan your day").font(.headline)
                            Text("Add 1–5 goals. Each check-in is compared with them, and you'll be asked when you drift.")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sunrise.fill").foregroundStyle(.orange).font(.title2)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                ForEach($today) { $goal in
                    GoalRow(goal: $goal,
                            onBreakdown: { breakdownGoal = goal },
                            onDelete: { today.removeAll { $0.id == goal.id } })
                }
                Button { today.append(Goal(text: "")) } label: { Label("Add goal", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(today.count >= 5)
            } header: {
                Text("Today · \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))")
            } footer: {
                Text("Tip: use the ✦ button to break a goal into small steps.").foregroundStyle(.secondary)
            }

            Section {
                ForEach($month) { $goal in
                    GoalRow(goal: $goal,
                            onBreakdown: { breakdownGoal = goal },
                            onDelete: { month.removeAll { $0.id == goal.id } })
                }
                Button { month.append(Goal(text: "")) } label: { Label("Add monthly goal", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(month.count >= 7)
            } header: {
                Text("This month · \(Date().formatted(.dateTime.month(.wide).year()))")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            today = goals.today()
            month = goals.thisMonth()
            if today.isEmpty { today = [Goal(text: "")] }
        }
        .onChange(of: today) { goals.setToday($0) }
        .onChange(of: month) { goals.setMonth($0) }
        .sheet(item: $breakdownGoal) { goal in
            BreakdownSheet(problem: goal.text, coach: coach)
        }
    }
}

struct GoalRow: View {
    @Binding var goal: Goal
    var onBreakdown: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { goal.done.toggle() } label: {
                Image(systemName: goal.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(goal.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            TextField("Goal", text: $goal.text, prompt: Text("Describe the goal"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .foregroundStyle(goal.done ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onBreakdown) { Image(systemName: "sparkles") }
                .buttonStyle(.borderless)
                .help("Break down into steps")
                .disabled(goal.text.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
        }
    }
}

// MARK: - Breakdown

struct BreakdownSheet: View {
    let problem: String
    let coach: CoachService
    @Environment(\.dismiss) private var dismiss
    @State private var steps: [BreakdownStep] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Break it down", systemImage: "sparkles").font(.headline).foregroundStyle(.secondary)
            Text(problem).font(.title3.weight(.semibold))
            if loading {
                HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                    .padding(.vertical, 20)
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                StepsList(steps: steps)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task {
            do { steps = try await coach.breakdown(problem) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

struct StepsList: View {
    let steps: [BreakdownStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(i == 0 ? Color.accentColor : Color.secondary))
                    Text(step.text)
                    Spacer()
                    if let m = step.minutes {
                        Text("\(m) min").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            let total = steps.compactMap(\.minutes).reduce(0, +)
            if total > 0 {
                Divider()
                Text("About \(durationText(Double(total) * 60)) in total · start with step 1")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Insights

struct InsightsView: View {
    let coach: CoachService
    @ObservedObject var store: EntryStore

    @State private var report: PatternReport?
    @State private var loading = false
    @State private var error: String?
    @State private var problem = ""
    @State private var breakdown: BreakdownRequest?

    struct BreakdownRequest: Identifiable {
        let id = UUID()
        let text: String
    }

    private var recent: [Entry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        return store.entries.filter { $0.periodEnd > cutoff }
    }

    private var answered: [Entry] { recent.filter { $0.status != .missed && $0.status != .skipped } }

    private var responseRate: String {
        guard !recent.isEmpty else { return "–" }
        return "\(Int((Double(answered.count) / Double(recent.count) * 100).rounded()))%"
    }

    private var onPlan: String {
        let checked = answered.filter { $0.goalAligned != nil }
        guard !checked.isEmpty else { return "–" }
        return "\(Int((Double(checked.filter { $0.goalAligned == true }.count) / Double(checked.count) * 100).rounded()))%"
    }

    private var successes: Int {
        answered.filter { RecapBuilder.keywordSuccess(CoachService.text(of: $0)) == true }.count
    }

    private var bestHour: String {
        var counts: [Int: Int] = [:]
        for e in answered where e.goalAligned == true || RecapBuilder.keywordSuccess(CoachService.text(of: e)) == true {
            counts[Calendar.current.component(.hour, from: e.periodStart), default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return "–" }
        let start = Calendar.current.date(bySettingHour: best, minute: 0, second: 0, of: Date()) ?? Date()
        return start.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Insights", subtitle: "Your last 14 days")

                HStack(spacing: 12) {
                    StatTile(value: responseRate, label: "Check-ins answered", symbol: "checklist", tint: .accentColor)
                    StatTile(value: onPlan, label: "On plan", symbol: "scope", tint: .green)
                    StatTile(value: "\(successes)", label: "Successes", symbol: "star.fill", tint: .yellow)
                    StatTile(value: bestHour, label: "Best hour", symbol: "bolt.fill", tint: .orange)
                }

                Card(title: "Patterns", symbol: "waveform.path.ecg") {
                    if loading {
                        HStack { ProgressView().controlSize(.small); Text("Reading your last 14 days…").foregroundStyle(.secondary) }
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    } else if let report {
                        if let best = report.bestTime {
                            Label(best, systemImage: "bolt.fill").foregroundStyle(.orange)
                        }
                        ForEach(report.patterns) { InsightRow(item: $0, symbol: "eye") }
                    } else {
                        Text("Find out when you do your best work, what pulls you off-plan, and where time goes.")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(report == nil ? "Analyze my patterns" : "Analyze again") { Task { await analyze() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(loading)
                    }
                }

                if let report, !report.suggestions.isEmpty {
                    Card(title: "Try this", symbol: "lightbulb") {
                        ForEach(report.suggestions) { InsightRow(item: $0, symbol: "arrow.right.circle") }
                    }
                }

                Card(title: "Break down a problem", symbol: "sparkles") {
                    Text("Turn something big or vague into small steps, using your history.")
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("e.g. Finalize MV2 picker BOM and order samples", text: $problem)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(startBreakdown)
                        Button("Break down", action: startBreakdown)
                            .disabled(problem.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(28)
        }
        .sheet(item: $breakdown) { req in BreakdownSheet(problem: req.text, coach: coach) }
    }

    private func startBreakdown() {
        let t = problem.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        breakdown = BreakdownRequest(text: t)
    }

    private func analyze() async {
        loading = true
        error = nil
        do { report = try await coach.analyzePatterns() } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct InsightRow: View {
    let item: InsightItem
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.semibold))
                Text(item.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
