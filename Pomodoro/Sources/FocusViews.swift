// SwiftUI windows for the focus & goal tracker (see Focus.swift). macOS 13+.

import Cocoa
import SwiftUI

// MARK: - Shared bits

@available(macOS 13.0, *)
struct FocusCard<Content: View>: View {
    let title: String
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

@available(macOS 13.0, *)
struct FocusStat: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
    }
}

@available(macOS 13.0, *)
struct FocusBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint).frame(width: max(0, g.size.width * min(1, fraction)))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Start of day: today's goals + this month's goals

@available(macOS 13.0, *)
struct FocusGoalsView: View {
    @ObservedObject var store: FocusStore
    let onSave: ([String], [String]) -> Void
    let onLater: () -> Void
    let onDayOff: () -> Void

    @State private var today: [String] = ["", "", ""]
    @State private var month: [String] = ["", "", ""]
    @State private var loaded = false

    private func filled(_ a: [String]) -> [String] {
        a.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var canSave: Bool { !filled(today).isEmpty && !filled(month).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sunrise.fill").font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's the goal today?").font(.title2.weight(.bold))
                    Text("Hourly focus check-ins split each hour across these goals.").foregroundStyle(.secondary)
                }
            }

            section("THIS MONTH · \(Date().formatted(.dateTime.month(.wide)).uppercased())") {
                ForEach(0..<3, id: \.self) { i in
                    field("calendar", $month[i], i == 0 ? "Most important outcome this month" : "Another (optional)")
                }
                let last = store.previousMonthGoals.filter { !month.contains($0) }
                if filled(month).isEmpty && !last.isEmpty {
                    chips("Last month:", last) { put($0, in: &month) }
                }
            }

            section("TODAY · \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())") {
                ForEach(0..<3, id: \.self) { i in
                    field("target", $today[i], i == 0 ? "The one thing that matters most today" : "Another (optional)")
                }
                let carry = store.yesterdayGoals.filter { !today.contains($0) }
                if !carry.isEmpty {
                    chips("Yesterday:", carry) { put($0, in: &today) }
                }
            }

            HStack(spacing: 12) {
                Button("No tracking today", action: onDayOff).buttonStyle(.borderless)
                Button("Remind me in 10 min", action: onLater).buttonStyle(.borderless)
                Spacer()
                Button("Start my day") { onSave(today, month) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            for (i, g) in store.todayGoals.prefix(3).enumerated() { today[i] = g }
            for (i, g) in store.thisMonthGoals.prefix(3).enumerated() { month[i] = g }
        }
    }

    private func put(_ goal: String, in list: inout [String]) {
        if let i = list.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { list[i] = goal }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func field(_ icon: String, _ text: Binding<String>, _ prompt: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func chips(_ label: String, _ items: [String], _ action: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ForEach(items.prefix(3), id: \.self) { g in
                Button(g) { action(g) }.buttonStyle(.bordered).controlSize(.small).lineLimit(1)
            }
        }
    }
}

// MARK: - Hourly check-in

@available(macOS 13.0, *)
@MainActor
final class FocusHourModel: ObservableObject {
    struct Row: Identifiable, Hashable {
        let label: String
        let kind: FocusShare.Kind
        var id: String { FocusShare.key(kind, label) }
    }

    let start: Date
    let end: Date
    let rows: [Row]
    let split: SiteSplit

    @Published var words = ""
    @Published var percents: [String: Int] = [:]

    var onDone: ((FocusHour) -> Void)?
    var onOpenDashboard: (() -> Void)?

    init(start: Date, end: Date, rows: [Row], previous: FocusHour?, split: SiteSplit) {
        self.start = start
        self.end = end
        self.rows = rows
        self.split = split
        // Start from the last hour's split when it still adds up to 100% with today's rows.
        var p: [String: Int] = [:]
        for s in previous?.shares ?? [] where rows.contains(where: { $0.id == s.key }) { p[s.key] = s.percent }
        percents = p.values.reduce(0, +) == 100 ? p : [:]
    }

    var rangeText: String {
        let s = start.formatted(date: .omitted, time: .shortened)
        let e = end.formatted(date: .omitted, time: .shortened)
        let mins = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
        return "\(s) – \(e)  (\(mins) min)"
    }

