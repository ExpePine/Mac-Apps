import SwiftUI

// MARK: - Data for one day's replay

struct DayStory {
    struct Block: Identifiable {
        let id = UUID()
        let start: Double          // fraction of day 0...1
        let end: Double
        let title: String
        let category: String
        let success: Bool?
    }
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let value: Double
    }
    struct Drift: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String?
        let tint: Color
    }

    var date: Date
    var tagline = ""
    var headline = ""
    var activeSeconds: Double = 0
    var checkIns = 0
    var missed = 0
    var blocks: [Block] = []
    var categories: [Item] = []        // minutes
    var sites: [Item] = []             // seconds
    var hourly: [Double] = Array(repeating: 0, count: 24)
    var wins: [String] = []
    var drifts: [Drift] = []
    var onPlanPercent: Int?
    var goalsDone = 0
    var goalsTotal = 0
}

extension ReportArchive {
    func story(for day: Date) -> DayStory {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: day)
        func frac(_ d: Date) -> Double { min(1, max(0, d.timeIntervalSince(midnight) / 86_400)) }
        func time(_ secs: Int) -> String { clockText(secs, on: day) }

        let rec = load(day)
        let entries = store.entries(on: day).sorted { $0.periodStart < $1.periodStart }
        let answered = entries.filter { $0.status != .missed && $0.status != .skipped }
        let u = usage.usage(for: day)
        let segments = u.segments ?? []

        var s = DayStory(date: day)
        s.tagline = rec?.tagline ?? rec.map { RecapBuilder.threeWords($0.headline) } ?? ""
        s.headline = rec?.headline ?? (answered.isEmpty ? "A quiet day." : "\(answered.count) check-ins logged.")
        s.activeSeconds = u.activeSeconds
        s.checkIns = answered.count
        s.missed = entries.filter { $0.status == .missed }.count

        // What happened when: report timeline → check-ins → app sessions
        if let rec, !rec.timeline.isEmpty {
            s.blocks = rec.timeline.map {
                DayStory.Block(start: frac($0.start), end: frac($0.end), title: $0.titles.first ?? "",
                               category: $0.category, success: $0.success)
            }
        } else if !answered.isEmpty {
            s.blocks = answered.map {
                DayStory.Block(start: frac($0.periodStart), end: frac($0.periodEnd),
                               title: String(CoachService.text(of: $0).prefix(48)), category: "Check-in",
                               success: RecapBuilder.keywordSuccess(CoachService.text(of: $0)))
            }
        } else if !segments.isEmpty {
            s.blocks = mergeSessions(segments, gap: 120) { $0.app }
                .filter { $0.active >= 120 }
                .map { DayStory.Block(start: Double($0.start) / 86_400, end: Double($0.end) / 86_400,
                                      title: $0.key, category: $0.key, success: nil) }
        }

        if let rec {
            s.categories = rec.categories.prefix(6).map { DayStory.Item(title: $0.name, value: Double($0.minutes)) }
        } else {
            var minutes: [String: Double] = [:]
            for b in s.blocks { minutes[b.category, default: 0] += (b.end - b.start) * 1440 }
            s.categories = minutes.sorted { $0.value > $1.value }.prefix(6).map { DayStory.Item(title: $0.key, value: $0.value) }
        }

        s.sites = u.top(u.sites, 6).filter { $0.seconds >= 60 }.map { DayStory.Item(title: $0.name, value: $0.seconds) }
        s.hourly = (0..<24).map { u.hourly[String(format: "%02d", $0)] ?? 0 }
        s.wins = rec?.solved
            ?? answered.filter { RecapBuilder.keywordSuccess(CoachService.text(of: $0)) == true }
                       .map { String(CoachService.text(of: $0).prefix(70)) }

