import SwiftUI

/// Shown before check-ins start: today's goals (and this month's, if missing) are required.
struct GoalsGateView: View {
    @ObservedObject var goals: GoalsStore
    let onStart: () -> Void
    let onSnooze: () -> Void
    let onDayOff: () -> Void

    @State private var today: [String] = ["", "", ""]
    @State private var month: [String] = ["", "", ""]
    @State private var needsMonth = false
    @State private var loaded = false

    private var todayFilled: [String] { today.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private var monthFilled: [String] { month.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private var canStart: Bool { !todayFilled.isEmpty && (!needsMonth || !monthFilled.isEmpty) }

    /// Yesterday's unfinished goals, offered as one-tap carry-overs.
    private var carryOver: [String] {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return goals.goals(on: yesterday).filter { !$0.done }.map(\.text).filter { !today.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sunrise.fill").font(.system(size: 30)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Before we start — what's today about?").font(.title2.weight(.bold))
                    Text("Check-ins begin once your goals are set. Each one is compared with them.")
                        .foregroundStyle(.secondary)
                }
            }

            if needsMonth {
                section("THIS MONTH · \(Date().formatted(.dateTime.month(.wide)).uppercased())",
                        hint: "1–3 outcomes you want by the end of the month") {
                    ForEach(0..<3, id: \.self) { i in
                        field(icon: "calendar", text: $month[i],
                              prompt: i == 0 ? "Most important outcome this month" : "Another outcome (optional)")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THIS MONTH").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(goals.activeMonth) { g in
                        Label(g.text, systemImage: g.done ? "checkmark.circle.fill" : "calendar")
                            .font(.callout)
                            .foregroundStyle(g.done ? Color.secondary : Color.primary)
                    }
                }
            }

            section("TODAY · \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())",
                    hint: "1–3 things that would make today a good day") {
                ForEach(0..<3, id: \.self) { i in
                    field(icon: "target", text: $today[i],
                          prompt: i == 0 ? "The one thing that matters most today" : "Another goal (optional)")
                }
                if !carryOver.isEmpty {
                    HStack(spacing: 6) {
                        Text("Carry over:").font(.caption).foregroundStyle(.secondary)
                        ForEach(carryOver.prefix(3), id: \.self) { g in
                            Button(g) { addToday(g) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .lineLimit(1)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Day off — no tracking today", action: onDayOff)
                    .buttonStyle(.borderless)
                Button("Remind me in 10 min", action: onSnooze)
                    .buttonStyle(.borderless)
                Spacer()
                Button {
                    save()
                    onStart()
                } label: {
                    Label("Start my day", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
            if !canStart {
                Text(needsMonth && monthFilled.isEmpty ? "Add at least one goal for this month and one for today."
                                                        : "Add at least one goal for today.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(26)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, hint: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(hint).font(.caption).foregroundStyle(.tertiary)
            }
            content()
        }
    }

    private func field(icon: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            TextField("Goal", text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Data

    private func load() {
        guard !loaded else { return }
        loaded = true
        needsMonth = goals.activeMonth.isEmpty
        let existing = goals.activeToday.map(\.text)
        for (i, t) in existing.prefix(3).enumerated() { today[i] = t }
    }

    private func addToday(_ text: String) {
        if let i = today.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            today[i] = text
        } else {
            today.append(text)
        }
    }

    private func save() {
        if needsMonth {
            goals.setMonth(monthFilled.map { Goal(text: $0) })
        }
        // Keep done-state of goals that already existed today.
        let old = goals.activeToday
        let list = todayFilled.prefix(5).map { text in old.first { $0.text == text } ?? Goal(text: text) }
        goals.setToday(Array(list))
    }
}
