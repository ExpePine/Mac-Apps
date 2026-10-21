import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Shows stored reports in the same layout as the morning email.
struct ReportsView: View {
    let reports: ReportService
    @ObservedObject var archive: ReportArchive
    var coach: CoachService? = nil

    @State private var kind: ReportKind = .calendar
    @State private var anchor = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var generating = false
    @State private var progress = ""
    @State private var replayDay: ReplayDay?
    @State private var lastAutoRefresh: [String: Date] = [:]

    struct ReplayDay: Identifiable { let id = UUID(); let day: Date }

    private var interval: DateInterval { archive.interval(kind, containing: anchor) }
    private var isCurrentPeriod: Bool { interval.contains(Date()) }

    /// HTML for the selected period (nil = daily report not generated yet).
    private var html: String? {
        _ = archive.version   // refresh after saves
        switch kind {
        case .day:
            return archive.load(anchor).map(RecapRenderer.html)
        default:
            return RecapRenderer.html(archive.aggregate(kind, containing: anchor))
        }
    }

    private var missing: [Date] { _ = archive.version; return archive.missingDays(kind, containing: anchor) }

    /// The day that should be kept up to date on screen right now.
    private var liveDay: Date? {
        switch kind {
        case .day: return anchor
        case .calendar: return isCurrentPeriod ? Date() : nil
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .task(id: "\(kind.rawValue)-\(UsageStore.key(anchor))") { await keepFresh() }
                .sheet(item: $replayDay) { r in DayStoryView(story: archive.story(for: r.day)) }
            Divider()
            if kind != .day && !missing.isEmpty { missingBanner }
            if kind == .calendar {
                CalendarGrid(archive: archive, month: anchor, onReplay: { replayDay = ReplayDay(day: $0) },
                             footer: AnyView(WorkPathPanel(archive: archive, coach: coach, anchor: anchor)
                                .id(UsageStore.key(archive.interval(.month, containing: anchor).start)))) { day in
                    anchor = day
                    kind = .day
                }
            } else {
                content
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $kind) {
                ForEach(ReportKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)

            HStack(spacing: 4) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous \(kind.rawValue.lowercased())")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isCurrentPeriod)
                    .help("Next \(kind.rawValue.lowercased())")
            }
            .buttonStyle(.borderless)

            Text(archive.label(kind, interval))
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Button("Today") { anchor = Date() }
                .disabled(isCurrentPeriod)

            if kind == .day {
                Button { replayDay = ReplayDay(day: anchor) } label: { Label("Replay", systemImage: "play.circle") }
                    .help("Animated replay of this day")
                    .disabled(!archive.hasActivity(anchor))
            }

            Menu {
                Button("Timeline data (CSV)…", action: exportCSV)
                Button("Report (HTML)…", action: exportHTML).disabled(html == nil)
                Divider()
                Button("Show reports folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([archive.directory])
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var missingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
            Text(kind == .calendar
                 ? "\(missing.count) day\(missing.count == 1 ? "" : "s") this month \(missing.count == 1 ? "has" : "have") no 3-word summary yet."
                 : "\(missing.count) day\(missing.count == 1 ? "" : "s") in this period \(missing.count == 1 ? "has" : "have") no stored report, so categories and successes are incomplete.")
                .font(.callout)
            Spacer()
            if generating {
                ProgressView().controlSize(.small)
                Text(progress).font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Generate \(missing.count)") { Task { await generate(missing) } }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let html {
            ReportWebView(html: html)
                .overlay(alignment: .topTrailing) {
                    if kind == .day {
                        HStack(spacing: 8) {
                            if generating {
                                ProgressView().controlSize(.small)
                                Text("Updating…")
                            } else {
                                Text(freshnessText)
                                Button { Task { await generate([anchor]) } } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                                .help("Rebuild this day's report from the latest log")
                            }
                        }
                        .font(.caption)
                        .controlSize(.small)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                    }
                }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(archive.hasActivity(anchor) ? "No report for this day yet" : "No activity on this day")
                    .font(.title3.weight(.semibold))
                if archive.hasActivity(anchor) {
                    Text(Calendar.current.isDateInToday(anchor)
                         ? "Today's report builds automatically and keeps updating while you look at it."
                         : "Build it from this day's check-ins and screen time.")
                        .foregroundStyle(.secondary)
                    if generating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(Calendar.current.isDateInToday(anchor) ? "Build now" : "Generate report") {
                            Task { await generate([anchor]) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func step(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: kind.calendarComponent, value: delta, to: anchor) {
            anchor = min(d, Date())
        }
    }

    private var freshnessText: String {
        _ = archive.version
        guard let built = archive.load(anchor)?.generatedAt else { return "" }
        let time = built.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(anchor) { return "Live · updated \(time)" }
        return archive.isStale(anchor) ? "Out of date" : "Updated \(built.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    /// Rebuilds the visible day when it's missing or stale; repeats every 5 min for today.
    private func keepFresh() async {
        while !Task.isCancelled {
            if let day = liveDay { await refreshIfNeeded(day) }
            guard let day = liveDay, Calendar.current.isDateInToday(day) else { return }
            try? await Task.sleep(nanoseconds: 300_000_000_000)
        }
    }

    private func refreshIfNeeded(_ day: Date) async {
        guard !generating, archive.hasActivity(day) else { return }
        guard !archive.hasRecord(day) || archive.isStale(day) else { return }
        let key = UsageStore.key(day)
        if let last = lastAutoRefresh[key], Date().timeIntervalSince(last) < 600 { return }   // max one AI call / 10 min
        lastAutoRefresh[key] = Date()
        await generate([day])
    }

    private func generate(_ days: [Date]) async {
        generating = true
        for (i, day) in days.enumerated() {
            progress = "\(i + 1) of \(days.count)…"
            await reports.generateReport(for: day)
        }
        progress = ""
        generating = false
    }

    private var fileStem: String {
        let f = DateFormatter()
        switch kind {
        case .day: f.dateFormat = "yyyy-MM-dd"
        case .week: f.dateFormat = "yyyy-'W'ww"
        case .month, .calendar: f.dateFormat = "yyyy-MM"
        case .year: f.dateFormat = "yyyy"
        }
        return f.string(from: interval.start)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "activity-timeline-\(fileStem).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? archive.timelineCSV(kind, containing: anchor).write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportHTML() {
        guard let html else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(kind.recapKind.lowercased())-report-\(fileStem).html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Displays the report HTML exactly as the email renders it.
struct ReportWebView: NSViewRepresentable {
    let html: String

    final class Coordinator {
        var lastHTML = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }
}


// MARK: - Calendar

struct CalendarGrid: View {
    @ObservedObject var archive: ReportArchive
    let month: Date
    var onReplay: (Date) -> Void = { _ in }
    var footer: AnyView = AnyView(EmptyView())
    let onSelect: (Date) -> Void

    private let palette: [Color] = [
        Color(red: 0.31, green: 0.42, blue: 0.93), Color(red: 0.08, green: 0.64, blue: 0.55),
        Color(red: 0.91, green: 0.51, blue: 0.23), Color(red: 0.76, green: 0.28, blue: 0.61),
        Color(red: 0.54, green: 0.36, blue: 0.96), Color(red: 0.85, green: 0.64, blue: 0.11),
        Color(red: 0.23, green: 0.62, blue: 0.85), Color(red: 0.48, green: 0.53, blue: 0.60),
    ]

    /// Same category always gets the same colour.
    private func color(for category: String?) -> Color {
        guard let category else { return .secondary }
        let sum = category.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }

    private var cal: Calendar { Calendar.current }

    /// Leading blanks + every day of the month.
    private var cells: [Date?] {
        _ = archive.version
        let range = archive.interval(.month, containing: month)
        let first = range.start
        let weekday = cal.component(.weekday, from: first)
        let leading = (weekday - cal.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        var d = first
        while d < range.end {
            result.append(d)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(c).frame(width: 14, height: 4)
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var weekdayNames: [String] {
        let names = cal.shortWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(names[start...] + names[..<start])
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
        ScrollView {
            VStack(spacing: 8) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(weekdayNames, id: \.self) { name in
                        Text(name.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                        if let date {
                            DayCell(info: archive.calendarDay(date),
                                    tint: color(for: archive.calendarDay(date).topCategory),
                                    isToday: cal.isDateInToday(date),
                                    isFuture: date > Date())
                                .onTapGesture { onSelect(date) }
                                .contextMenu {
                                    Button("Open report") { onSelect(date) }
                                    Button("Replay this day") { onReplay(date) }
                                        .disabled(!archive.hasActivity(date))
                                }
                        } else {
                            Color.clear.frame(height: 96)
                        }
                    }
                }
                HStack(spacing: 14) {
                    legend(.green, "Goal-tied")
                    legend(.orange, "Drift / off-plan")
                    legend(.gray, "Other / untagged")
                    Spacer()
                }
                .padding(.top, 4)
                footer.padding(.top, 18)
            }
            .padding(20)
        }
    }
}

private struct DayCell: View {
    let info: ReportArchive.CalendarDay
    let tint: Color
    let isToday: Bool
    let isFuture: Bool

    private var hasActivity: Bool { info.checkIns > 0 || info.activeSeconds >= 60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(Calendar.current.component(.day, from: info.date))")
                    .font(.callout.weight(isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Color.white : (isFuture ? Color.secondary : Color.primary))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isToday ? Color.accentColor : Color.clear))
                Spacer()
                if info.successes > 0 {
                    Text("✅\(info.successes > 1 ? " \(info.successes)" : "")").font(.caption2)
                }
            }

            if let tagline = info.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hasActivity && !isFuture {
                Text(isToday ? "In progress" : "Not summarized")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let split = info.goalSplit {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.green).frame(width: geo.size.width * split.tied)
                        Rectangle().fill(Color.orange).frame(width: geo.size.width * split.drift)
                        Rectangle().fill(Color.gray.opacity(0.35))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 4)
                .help("\(Int(split.tied * 100))% goal-tied · \(Int(split.drift * 100))% drift")
            }

            if info.activeSeconds >= 60 {
                HStack(spacing: 4) {
                    Capsule()
                        .fill(tint.opacity(0.8))
                        .frame(width: max(4, min(1, info.activeSeconds / 28_800) * 60), height: 4)
                    Text(durationText(info.activeSeconds))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(info.tagline != nil ? tint.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isToday ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06))
        )
        .opacity(isFuture ? 0.45 : 1)
        .contentShape(Rectangle())
        .help(info.tagline.map { "\($0) · click for the full report" } ?? "Click for the full report")
    }
}