        // Why I didn't work
        let missed = entries.filter { $0.status == .missed }
        if !missed.isEmpty {
            s.drifts.append(.init(icon: "bell.slash.fill",
                                  title: "\(missed.count) check-in\(missed.count == 1 ? "" : "s") missed",
                                  detail: missed.prefix(4).map(\.timeRangeText).joined(separator: " · "),
                                  tint: .orange))
        }
        for e in entries where e.goalAligned == false {
            let why = e.explanation ?? e.deviationNote ?? "Off plan"
            s.drifts.append(.init(icon: e.explanationAccepted == true ? "arrow.triangle.branch" : "exclamationmark.bubble.fill",
                                  title: why,
                                  detail: "\(e.timeRangeText) · \(String(CoachService.text(of: e).prefix(60)))",
                                  tint: e.explanationAccepted == true ? .teal : .orange))
        }
        let skipped = entries.filter { $0.status == .skipped }.count
        if skipped > 0 {
            s.drifts.append(.init(icon: "forward.fill", title: "\(skipped) check-in\(skipped == 1 ? "" : "s") skipped",
                                  detail: nil, tint: .gray))
        }
        // Away from the computer: gaps of 20+ minutes between activity
        let sorted = segments.sorted { $0.start < $1.start }
        var gaps: [(Int, Int)] = []
        var lastEnd = sorted.first?.end
        for seg in sorted.dropFirst() {
            if let le = lastEnd, seg.start - le >= 1200 { gaps.append((le, seg.start)) }
            lastEnd = max(lastEnd ?? seg.end, seg.end)
        }
        for g in gaps.sorted(by: { ($0.1 - $0.0) > ($1.1 - $1.0) }).prefix(3).sorted(by: { $0.0 < $1.0 }) {
            s.drifts.append(.init(icon: "moon.zzz.fill", title: "Away \(durationText(Double(g.1 - g.0)))",
                                  detail: "\(time(g.0)) – \(time(g.1))", tint: .indigo))
        }
        for b in (plans?.plans ?? []).flatMap(\.blockers) where cal.isDate(b.date, inSameDayAs: day) {
            s.drifts.append(.init(icon: "bolt.horizontal.circle.fill", title: b.reason,
                                  detail: "Flow broke on: \(b.stepText)", tint: .red))
        }

        let checked = answered.filter { $0.goalAligned != nil }
        if !checked.isEmpty {
            s.onPlanPercent = Int((Double(checked.filter { $0.goalAligned == true }.count) / Double(checked.count) * 100).rounded())
        }
        let g = goals.goals(on: day)
        s.goalsTotal = g.count
        s.goalsDone = g.filter(\.done).count
        return s
    }
}

// MARK: - Player

struct DayStoryView: View {
    let story: DayStory
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Scene: Hashable { case intro, clock, categories, web, energy, wins, drift, outro }

    @State private var index = 0
    @State private var progress = 0.0
    @State private var paused = false

    private let sceneSeconds = 7.0

    private var scenes: [Scene] {
        var list: [Scene] = [.intro]
        if !story.blocks.isEmpty { list.append(.clock) }
        if !story.categories.isEmpty { list.append(.categories) }
        if !story.sites.isEmpty { list.append(.web) }
        if story.hourly.reduce(0, +) >= 60 { list.append(.energy) }
        if !story.wins.isEmpty { list.append(.wins) }
        list.append(.drift)
        list.append(.outro)
        return list
    }

    private var scene: Scene { scenes[min(index, scenes.count - 1)] }