    var wordCount: Int { words.split(whereSeparator: { $0.isWhitespace }).count }
    var total: Int { rows.reduce(0) { $0 + (percents[$1.id] ?? 0) } }
    var canSave: Bool { (1...5).contains(wordCount) && total == 100 }

    func percent(_ row: Row) -> Int { percents[row.id] ?? 0 }
    func set(_ row: Row, _ value: Int) { percents[row.id] = min(100, max(0, value)) }

    /// Give this row whatever is left to reach 100%.
    func fillRest(_ row: Row) { set(row, 100 - (total - percent(row))) }

    func save() {
        guard canSave else { return }
        let shares = rows.compactMap { r -> FocusShare? in
            let p = percent(r)
            return p > 0 ? FocusShare(label: r.label, kind: r.kind, percent: p) : nil
        }
        let text = words.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        onDone?(FocusHour(start: start, end: end, words: text, shares: shares, skipped: false, savedAt: Date()))
    }

    func skip() {
        onDone?(FocusHour(start: start, end: end, words: "", shares: [], skipped: true, savedAt: Date()))
    }
}

@available(macOS 13.0, *)
struct FocusHourView: View {
    @ObservedObject var model: FocusHourModel

    private var goalRows: [FocusHourModel.Row] { model.rows.filter { $0.kind == .monthGoal || $0.kind == .dayGoal } }
    private var dutyRows: [FocusHourModel.Row] { model.rows.filter { $0.kind == .responsibility } }
    private var otherRows: [FocusHourModel.Row] { model.rows.filter { $0.kind == .waste || $0.kind == .other } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "scope").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Where was my focus?").font(.title2.weight(.bold))
                    Text(model.rangeText).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("This hour in five words", text: $model.words)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                Text(model.wordCount > 5 ? "\(model.wordCount) words, keep it to 5" : "\(model.wordCount)/5 words")
                    .font(.caption)
                    .foregroundStyle(model.wordCount > 5 ? Color.red : Color.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    group("GOALS", goalRows)
                    if dutyRows.isEmpty {
                        Button("Add daily responsibilities (like a LinkedIn post) in the Focus Dashboard…") {
                            model.onOpenDashboard?()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    } else {
                        group("DAILY RESPONSIBILITIES", dutyRows)
                    }
                    group("EVERYTHING ELSE", otherRows)
                }
            }
            .frame(minHeight: 160, maxHeight: 340)

            HStack {
                Text("Total \(model.total)%")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(model.total == 100 ? Color.green : Color.orange)
                if model.total != 100 {
                    Text(model.total < 100 ? "\(100 - model.total)% left to place" : "\(model.total - 100)% too much")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if model.split.total > 60 { trackerLine }

            HStack {
                Button("Skip this hour") { model.skip() }
                Spacer()
                Button("Save") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var trackerLine: some View {
        let s = model.split
        var parts: [String] = []
        if s.work > 0 { parts.append("work sites \(focusDuration(s.work))") }
        if s.notWork > 0 { parts.append("not-work sites \(focusDuration(s.notWork))") }
        if s.unsorted > 0 { parts.append("unsorted sites \(focusDuration(s.unsorted))") }
        if s.otherApps > 0 { parts.append("other apps \(focusDuration(s.otherApps))") }
        return Label("Tracker saw: " + parts.joined(separator: " · "), systemImage: "globe")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [FocusHourModel.Row]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: Self.icon(row.kind)).foregroundStyle(.secondary).frame(width: 16)
                        Text(row.label).lineLimit(1).truncationMode(.tail)
                            .frame(width: 180, alignment: .leading)
                            .help(row.label)
                        Slider(value: Binding(get: { Double(model.percent(row)) },
                                              set: { model.set(row, Int($0.rounded())) }),
                               in: 0...100, step: 5)
                        Text("\(model.percent(row))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        Button("Rest") { model.fillRest(row) }
                            .controlSize(.small)
                            .help("Put the remaining % here")
                    }
                }
            }
        }
    }

    static func icon(_ kind: FocusShare.Kind) -> String {
        switch kind {
        case .monthGoal: return "calendar"
        case .dayGoal: return "target"
        case .responsibility: return "checklist"
        case .waste: return "hourglass"
        case .other: return "cup.and.saucer"
        }
    }
}

