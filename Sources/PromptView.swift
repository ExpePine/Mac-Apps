import AppKit
import SwiftUI

struct PromptView: View {
    @ObservedObject var session: PromptSession
    @State private var showWeek = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let intent = session.previousIntent { intentCheck(intent) }
            pathSection
            noteSection
            nextSection
            if let msg = session.errorMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.todayRows.isEmpty { timeByGoal }
            buttons
        }
        .padding(20)
        .frame(width: 540)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Where were you?")
                    .font(.title2.weight(.semibold))
                Text(session.prompt.rangeText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let f = session.followThrough, f.total > 0 {
                    Label("Follow-through today: \(Int(f.done / Double(f.total) * 100))% (\(f.total) checked)",
                          systemImage: "arrow.uturn.forward.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            CountdownRing(remaining: session.remaining, total: session.totalSeconds)
        }
    }

    // MARK: Did I do what I said?

    private func intentCheck(_ intent: PromptSession.Intent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "quote.opening").foregroundStyle(.secondary)
                Text("You said you'd: ").foregroundColor(.secondary) + Text(intent.text).fontWeight(.semibold)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                resultChip("did", "Did it", "checkmark.circle.fill", .green)
                resultChip("partly", "Partly", "circle.lefthalf.filled", .yellow)
                resultChip("didnt", "Didn't", "xmark.circle.fill", .orange)
                Spacer()
                if session.intentResult != nil {
                    Text("auto-checked from your tap — change if wrong").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if session.intentResult == "didnt" || session.intentResult == "partly" {
                let reasons = ["Pulled into something else", "Took longer", "Interrupted", "Changed plan", "Distracted", "Blocked"]
                FlowChips(items: reasons) { r in
                    chip(r, color: .orange, selected: session.intentReason == r) {
                        session.intentReason = session.intentReason == r ? nil : r
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.07)))
    }

    private func resultChip(_ value: String, _ title: String, _ icon: String, _ tint: Color) -> some View {
        let selected = session.intentResult == value
        return Button { session.setIntentResult(value) } label: {
            Label(title, systemImage: icon)
                .font(.callout)
                .foregroundStyle(selected ? tint : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? tint.opacity(0.2) : Color.secondary.opacity(0.10)))
                .overlay(Capsule().strokeBorder(selected ? tint : Color.clear, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Next interval

    private var nextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEXT \(session.intervalMinutes) MIN — WHAT WILL YOU DO?")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if session.hasSelection && session.selectedKind != "drift" {
                    nextChip(.same, "Continue this", "arrow.forward.circle")
                }
                if let f = session.followingStep {
                    nextChip(.nextStep(planID: f.path.id, stepID: f.step.id, text: f.step.text),
                             "Next: \(f.step.text)", "forward.end")
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
            TextField("Next", text: $session.nextText, prompt: Text("Optional — “I'll …” in a few words"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    private var otherLabel: String {
        if case .goal(let g) = session.nextChoice { return "Goal: \(g)" }
        if case .nextStep(_, _, let t) = session.nextChoice,
           session.followingStep?.step.text != t { return "Step: \(t)" }
        return "Something else…"
    }

    private func nextChip(_ choice: PromptSession.NextChoice, _ title: String, _ icon: String) -> some View {
        let selected = session.nextChoice == choice
        return Button { session.setNext(choice) } label: {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.10)))
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Path — tap where you are

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.guessing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Guessing where you are…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let note = session.guessNote {
                Label(note, systemImage: "sparkles").font(.caption).foregroundStyle(Color.accentColor)
            }

            ForEach(session.planPaths) { path in
                VStack(alignment: .leading, spacing: 4) {
                    Text("PLAN · \(path.goal)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    ForEach(path.steps) { step in
                        stepRow(step, path: path)
                    }
                }
            }

            if !session.goalOptions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GOALS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    FlowChips(items: session.goalOptions) { g in
                        chip(g, color: areaColor(g), selected: session.selectedGoal == g && session.selectedStep == nil) {
                            session.pickGoal(g)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                kindChip("break", "Break", "cup.and.saucer")
                kindChip("meeting", "Meeting", "person.2")
                kindChip("admin", "Admin", "tray")
                kindChip("drift", "Drifted", "arrow.triangle.branch")
            }
        }
    }

    private func stepRow(_ step: PlanStep, path: PromptSession.PlanPath) -> some View {
        let selected = session.selectedStep == step.id
        return VStack(alignment: .leading, spacing: 4) {
            Button { session.pickStep(step, in: path) } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(step.text).lineLimit(1)
                    if step.id == path.currentStepID {
                        Text("NOW").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if let r = step.rangeText { Text(r).font(.caption).foregroundStyle(.tertiary) }
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected {
                Toggle("Finished this step", isOn: $session.stepDone)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .padding(.leading, 32)
            }
        }
    }

    private func chip(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? color.opacity(0.25) : Color.secondary.opacity(0.10)))
            .overlay(Capsule().strokeBorder(selected ? color : Color.clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func kindChip(_ kind: String, _ title: String, _ icon: String) -> some View {
        let selected = session.selectedKind == kind
        let tint: Color = kind == "drift" ? .orange : .teal
        return Button { session.pickKind(kind) } label: {
            Label(title, systemImage: icon)
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? tint.opacity(0.25) : Color.secondary.opacity(0.10)))
                .overlay(Capsule().strokeBorder(selected ? tint : Color.clear, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Optional note

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Note", text: $session.text, prompt: Text(session.hasSelection
                                                                   ? "Optional — a word or two"
                                                                   : "Tap above, or type / speak what you did"),
                          axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button {
                    Task { await session.toggleRecording() }
                } label: {
                    Image(systemName: session.isRecording ? "stop.circle.fill" : "mic.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.isRecording ? Color.red : Color.accentColor)
                .disabled(session.isTranscribing)
                .keyboardShortcut("r", modifiers: .command)
                .help("Speak instead (⌘R)")
            }
            if session.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(mmss(session.recordingSeconds)).monospacedDigit().font(.caption)
                }
            } else if session.isTranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Converting speech to text…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Time by goal

    private var timeByGoal: some View {
        let rows = (showWeek ? session.weekRows : session.todayRows).filter { $0.kind != .notLogged }
        let goalNames = rows.filter { $0.kind == .goal }.map(\.name)
        let summary = GoalAccounting.summary(rows, goals: goalNames)
        let maxV = max(60, rows.map(\.seconds).max() ?? 60)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TIME BY GOAL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("Range", selection: $showWeek) {
                    Text("Today").tag(false)
                    Text("Week").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130).controlSize(.small)
            }
            ForEach(rows.prefix(6)) { row in
                HStack(spacing: 8) {
                    Text(row.name).font(.caption).lineLimit(1).frame(width: 170, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Color.secondary.opacity(0.1))
                            .overlay(alignment: .leading) {
                                Capsule().fill(row.kind == .drift ? Color.orange : (row.kind == .goal ? areaColor(row.name) : Color.gray))
                                    .frame(width: max(row.seconds > 0 ? 4 : 0, geo.size.width * row.seconds / maxV))
                            }
                    }
                    .frame(height: 6)
                    Text(row.seconds > 0 ? durationText(row.seconds) : "—")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
            if let w = summary.warning {
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            Button("Skip") { session.finish(.skipped) }
            Button("+1 min") { session.extend() }
            Button { session.onStuck?() } label: { Label("Stuck?", systemImage: "lifepreserver") }
                .help("Get help with what's blocking you")
            Spacer()
            Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
            Button("Save") { session.finish(.completed) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
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