    private var background: [Color] {
        switch scene {
        case .intro, .outro: return [Color(red: 0.12, green: 0.11, blue: 0.37), Color(red: 0.14, green: 0.39, blue: 0.92)]
        case .clock: return [Color(red: 0.05, green: 0.10, blue: 0.25), Color(red: 0.10, green: 0.30, blue: 0.55)]
        case .categories: return [Color(red: 0.20, green: 0.08, blue: 0.35), Color(red: 0.45, green: 0.20, blue: 0.70)]
        case .web: return [Color(red: 0.03, green: 0.20, blue: 0.25), Color(red: 0.05, green: 0.50, blue: 0.55)]
        case .energy: return [Color(red: 0.30, green: 0.12, blue: 0.05), Color(red: 0.80, green: 0.40, blue: 0.10)]
        case .wins: return [Color(red: 0.04, green: 0.25, blue: 0.15), Color(red: 0.10, green: 0.60, blue: 0.35)]
        case .drift: return [Color(red: 0.15, green: 0.15, blue: 0.20), Color(red: 0.35, green: 0.30, blue: 0.40)]
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: background, startPoint: .topLeading, endPoint: .bottomTrailing)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: index)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                progressBars
                sceneView
                    .id(index)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                     removal: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        location.x < 200 ? previous() : next()
                    }
                controls
            }
            .padding(22)
        }
        .foregroundStyle(.white)
        .frame(width: 780, height: 540)
        .task(id: index) { await autoAdvance() }
    }

    // MARK: Chrome

    private var progressBars: some View {
        HStack(spacing: 4) {
            ForEach(0..<scenes.count, id: \.self) { i in
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white)
                                .frame(width: geo.size.width * (i < index ? 1 : (i == index ? progress : 0)))
                        }
                }
                .frame(height: 3)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Text(story.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.callout).opacity(0.75)
            Spacer()
            Button { previous() } label: { Image(systemName: "backward.fill") }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                .keyboardShortcut(.space, modifiers: [])
            Button { next() } label: { Image(systemName: "forward.fill") }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    // MARK: Navigation

    private func autoAdvance() async {
        progress = 0
        let step = 0.05
        while progress < 1 {
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            if Task.isCancelled { return }
            if !paused { progress = min(1, progress + step / sceneSeconds) }
        }
        if index < scenes.count - 1 { next() } else { paused = true }
    }

    private func next() {
        guard index < scenes.count - 1 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { index += 1 }
    }

    private func previous() {
        guard index > 0 else { progress = 0; return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { index -= 1 }
    }

    // MARK: Scenes

    @ViewBuilder private var sceneView: some View {
        switch scene {
        case .intro: IntroScene(story: story)
        case .clock: ClockScene(story: story)
        case .categories: BubblesScene(items: story.categories)
        case .web: RaceScene(items: story.sites)
        case .energy: EnergyScene(hourly: story.hourly)
        case .wins: WinsScene(wins: story.wins)
        case .drift: DriftScene(drifts: story.drifts)
        case .outro: OutroScene(story: story)
        }
    }
}

// MARK: - Animation helpers

/// Animates a number from 0 to its value.
struct CountUp: ViewModifier, Animatable {
    var value: Double
    let format: (Double) -> String
    var animatableData: Double { get { value } set { value = newValue } }
    func body(content: Content) -> some View { Text(format(value)) }
}

/// Runs `t` from 0 to 1 when the scene appears (instantly with Reduce Motion).
private struct Appear: ViewModifier {
    @Binding var t: Double
    var duration: Double = 2.2
    var delay: Double = 0.2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onAppear {
            if reduceMotion { t = 1; return }
            withAnimation(.easeOut(duration: duration).delay(delay)) { t = 1 }
        }
    }
}

private struct SceneTitle: View {
    let kicker: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker.uppercased()).font(.caption.weight(.semibold)).opacity(0.7)
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: 1. Intro — counters

private struct IntroScene: View {
    let story: DayStory
    @State private var t = 0.0

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Text(story.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.callout.weight(.semibold)).opacity(0.75)
            Text(story.tagline.isEmpty ? "Your day" : story.tagline)
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .scaleEffect(0.85 + 0.15 * t)
                .opacity(t)
            HStack(spacing: 40) {
                stat(story.activeSeconds, "active", fmt: { durationText($0) })
                stat(Double(story.checkIns), "check-ins", fmt: { "\(Int($0))" })
                stat(Double(story.wins.count), story.wins.count == 1 ? "win" : "wins", fmt: { "\(Int($0))" })
            }
            Spacer()
        }
        .modifier(Appear(t: $t, duration: 1.8))
    }

    private func stat(_ v: Double, _ label: String, fmt: @escaping (Double) -> String) -> some View {
        VStack(spacing: 4) {
            Color.clear.frame(width: 1, height: 1).modifier(CountUp(value: v * t, format: fmt))
                .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                .fixedSize()
            Text(label).font(.callout).opacity(0.75)
        }
        .frame(minWidth: 120)
    }
}

