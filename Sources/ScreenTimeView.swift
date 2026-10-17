import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sessions (merged segments)

struct UsageSession: Identifiable {
    let id = UUID()
    let key: String
    let app: String
    var start: Int
    var end: Int
    var active: Int          // seconds actually in front (gaps excluded)
}

/// Merges consecutive segments with the same key when the gap between them is small.
func mergeSessions(_ segments: [UsageSegment], gap: Int, key: (UsageSegment) -> String?) -> [UsageSession] {
    var result: [UsageSession] = []
    var open: [String: Int] = [:]      // key -> index of its latest session
    for seg in segments.sorted(by: { $0.start < $1.start }) {
        guard let k = key(seg) else { continue }
        if let i = open[k], seg.start - result[i].end <= gap {
            result[i].end = max(result[i].end, seg.end)
            result[i].active += seg.seconds
        } else {
            result.append(UsageSession(key: k, app: seg.app, start: seg.start, end: seg.end, active: seg.seconds))
            open[k] = result.count - 1
        }
    }
    return result.sorted { $0.start < $1.start }
}

func clockText(_ secondsOfDay: Int, on day: Date) -> String {
    Calendar.current.startOfDay(for: day).addingTimeInterval(TimeInterval(secondsOfDay))
        .formatted(date: .omitted, time: .shortened)
}

// MARK: - Screen Time

struct ScreenTimeView: View {
    let app: AppDelegate
    @ObservedObject var tracker: UsageTracker

    enum Mode: String, CaseIterable, Identifiable { case websites = "Websites", apps = "Apps"; var id: String { rawValue } }
    struct Lane: Identifiable { var id: String { name }; let name: String; let total: Int; let sessions: [UsageSession] }
    struct ReplayRequest: Identifiable { let id = UUID(); let day: Date }

    @State private var day = Date()
    @State private var mode: Mode = .websites
    @State private var hoverText: String?
    @State private var replay: ReplayRequest?

    private var usage: DayUsage {
        _ = tracker.today.activeSeconds     // refresh live for today
        return tracker.usage.usage(for: day)
    }
    private var segments: [UsageSegment] { usage.segments ?? [] }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    private func key(_ s: UsageSegment) -> String? { mode == .websites ? s.site : s.app }

    /// Sessions for the list: gaps up to 2 minutes are bridged.
    private var sessions: [UsageSession] { mergeSessions(segments, gap: 120, key: key) }

    private var lanes: [Lane] {
        let drawn = mergeSessions(segments, gap: 45, key: key)
        var totals: [String: Int] = [:]
        for s in drawn { totals[s.key, default: 0] += s.active }
        let top = totals.sorted { $0.value > $1.value }.prefix(8).map(\.key)
        var lanes = top.map { k in Lane(name: k, total: totals[k] ?? 0, sessions: drawn.filter { $0.key == k }) }
        let rest = drawn.filter { !top.contains($0.key) }
        if !rest.isEmpty {
            lanes.append(Lane(name: mode == .websites ? "Other sites" : "Other apps",
                              total: rest.reduce(0) { $0 + $1.active }, sessions: rest))
        }
        return lanes
    }

