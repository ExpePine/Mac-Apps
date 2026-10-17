import SwiftUI

/// Time slider under the Filter table: replays the whole Filter view over the last 30 stored days.
struct TimelineBar: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @AppStorage("timelineSecondsPerDay") private var secondsPerDay = 0.8

    var body: some View {
        VStack(spacing: 6) {
            if vm.timelineDays.isEmpty {
                HStack {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.secondary)
                    Text("No past days stored yet. The app saves one compressed snapshot per trading day; the replay fills up as days pass (30 days ≈ 6 weeks).")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { vm.closeTimeline() }
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        vm.isTimelinePlaying ? vm.pauseTimeline() : vm.playTimeline(secondsPerDay: secondsPerDay)
                    } label: {
                        Image(systemName: vm.isTimelinePlaying ? "pause.fill" : "play.fill")
                            .frame(width: 18)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help(vm.isTimelinePlaying ? "Pause" : "Play from \(vm.timelineDays.count) days ago up to today")

                    Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }
                        .disabled(vm.timelinePosition == 0)
                    Button { step(1) } label: { Image(systemName: "forward.frame.fill") }
                        .disabled(vm.timelineIndex == nil)

                    Slider(value: Binding(
                        get: { Double(vm.timelinePosition) },
                        set: { v in
                            vm.pauseTimeline()
                            vm.setTimelinePosition(Int(v.rounded()))
                        }),
                           in: 0...Double(vm.timelineDays.count), step: 1)
                        .frame(minWidth: 200)

                    HStack(spacing: 4) {
                        if vm.isTimelineLoading { ProgressView().controlSize(.small) }
                        Text(vm.timelineDateText)
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(vm.timelineIndex == nil ? Color.green : Color.orange)
                    }
                    .frame(minWidth: 150, alignment: .leading)

                    Picker("", selection: $secondsPerDay) {
                        Text("Slow").tag(1.5)
                        Text("Normal").tag(0.8)
                        Text("Fast").tag(0.35)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Playback speed")

                    Button("Live") { vm.pauseTimeline(); vm.goLive() }
                        .disabled(vm.timelineIndex == nil)
                    Button { vm.closeTimeline() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Close the time slider (back to live data)")
                }

                HStack {
                    Text(dayLabel(0))
                    Spacer()
                    Text("\(vm.timelineDays.count) stored day\(vm.timelineDays.count == 1 ? "" : "s") · then Live")
                    Spacer()
                    Text("Live")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.07))
    }

    private func step(_ delta: Int) {
        vm.pauseTimeline()
        vm.setTimelinePosition(vm.timelinePosition + delta)
    }

    private func dayLabel(_ i: Int) -> String {
        guard i < vm.timelineDays.count, let d = HistoryStore.date(fromKey: vm.timelineDays[i]) else { return "" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Banner shown above the table while a past day is displayed.
struct PastDayBanner: View {
    @EnvironmentObject var vm: ScreenerViewModel

    var body: some View {
        if vm.timelineIndex != nil {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Showing \(vm.timelineDateText) — filters, sort and colors applied to that day's data")
                Spacer()
                Button("Back to live") { vm.pauseTimeline(); vm.goLive() }
                    .buttonStyle(.borderless)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }
}