// MARK: 2. Clock — the day sweeps around a 24h dial

private struct ClockArc: Shape {
    var start: Double
    var end: Double
    var sweep: Double
    var animatableData: Double { get { sweep } set { sweep = newValue } }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let e = min(end, sweep)
        guard e > start else { return p }
        let r = min(rect.width, rect.height) / 2
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r,
                 startAngle: .degrees(start * 360 - 90), endAngle: .degrees(e * 360 - 90), clockwise: false)
        return p
    }
}

private struct ClockScene: View {
    let story: DayStory
    @State private var t = 0.0

    private var span: (Double, Double) {
        let s = story.blocks.map(\.start).min() ?? 0.375
        let e = story.blocks.map(\.end).max() ?? 0.75
        return (s, max(e, s + 0.01))
    }

    var body: some View {
        let sweep = span.0 + (span.1 - span.0) * t
        HStack(spacing: 30) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 26)
                ForEach(story.blocks) { b in
                    ClockArc(start: b.start, end: b.end, sweep: sweep)
                        .stroke(areaColor(b.category), style: StrokeStyle(lineWidth: 26, lineCap: .butt))
                }
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(h == 0 ? "12a" : (h == 12 ? "12p" : (h < 12 ? "\(h)a" : "\(h - 12)p")))
                        .font(.caption2.weight(.semibold)).opacity(0.7)
                        .offset(y: -150)
                        .rotationEffect(.degrees(Double(h) * 15))
                }
                Capsule().fill(.white).frame(width: 3, height: 118)
                    .offset(y: -59)
                    .rotationEffect(.degrees(sweep * 360))
                Circle().fill(.white).frame(width: 10, height: 10)
                VStack(spacing: 2) {
                    Color.clear.frame(width: 1, height: 1)
                        .modifier(CountUp(value: sweep * 86_400) { clockText(Int($0), on: story.date) })
                        .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        .fixedSize()
                }
                .offset(y: 40)
            }
            .frame(width: 260, height: 260)
            .padding(30)

            VStack(alignment: .leading, spacing: 8) {
                SceneTitle(kicker: "Your day on the clock", title: "How the hours went")
                let current = story.blocks.last { $0.start <= sweep }
                if let current {
                    HStack(spacing: 8) {
                        Circle().fill(areaColor(current.category)).frame(width: 10, height: 10)
                        Text(current.category).font(.headline)
                        if current.success == true { Text("✅") }
                    }
                    Text(current.title).font(.title3).opacity(0.85).lineLimit(2)
                        .id(current.id)
                        .transition(.opacity)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.3), value: story.blocks.last { $0.start <= sweep }?.id)
        }
        .modifier(Appear(t: $t, duration: 5.2, delay: 0.3))
    }
}

// MARK: 3. Categories — bubbles

private struct BubblesScene: View {
    let items: [DayStory.Item]
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let maxV = max(1, items.map(\.value).max() ?? 1)
        VStack(spacing: 16) {
            SceneTitle(kicker: "Where time went", title: items.first.map { "Mostly \($0.title)" } ?? "")
            Spacer()
            HStack(alignment: .center, spacing: 18) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let d = 70 + 130 * sqrt(item.value / maxV)
                    ZStack {
                        Circle().fill(areaColor(item.title).gradient)
                        VStack(spacing: 2) {
                            Text(item.title).font(.system(size: max(11, d / 9), weight: .semibold)).multilineTextAlignment(.center)
                                .lineLimit(2).minimumScaleFactor(0.7)
                            Text(durationText(item.value * 60)).font(.system(size: max(10, d / 11))).opacity(0.85)
                        }
                        .padding(8)
                    }
                    .frame(width: d, height: d)
                    .scaleEffect(shown ? 1 : 0.05)
                    .opacity(shown ? 1 : 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.6).delay(0.25 + Double(i) * 0.22), value: shown)
                }
            }
            Spacer()
        }
        .onAppear { shown = true }
    }
}