// MARK: - First visit to a website

@available(macOS 13.0, *)
struct SiteQuestionView: View {
    let domain: String
    let goals: [String]
    let onAnswer: (FocusCenter.SiteAnswer) -> Void

    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "globe").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("First visit: \(domain)").font(.headline)
                    Text("Why are you visiting it? After this it's only counted.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            TextField("e.g. research for today's LinkedIn post", text: $reason)
                .textFieldStyle(.roundedBorder)
            if !goals.isEmpty {
                Text("Goals: " + goals.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button("Ask me later") { onAnswer(.later) }
                Spacer()
                Button("Not work") { onAnswer(.notWork(reason)) }
                Button("Work") { onAnswer(.work(reason)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

// MARK: - Dashboard

@available(macOS 13.0, *)
struct FocusDashboardView: View {
    let center: FocusCenter
    @ObservedObject var store: FocusStore
    @ObservedObject var tracker: FocusTracker

    @State private var newDuty = ""

    private var todayHours: [FocusHour] { store.hours(on: Date()) }

    var body: some View {
        let totals = FocusTotals(todayHours)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus").font(.largeTitle.weight(.bold))
                        Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit goals") { center.showGoals() }
                    Button { center.checkInNow() } label: { Label("Where was my focus?", systemImage: "scope") }
                        .buttonStyle(.borderedProminent)
                }
                goalsVsActual(totals)
                crossCheck(totals)
                hourByHour
                responsibilities(totals)
                websites
                settingsCard
            }
            .padding(22)
        }
        .frame(minWidth: 640, minHeight: 500)
    }

    // MARK: Goals vs actual

    private func goalsVsActual(_ t: FocusTotals) -> some View {
        let month = store.thisMonthGoals
        let today = store.todayGoals.filter { !month.contains($0) }
        let known = Set(month.map { FocusShare.key(.monthGoal, $0) } + today.map { FocusShare.key(.dayGoal, $0) }
                        + store.responsibilities.map { FocusShare.key(.responsibility, $0.text) }
                        + [FocusShare.key(.waste, FocusCenter.wasteLabel), FocusShare.key(.other, FocusCenter.otherLabel)])
        let extra = t.labels.filter { !known.contains($0.key) }.map(\.value).sorted { $0.label < $1.label }
        return FocusCard(title: "Goals vs actual today", symbol: "target") {
            if t.answered == 0 {
                Text("No hours logged yet today. At the top of each hour you'll be asked where your focus was.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(t.answered) hour\(t.answered == 1 ? "" : "s") logged (\(focusDuration(t.loggedMinutes * 60)))"
                     + (t.skipped > 0 ? " · \(t.skipped) skipped" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !month.isEmpty { subhead("THIS MONTH") }
            ForEach(month, id: \.self) { shareRow($0, .monthGoal, t, tint: .blue) }
            if !today.isEmpty { subhead("TODAY") }
            ForEach(today, id: \.self) { shareRow($0, .dayGoal, t, tint: .indigo) }
            if !store.responsibilities.isEmpty { subhead("DAILY RESPONSIBILITIES") }
            ForEach(store.responsibilities) { shareRow($0.text, .responsibility, t, tint: .teal) }
            if !extra.isEmpty { subhead("EARLIER GOALS") }
            ForEach(extra, id: \.self) { shareRow($0.label, $0.kind, t, tint: .gray) }
            subhead("EVERYTHING ELSE")
            shareRow(FocusCenter.wasteLabel, .waste, t, tint: .red)
            shareRow(FocusCenter.otherLabel, .other, t, tint: .gray)
        }
    }

    private func subhead(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func shareRow(_ label: String, _ kind: FocusShare.Kind, _ t: FocusTotals, tint: Color) -> some View {
        let f = t.fraction(kind, label)
        let mins = t.minutes(kind, label)
        let neglected = t.answered > 0 && mins == 0 && (kind == .monthGoal || kind == .dayGoal)
        return HStack(spacing: 10) {
            Text(label).lineLimit(1).frame(width: 220, alignment: .leading).help(label)
            FocusBar(fraction: f, tint: tint)
            Text("\(Int((f * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            Text(focusDuration(mins * 60)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .foregroundStyle(neglected ? Color.orange : Color.primary)
    }

    // MARK: Said vs seen

    private func crossCheck(_ t: FocusTotals) -> some View {
        let s = store.daySplit(tracker.today)
        let saidWaste = t.fraction(.waste, FocusCenter.wasteLabel)
        let seenWaste = s.notWork / max(1, s.browserTotal)
        return FocusCard(title: "What you said vs what the tracker saw", symbol: "eye") {
            if s.browserTotal < 60 {
                Text("No browser time tracked today yet.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    FocusStat(value: focusDuration(s.work), label: "Work sites", symbol: "briefcase", tint: .green)
                    FocusStat(value: focusDuration(s.notWork), label: "Not-work sites", symbol: "gamecontroller", tint: .red)
                    FocusStat(value: focusDuration(s.unsorted), label: "Not sorted yet", symbol: "questionmark.circle", tint: .gray)
                }
                if t.answered > 0 {
                    Text("You reported \(Int((saidWaste * 100).rounded()))% of logged hours as time waste. "
                         + "\(Int((seenWaste * 100).rounded()))% of today's browser time was on sites you marked not work.")
                        .font(.callout)
                }
            }
        }
    }

    // MARK: Hour by hour

    private var hourByHour: some View {
        FocusCard(title: "Hour by hour", symbol: "clock") {
            if todayHours.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(todayHours) { h in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(h.rangeText).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    if h.skipped {
                        Text("Skipped").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.words).fontWeight(.medium)
                            Text(h.shares.sorted { $0.percent > $1.percent }
                                .map { "\($0.label) \($0.percent)%" }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: Responsibilities

    private func responsibilities(_ t: FocusTotals) -> some View {
        FocusCard(title: "Daily responsibilities", symbol: "checklist") {
            Text("Each one gets its own row in the hourly split.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.responsibilities) { r in
                HStack {
                    Image(systemName: "checklist").foregroundStyle(.secondary)
                    Text(r.text)
                    Spacer()
                    Text(focusDuration(t.minutes(.responsibility, r.text) * 60) + " today")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button { store.removeResponsibility(r.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                }
            }
            HStack {
                TextField("Add a responsibility, e.g. LinkedIn post", text: $newDuty)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDuty)
                Button("Add", action: addDuty)
                    .disabled(newDuty.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addDuty() {
        store.addResponsibility(newDuty)
        newDuty = ""
    }

    // MARK: Websites

    private var websites: some View {
        let seconds = tracker.today.sites.filter { isRealSite($0.key) }
        let visits = store.visits(on: Date())
        let domains = Set(seconds.keys).union(visits.keys).sorted { (seconds[$0] ?? 0) > (seconds[$1] ?? 0) }
        return FocusCard(title: "Websites today", symbol: "globe") {
            if !tracker.deniedBrowsers.isEmpty {
                Label("Not allowed to read tabs in \(tracker.deniedBrowsers.joined(separator: ", ")). "
                      + "Allow it in System Settings → Privacy & Security → Automation → Pomodoro.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if domains.isEmpty { Text("No websites tracked today yet.").foregroundStyle(.secondary) }
            ForEach(Array(domains.prefix(40)), id: \.self) { d in
                HStack(spacing: 10) {
                    badge(d)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d).lineLimit(1)
                        if let r = store.sites[d]?.reason, !r.isEmpty {
                            Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    let n = visits[d] ?? 0
                    Text("\(n) visit\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(focusDuration(seconds[d] ?? 0)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Menu {
                        Button("Mark as work") { store.classify(d, reason: store.sites[d]?.reason ?? "", isWork: true) }
                        Button("Mark as not work") { store.classify(d, reason: store.sites[d]?.reason ?? "", isWork: false) }
                        if store.sites[d] != nil {
                            Button("Forget (ask again next visit)") { store.forget(d) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
            }
        }
    }

    private func badge(_ d: String) -> some View {
        let (text, color): (String, Color) = {
            switch store.sites[d]?.isWork {
            case .some(true): return ("Work", .green)
            case .some(false): return ("Not work", .red)
            case .none: return ("Unsorted", .gray)
            }
        }()
        return Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.2)))
            .frame(width: 64)
    }

    // MARK: Settings

    private var settingsCard: some View {
        FocusCard(title: "Focus settings", symbol: "gearshape") {
            Toggle("Ask \"Where was my focus?\" at the top of every hour", isOn: $store.hourlyEnabled)
            Toggle("Ask why I'm visiting a website the first time", isOn: $store.askNewSites)
            Toggle("Notify when I visit a not-work site 2 or more times in a day", isOn: $store.nagNonWork)
            HStack {
                Text("Stored only on this Mac: ~/Library/Application Support/Pomodoro/")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - CI preview: `Pomodoro --render-focus-preview dist/focus` writes dist/focus-*.png

/// Draws the focus windows with sample data. Note: the dashboard sample writes to
/// ~/Library/Application Support/Pomodoro/focus.json, so this is meant for CI only.
func renderFocusPreview(to base: String) {
    guard #available(macOS 13.0, *) else { print("Focus tracker needs macOS 13 or later"); return }
    MainActor.assumeIsolated { FocusPreview.render(base) }
}

@available(macOS 13.0, *)
@MainActor
enum FocusPreview {
    static func render(_ base: String) {
        let cal = Calendar.current
        let hourStart = cal.dateInterval(of: .hour, for: Date())!.start.addingTimeInterval(-3600)
        let rows: [FocusHourModel.Row] = [
            .init(label: "Launch the course landing page", kind: .monthGoal),
            .init(label: "Finish pricing section copy", kind: .dayGoal),
            .init(label: "LinkedIn post", kind: .responsibility),
            .init(label: FocusCenter.wasteLabel, kind: .waste),
            .init(label: FocusCenter.otherLabel, kind: .other),
        ]
        let model = FocusHourModel(start: hourStart, end: hourStart.addingTimeInterval(3600), rows: rows,
                                   previous: nil,
                                   split: SiteSplit(work: 2100, notWork: 420, unsorted: 180, otherApps: 900))
        model.words = "Drafted pricing copy, LinkedIn draft"
        model.percents = [rows[0].id: 25, rows[1].id: 50, rows[2].id: 15, rows[3].id: 5, rows[4].id: 5]
        snapshot(FocusHourView(model: model), base + "-hour.png")

        snapshot(SiteQuestionView(domain: "youtube.com", goals: ["Finish pricing section copy"]) { _ in },
                 base + "-site.png")

        let store = FocusStore()
        store.setGoals(today: ["Finish pricing section copy"], month: ["Launch the course landing page"])
        store.addResponsibility("LinkedIn post")
        for (i, words, p) in [(3, "Outlined pricing page sections", [25, 60, 0, 10, 5]),
                              (2, "LinkedIn post drafted and scheduled", [10, 20, 60, 5, 5]),
                              (1, "Pricing copy, too much YouTube", [20, 45, 0, 30, 5])] {
            let s = hourStart.addingTimeInterval(-Double(i - 1) * 3600)
            let shares = zip(rows, p).compactMap { r, v in v > 0 ? FocusShare(label: r.label, kind: r.kind, percent: v) : nil }
            store.saveHour(FocusHour(start: s, end: s.addingTimeInterval(3600), words: words, shares: shares,
                                     skipped: false, savedAt: Date()))
        }
        store.classify("docs.google.com", reason: "Writing pricing copy", isWork: true)
        store.classify("youtube.com", reason: "Music while writing", isWork: false)
        store.recordVisit("youtube.com"); store.recordVisit("youtube.com"); store.recordVisit("youtube.com")
        store.recordVisit("docs.google.com")
        snapshot(FocusGoalsView(store: store, onSave: { _, _ in }, onLater: {}, onDayOff: {}), base + "-goals.png")
        snapshot(FocusDashboardView(center: FocusCenter(), store: store, tracker: FocusTracker())
                    .frame(width: 760, height: 1100), base + "-dashboard.png")
    }

    static func snapshot<V: View>(_ view: V, _ path: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(Int(size.width))x\(Int(size.height))")
    }
}