    /// Visible window, in whole hours.
    private var range: (start: Int, end: Int) {
        let starts = segments.map(\.start), ends = segments.map(\.end)
        var lo = ((starts.min() ?? 9 * 3600) / 3600) * 3600
        var hi = (((ends.max() ?? 18 * 3600) + 3599) / 3600) * 3600
        if isToday {
            let now = Int(Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())))
            hi = max(hi, ((now + 3599) / 3600) * 3600)
        }
        if hi - lo < 2 * 3600 { hi = min(24 * 3600, lo + 2 * 3600); lo = max(0, hi - 2 * 3600) }
        return (lo, hi)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tiles
                    if segments.isEmpty {
                        fallback
                    } else {
                        Card(title: "\(mode.rawValue) timeline", symbol: "chart.bar.doc.horizontal") {
                            if lanes.isEmpty {
                                Text(mode == .websites ? "No website time recorded on this day." : "No app time recorded.")
                                    .foregroundStyle(.secondary)
                            } else {
                                LanesChart(lanes: lanes, range: range, day: day, isToday: isToday, hoverText: $hoverText)
                            }
                        }
                        Card(title: "Sessions", symbol: "list.bullet") {
                            let list = sessions.filter { $0.active >= 60 }
                            if list.isEmpty {
                                Text("No sessions of a minute or more.").foregroundStyle(.secondary)
                            }
                            ForEach(list) { s in
                                HStack(spacing: 10) {
                                    Text("\(clockText(s.start, on: day))–\(clockText(s.end, on: day))")
                                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                                        .frame(width: 150, alignment: .leading)
                                    Circle().fill(areaColor(s.key)).frame(width: 8, height: 8)
                                    Text(s.key).lineLimit(1)
                                    if mode == .websites {
                                        Text(s.app).font(.caption).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text(durationText(Double(s.active))).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .sheet(item: $replay) { r in DayStoryView(story: app.archive.story(for: r.day)) }
    }

    // MARK: Pieces

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            HStack(spacing: 4) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.disabled(isToday)
            }
            .buttonStyle(.borderless)
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())).font(.headline)
            Spacer()
            Button("Today") { day = Date() }.disabled(isToday)
            Button { replay = ReplayRequest(day: day) } label: { Label("Replay day", systemImage: "play.circle") }
            Button { exportCSV() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(segments.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var tiles: some View {
        let webSeconds = usage.sites.values.reduce(0, +)
        let siteCount = usage.sites.filter { $0.value >= 60 }.count
        let longest = sessions.max { $0.active < $1.active }
        return HStack(spacing: 12) {
            StatTile(value: durationText(usage.activeSeconds), label: "Active screen time", symbol: "desktopcomputer", tint: .orange)
            StatTile(value: durationText(webSeconds), label: "On websites", symbol: "globe", tint: .accentColor)
            StatTile(value: "\(siteCount)", label: "Sites (1 min+)", symbol: "square.grid.2x2", tint: .green)
            StatTile(value: longest.map { durationText(Double($0.active)) } ?? "–",
                     label: longest.map { "Longest: \($0.key)" } ?? "Longest stretch",
                     symbol: "timer", tint: .purple)
        }
    }

    /// Days recorded before per-visit tracking: hourly totals + top sites.
    private var fallback: some View {
        Card(title: "By hour", symbol: "chart.bar") {
            Text(usage.activeSeconds < 60
                 ? "No screen time recorded on this day."
                 : "The detailed timeline starts from the day this version was installed. Here's what was recorded by hour.")
                .foregroundStyle(.secondary)
            if usage.activeSeconds >= 60 {
                let values = (0..<24).map { usage.hourly[String(format: "%02d", $0)] ?? 0 }
                let maxV = max(1, values.max() ?? 1)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { h in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(values[h] > 0 ? 0.85 : 0.12))
                                .frame(height: max(2, CGFloat(values[h] / maxV) * 90))
                            Text(h % 3 == 0 ? "\(h)" : " ").font(.caption2).foregroundStyle(.secondary)
                        }
                        .help("\(h):00 – \(durationText(values[h]))")
                    }
                }
                .frame(height: 110)
                ForEach(usage.top(usage.sites, 8), id: \.name) { s in
                    HStack {
                        Circle().fill(areaColor(s.name)).frame(width: 8, height: 8)
                        Text(s.name)
                        Spacer()
                        Text(durationText(s.seconds)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private func shift(_ d: Int) {
        if let n = Calendar.current.date(byAdding: .day, value: d, to: day) { day = min(n, Date()) }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "screen-time-\(f.string(from: day)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func esc(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["date,start,end,seconds,app,site"]
        for s in segments.sorted(by: { $0.start < $1.start }) {
            lines.append([f.string(from: day), clockText(s.start, on: day), clockText(s.end, on: day),
                          "\(s.seconds)", esc(s.app), esc(s.site)].joined(separator: ","))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Lanes chart (one Canvas, hover to inspect)

struct LanesChart: View {
    let lanes: [ScreenTimeView.Lane]
    let range: (start: Int, end: Int)
    let day: Date
    let isToday: Bool
    @Binding var hoverText: String?

    private let rowH: CGFloat = 28
    private let labelW: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hoverText ?? "Hover a bar for details")
                .font(.callout)
                .foregroundStyle(hoverText == nil ? Color.secondary : Color.primary)
                .monospacedDigit()
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 18)
                    ForEach(lanes) { lane in
                        HStack(spacing: 6) {
                            Circle().fill(areaColor(lane.name)).frame(width: 8, height: 8)
                            Text(lane.name).lineLimit(1).font(.callout)
                            Spacer(minLength: 2)
                            Text(durationText(Double(lane.total))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .frame(height: rowH)
                    }
                }
                .frame(width: labelW)

                GeometryReader { geo in
                    let span = Double(max(1, range.end - range.start))
                    let width = geo.size.width
                    VStack(spacing: 0) {
                        axis(width: width, span: span)
                        Canvas { ctx, size in
                            // hour grid
                            var h = range.start
                            while h <= range.end {
                                let x = CGFloat(Double(h - range.start) / span) * size.width
                                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.secondary.opacity(0.15)))
                                h += 3600
                            }
                            for (row, lane) in lanes.enumerated() {
                                let y = CGFloat(row) * rowH
                                ctx.fill(Path(roundedRect: CGRect(x: 0, y: y + 5, width: size.width, height: rowH - 10), cornerRadius: 4),
                                         with: .color(.secondary.opacity(0.07)))
                                let color = areaColor(lane.name)
                                for s in lane.sessions {
                                    let x0 = CGFloat(Double(s.start - range.start) / span) * size.width
                                    let x1 = CGFloat(Double(s.end - range.start) / span) * size.width
                                    ctx.fill(Path(roundedRect: CGRect(x: x0, y: y + 6, width: max(2, x1 - x0), height: rowH - 12), cornerRadius: 3),
                                             with: .color(color))
                                }
                            }
                            if isToday {
                                let now = Int(Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())))
                                if now >= range.start && now <= range.end {
                                    let x = CGFloat(Double(now - range.start) / span) * size.width
                                    ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.red.opacity(0.8)))
                                }
                            }
                        }
                        .frame(height: CGFloat(lanes.count) * rowH)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): hoverText = describe(at: p, width: width, span: span)
                            case .ended: hoverText = nil
                            }
                        }
                    }
                }
                .frame(height: 18 + CGFloat(lanes.count) * rowH)
            }
        }
    }

    private func axis(width: CGFloat, span: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: range.start, through: range.end, by: 3600)), id: \.self) { h in
                let x = CGFloat(Double(h - range.start) / span) * width
                Text(clockText(h, on: day))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(max(x, 18), width - 18), y: 8)
            }
        }
        .frame(width: width, height: 18)
    }

    private func describe(at p: CGPoint, width: CGFloat, span: Double) -> String? {
        let row = Int(p.y / rowH)
        guard row >= 0, row < lanes.count, width > 0 else { return nil }
        let t = range.start + Int(Double(p.x / width) * span)
        let tolerance = Int(span / Double(width) * 3)
        let lane = lanes[row]
        guard let s = lane.sessions.first(where: { t >= $0.start - tolerance && t <= $0.end + tolerance }) else {
            return "\(lane.name) · \(clockText(t, on: day))"
        }
        return "\(s.key) · \(clockText(s.start, on: day))–\(clockText(s.end, on: day)) · \(durationText(Double(s.active)))\(s.key != s.app ? " · \(s.app)" : "")"
    }
}