// MARK: 4. Web — bar race

private struct RaceScene: View {
    let items: [DayStory.Item]
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let maxV = max(1, items.map(\.value).max() ?? 1)
        VStack(alignment: .leading, spacing: 14) {
            SceneTitle(kicker: "On the web", title: items.first.map { "Top site: \($0.title)" } ?? "")
            Spacer()
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        let anim: Animation? = reduceMotion ? nil : .easeOut(duration: 1.4).delay(0.3 + Double(i) * 0.25)
                        HStack(spacing: 10) {
                            Text(item.title).font(.headline).lineLimit(1).frame(width: 190, alignment: .trailing)
                            Capsule().fill(areaColor(item.title))
                                .frame(width: max(6, (geo.size.width - 290) * (shown ? item.value / maxV : 0)), height: 22)
                                .animation(anim, value: shown)
                            Color.clear.frame(width: 1, height: 1)
                                .modifier(CountUp(value: shown ? item.value : 0, format: { durationText($0) }))
                                .animation(anim, value: shown)
                                .font(.callout.weight(.semibold)).monospacedDigit()
                                .fixedSize()
                        }
                    }
                }
            }
            Spacer()
        }
        .onAppear { shown = true }
    }
}

// MARK: 5. Energy — hourly activity curve

private struct EnergyScene: View {
    let hourly: [Double]
    @State private var t = 0.0
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var window: Range<Int> {
        let active = hourly.indices.filter { hourly[$0] >= 60 }
        let lo = max(0, (active.first ?? 8) - 1), hi = min(24, (active.last ?? 18) + 2)
        return lo..<max(hi, lo + 3)
    }

    var body: some View {
        let hours = Array(window)
        let values = hours.map { hourly[$0] }
        let maxV = max(60, values.max() ?? 60)
        let peakIndex = values.indices.max { values[$0] < values[$1] } ?? 0
        let peakHour = hours[peakIndex]
        VStack(alignment: .leading, spacing: 12) {
            SceneTitle(kicker: "Your energy", title: "Peak at \(hourLabel(peakHour)) · \(durationText(values[peakIndex]))")
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height - 24
                let pts: [CGPoint] = values.enumerated().map { i, v in
                    CGPoint(x: w * CGFloat(i) / CGFloat(max(1, values.count - 1)), y: h - h * CGFloat(v / maxV) * 0.92)
                }
                ZStack(alignment: .topLeading) {
                    curve(pts, close: true, h: h).fill(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.02)],
                                                                      startPoint: .top, endPoint: .bottom))
                        .opacity(t)
                    curve(pts, close: false, h: h).trim(from: 0, to: t)
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    if t > 0.98 {
                        Circle().fill(Color.yellow)
                            .frame(width: 16, height: 16)
                            .scaleEffect(pulse ? 1.6 : 1)
                            .opacity(pulse ? 0.6 : 1)
                            .position(pts[peakIndex])
                            .onAppear {
                                guard !reduceMotion else { return }
                                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
                            }
                    }
                    ForEach(Array(hours.enumerated()), id: \.offset) { i, hr in
                        if hours.count <= 12 || i % 2 == 0 {
                            Text(hourLabel(hr)).font(.caption2).opacity(0.7)
                                .position(x: w * CGFloat(i) / CGFloat(max(1, values.count - 1)), y: h + 14)
                        }
                    }
                }
            }
        }
        .modifier(Appear(t: $t, duration: 3.2, delay: 0.3))
    }

    private func hourLabel(_ h: Int) -> String {
        h == 0 || h == 24 ? "12a" : (h == 12 ? "12p" : (h < 12 ? "\(h)a" : "\(h - 12)p"))
    }

    private func curve(_ pts: [CGPoint], close: Bool, h: CGFloat) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for i in 1..<max(1, pts.count) where i < pts.count {
            let a = pts[i - 1], b = pts[i]
            let mid = (a.x + b.x) / 2
            p.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
        }
        if close, let last = pts.last {
            p.addLine(to: CGPoint(x: last.x, y: h))
            p.addLine(to: CGPoint(x: first.x, y: h))
            p.closeSubpath()
        }
        return p
    }
}

