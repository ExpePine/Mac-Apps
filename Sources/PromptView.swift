import AppKit
import SwiftUI

/// Compact check-in: ~440 pt wide, sits in the top-right corner.
/// Rarely used parts (all plan steps, the "next" text field, time-by-goal detail) stay folded until asked for.
struct PromptView: View {
    @ObservedObject var session: PromptSession
    @State private var showWeek = false
    @State private var showAllSteps = false
    @State private var showNextField = false
    @State private var showTimeDetail = false
    @State private var showQuickNote = false
    @State private var quickNote = ""
    @State private var noteSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let intent = session.previousIntent { intentCheck(intent) }
            pathSection
            noteSection
            nextSection
            if let msg = session.errorMessage {
                Text(msg).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.todayRows.isEmpty { timeByGoal }
            buttons
        }
        .padding(12)
        .frame(width: 440)
        .controlSize(.small)
    }

    // MARK: Header (one line)

    private var header: some View {
        HStack(spacing: 8) {
            Text("Where were you?").font(.headline)
            Text(session.prompt.rangeText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 4)
            if let f = session.followThrough, f.total > 0 {
                Label("\(Int(f.done / Double(f.total) * 100))%", systemImage: "arrow.uturn.forward.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Follow-through today: did what you said \(Int(f.done))/\(f.total)")
            }
            Text(mmss(session.remaining))
                .font(.system(.caption, design: .rounded).weight(.semibold)).monospacedDigit()
                .foregroundStyle(session.remaining <= 30 ? Color.red : Color.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .help("Time left — auto-saves at 0")
        }
    }

    // MARK: Did I do what I said? (one row + optional reasons)

    private func intentCheck(_ intent: PromptSession.Intent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "quote.opening").font(.caption).foregroundStyle(.secondary)
                Text(intent.text).font(.callout.weight(.medium)).lineLimit(1).help("You said you'd: \(intent.text)")
                Spacer(minLength: 4)
                resultChip("did", "checkmark", .green, "Did it")
                resultChip("partly", "circle.lefthalf.filled", .yellow, "Partly")
                resultChip("didnt", "xmark", .orange, "Didn't")
            }
            if session.intentResult == "didnt" || session.intentResult == "partly" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(["Pulled away", "Took longer", "Interrupted", "Changed plan", "Distracted", "Blocked"], id: \.self) { r in
                            chip(r, color: .orange, selected: session.intentReason == r) {
                                session.intentReason = session.intentReason == r ? nil : r
                            }
                        }
                    }
                }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.07)))
    }

    private func resultChip(_ value: String, _ icon: String, _ tint: Color, _ title: String) -> some View {
        let selected = session.intentResult == value
        return Button { session.setIntentResult(value) } label: {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? tint : Color.secondary)
                .frame(width: 24, height: 20)
                .background(Capsule().fill(selected ? tint.opacity(0.22) : Color.secondary.opacity(0.10)))
                .overlay(Capsule().strokeBorder(selected ? tint : Color.clear, lineWidth: 1.2))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: Path — tap where you are

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.planPaths) { path in
                planBlock(path)
            }
            HStack(spacing: 5) {
                if !session.goalOptions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(session.goalOptions, id: \.self) { g in
                                chip(g, color: areaColor(g), selected: session.selectedGoal == g && session.selectedStep == nil) {
                                    session.pickGoal(g)
                                }
                            }
                        }
                    }
                } else {
                    Spacer()
                }
                Divider().frame(height: 18)
                kindChip("break", "Break", "cup.and.saucer")
                kindChip("meeting", "Meeting", "person.2")
                kindChip("admin", "Admin", "tray")
                kindChip("drift", "Drifted", "arrow.triangle.branch")
            }
        }
    }

    /// Shows the current step and the next one; the rest fold behind "+N".
    private func planBlock(_ path: PromptSession.PlanPath) -> some View {
        let idx = path.steps.firstIndex { $0.id == path.currentStepID } ?? 0
        let near = Array(path.steps.dropFirst(idx).prefix(2))
        var shown = showAllSteps ? path.steps : near
        if let sel = session.selectedStep, !shown.contains(where: { $0.id == sel }),
           let st = path.steps.first(where: { $0.id == sel }) { shown.append(st) }
        let hidden = path.steps.count - shown.count
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(path.goal).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if hidden > 0 || showAllSteps {
                    Button(showAllSteps ? "Less" : "+\(hidden) more") { showAllSteps.toggle() }
                        .buttonStyle(.borderless).font(.caption2)
                }
            }
            ForEach(shown) { step in stepRow(step, path: path) }
        }
    }

    private func stepRow(_ step: PlanStep, path: PromptSession.PlanPath) -> some View {
        let selected = session.selectedStep == step.id
        return HStack(spacing: 6) {
            Button { session.pickStep(step, in: path) } label: {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.caption)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(step.text).font(.callout).lineLimit(1)
                    if step.id == path.currentStepID {
                        Text("NOW").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 2)
                }
                .padding(.vertical, 2).padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected {
                Toggle("Done", isOn: $session.stepDone).toggleStyle(.checkbox).font(.caption)
            }
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
    }

    private func chip(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(selected ? color.opacity(0.25) : Color.secondary.opacity(0.10)))
            .overlay(Capsule().strokeBorder(selected ? color : Color.clear, lineWidth: 1.2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// Icon-only; the name shows on hover.
    private func kindChip(_ kind: String, _ title: String, _ icon: String) -> some View {
        let selected = session.selectedKind == kind
        let tint: Color = kind == "drift" ? .orange : .teal
        return Button { session.pickKind(kind) } label: {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(selected ? tint : Color.secondary)
                .frame(width: 26, height: 22)
                .background(Capsule().fill(selected ? tint.opacity(0.25) : Color.secondary.opacity(0.10)))
                .overlay(Capsule().strokeBorder(selected ? tint : Color.clear, lineWidth: 1.2))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: Note + mic + quick note (one row)

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Note", text: $session.text, prompt: Text(session.hasSelection
                                                                   ? "Optional — a word or two"
                                                                   : "Tap above, or type / speak what you did"),
                          axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Button {
                    Task { await session.toggleRecording() }
                } label: {
                    Image(systemName: session.isRecording ? "stop.circle.fill" : "mic.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.isRecording ? Color.red : Color.accentColor)
                .disabled(session.isTranscribing)
                .keyboardShortcut("r", modifiers: .command)
                .help("Speak instead (⌘R)")
                Button { showQuickNote.toggle() } label: {
                    Image(systemName: noteSaved ? "checkmark.circle.fill" : "note.text.badge.plus").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(noteSaved ? Color.green : Color.yellow)
                .help("Save a note to Notes (doesn't count as a check-in)")
                .popover(isPresented: $showQuickNote, arrowEdge: .bottom) { quickNotePopover }
            }
            if session.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text(mmss(session.recordingSeconds)).monospacedDigit().font(.caption)
                }
            } else if session.isTranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Converting speech to text…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var quickNotePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick note").font(.headline)
            TextField("Note", text: $quickNote, prompt: Text("Idea, finding, something to remember"), axis: .vertical)
                .labelsHidden().textFieldStyle(.roundedBorder).lineLimit(3...8)
            HStack {
                if let g = session.selectedGoal {
                    Text("Linked to \(g)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Save note") {
                    let t = quickNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    session.onQuickNote?(t, session.selectedGoal)
                    quickNote = ""
                    showQuickNote = false
                    noteSaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { noteSaved = false }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(quickNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: Next interval (one row; text field on demand)

    private var nextSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("Next \(session.intervalMinutes)m").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        if session.hasSelection && session.selectedKind != "drift" {
                            nextChip(.same, "Continue", "arrow.forward")
                        }
                        if let f = session.followingStep {
                            nextChip(.nextStep(planID: f.path.id, stepID: f.step.id, text: f.step.text),
                                     f.step.text, "forward.end")
                        }
                        nextChip(.kind("break"), "Break", "cup.and.saucer")
                        Menu {
                            ForEach(session.goalOptions, id: \.self) { g in
                                Button(g) { session.setNext(.goal(g)) }
                            }
                            ForEach(session.planPaths) { path in
                                Section(path.goal) {
                                    ForEach(path.steps) { st in
                                        Button(st.text) { session.setNext(.nextStep(planID: path.id, stepID: st.id, text: st.text)) }
                                    }
                                }
                            }
                        } label: {
                            Text(otherLabel).lineLimit(1)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                Button { showNextField.toggle() } label: {
                    Image(systemName: showNextField || !session.nextText.isEmpty ? "pencil.circle.fill" : "pencil.circle")
                }
                .buttonStyle(.borderless)
                .help("Write it in your own words")
            }
            if showNextField || !session.nextText.isEmpty {
                TextField("Next", text: $session.nextText, prompt: Text("“I'll …” in a few words"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var otherLabel: String {
        if case .goal(let g) = session.nextChoice { return g }
        if case .nextStep(_, _, let t) = session.nextChoice,
           session.followingStep?.step.text != t { return t }
        return "Other…"
    }

    private func nextChip(_ choice: PromptSession.NextChoice, _ title: String, _ icon: String) -> some View {
        let selected = session.nextChoice == choice
        return Button { session.setNext(choice) } label: {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.10)))
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.2))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: Time by goal — one stacked bar; tap for detail

    private var timeByGoal: some View {
        let rows = (showWeek ? session.weekRows : session.todayRows).filter { $0.kind != .notLogged && $0.seconds > 0 }
        let goalNames = rows.filter { $0.kind == .goal }.map(\.name)
        let summary = GoalAccounting.summary(rows, goals: goalNames)
        let total = max(1, rows.reduce(0) { $0 + $1.seconds })
        let color: (GoalTimeRow) -> Color = { $0.kind == .drift ? .orange : ($0.kind == .goal ? areaColor($0.name) : .gray) }
        return VStack(alignment: .leading, spacing: 5) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showTimeDetail.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(showWeek ? "Week" : "Today").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(rows) { r in
                                Rectangle().fill(color(r)).frame(width: max(2, geo.size.width * r.seconds / total - 1))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 6)
                    if summary.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    Image(systemName: showTimeDetail ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Time by goal — click for detail")
            if showTimeDetail {
                Picker("Range", selection: $showWeek) {
                    Text("Today").tag(false)
                    Text("Week").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                ForEach(rows.prefix(6)) { row in
                    HStack(spacing: 6) {
                        Circle().fill(color(row)).frame(width: 6, height: 6)
                        Text(row.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(durationText(row.seconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let w = summary.warning {
                    Text(w).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Skip") { session.finish(.skipped) }
            Button("+1 min") { session.extend() }
            Button { session.onStuck?() } label: { Image(systemName: "lifepreserver") }
                .help("Stuck? Get help with what's blocking you")
            Spacer()
            Button("Save  ⌘↩") { session.finish(.completed) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!session.canSave)
        }
    }
}

/// Simple wrapping row of chips.
struct FlowChips<Content: View>: View {
    let items: [String]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        // Group into rows of up to 3 to keep it compact and predictable.
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { content($0) }
                }
            }
        }
    }
}

struct CountdownRing: View {
    let remaining: Int
    let total: Int

    private var fraction: Double { total > 0 ? Double(remaining) / Double(total) : 0 }
    private var color: Color { remaining <= 30 ? .red : .accentColor }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
            Text(mmss(remaining))
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel("\(remaining) seconds left")
    }
}