// MARK: 6. Wins

private struct WinsScene: View {
    let wins: [String]
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SceneTitle(kicker: "Wins", title: "\(wins.count) thing\(wins.count == 1 ? "" : "s") went right")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(wins.prefix(6).enumerated()), id: \.offset) { i, w in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26)).foregroundStyle(.white, Color.green)
                            .scaleEffect(shown ? 1 : 0.1)
                        Text(w).font(.title3).lineLimit(2)
                            .opacity(shown ? 1 : 0)
                            .offset(x: shown ? 0 : 30)
                    }
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.55).delay(0.3 + Double(i) * 0.45), value: shown)
                }
                if wins.count > 6 { Text("+ \(wins.count - 6) more").opacity(0.7) }
            }
            Spacer()
        }
        .onAppear { shown = true }
    }
}

// MARK: 7. Drift — why I didn't work

private struct DriftScene: View {
    let drifts: [DayStory.Drift]
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SceneTitle(kicker: "Why I didn't work", title: drifts.isEmpty ? "No drift today" : "What pulled you away")
            if drifts.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: "leaf.fill").font(.system(size: 70)).foregroundStyle(.green)
                        .scaleEffect(shown ? 1 : 0.2).opacity(shown ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.5).delay(0.3), value: shown)
                    Spacer()
                }
                Text("No missed check-ins, no long gaps, nothing off-plan.").frame(maxWidth: .infinity).opacity(0.85)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(drifts.prefix(7).enumerated()), id: \.element.id) { i, d in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: d.icon).font(.title2).foregroundStyle(d.tint).frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.title).font(.headline).lineLimit(2)
                                    if let detail = d.detail { Text(detail).font(.callout).opacity(0.75).lineLimit(2) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.10)))
                            .offset(x: shown ? 0 : 400)
                            .opacity(shown ? 1 : 0)
                            .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8).delay(0.2 + Double(i) * 0.35), value: shown)
                        }
                    }
                }
            }
        }
        .onAppear { shown = true }
    }
}

// MARK: 8. Outro — on-plan ring

private struct OutroScene: View {
    let story: DayStory
    @State private var t = 0.0

    var body: some View {
        HStack(spacing: 40) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 18)
                Circle()
                    .trim(from: 0, to: t * Double(story.onPlanPercent ?? 0) / 100)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Color.clear.frame(width: 1, height: 1)
                        .modifier(CountUp(value: t * Double(story.onPlanPercent ?? 0), format: { "\(Int($0))%" }))
                        .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .fixedSize()
                    Text(story.onPlanPercent == nil ? "no goal checks" : "on plan").font(.callout).opacity(0.75)
                }
            }
            .frame(width: 200, height: 200)

            VStack(alignment: .leading, spacing: 14) {
                SceneTitle(kicker: "That was your day", title: story.headline)
                if story.goalsTotal > 0 {
                    Label("\(story.goalsDone) of \(story.goalsTotal) goals done", systemImage: "target").font(.title3)
                }
                Label("\(durationText(story.activeSeconds)) active · \(story.checkIns) check-ins", systemImage: "clock")
                    .font(.title3).opacity(0.85)
            }
            .opacity(t)
        }
        .padding(.horizontal, 20)
        .modifier(Appear(t: $t, duration: 2.0))
    }
}
