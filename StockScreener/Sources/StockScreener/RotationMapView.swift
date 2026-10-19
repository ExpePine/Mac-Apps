import SwiftUI
import Charts

/// Animated rotation map: sectors move day by day; only the important ones are labelled, hover names any dot,
/// click to follow a sector with its trail.
struct RotationMapView: View {
    let report: SectorReport
    @State private var dayIndex: Int?
    @State private var playing = false
    @State private var show: Show = .top
    @State private var minStocks = 5
    @State private var tails = true
    @State private var search = ""
    @State private var selected: Set<String> = []
    @State private var hover: String?

    enum Show: String, CaseIterable {
        case top = "Top 15 by score", movers = "15 biggest movers", leading = "Leading", improving = "Improving",
             weakening = "Weakening", lagging = "Lagging", all = "All sectors"
    }

    private var days: [String] { report.sectors.max { $0.path.count < $1.path.count }?.path.map(\.day) ?? [] }
    private var index: Int { min(dayIndex ?? (days.count - 1), max(0, days.count - 1)) }
    private var day: String { days.isEmpty ? "" : days[index] }

    private func point(_ s: SectorStat, _ d: String) -> RRGPoint? { s.path.last { $0.day <= d } }

    private var shown: [SectorStat] {
        let eligible = report.sectors.filter { $0.priced >= minStocks }
        let q = search.trimmingCharacters(in: .whitespaces)
        var base: [SectorStat]
        if !q.isEmpty {
            base = eligible.filter { $0.name.localizedCaseInsensitiveContains(q) }
        } else {
            switch show {
            case .top: base = Array(eligible.sorted { $0.rank < $1.rank }.prefix(15))
            case .movers:
                base = Array(eligible.sorted { moved($0) > moved($1) }.prefix(15))
            case .all: base = eligible
            case .leading, .improving, .weakening, .lagging:
                base = eligible.filter { s in point(s, day).map { Quadrant.of(ratio: $0.ratio, momentum: $0.momentum).rawValue == show.rawValue } ?? false }
            }
        }
        let extra = eligible.filter { selected.contains($0.name) && !base.contains(where: { b in b.name == $0.name }) }
        return base + extra
    }

    /// How far a sector travelled on the map over the last 10 days.
    private func moved(_ s: SectorStat) -> Double {
        guard let a = point(s, day), let i = s.path.lastIndex(where: { $0.day <= day }), i >= 10 else { return 0 }
        let b = s.path[i - 10]
        return hypot(a.ratio - b.ratio, a.momentum - b.momentum)
    }

    private func trail(_ s: SectorStat, _ n: Int) -> [RRGPoint] {
        guard let i = s.path.lastIndex(where: { $0.day <= day }) else { return [] }
        return Array(s.path[max(0, i - n + 1)...i])
    }

    /// Axis ranges from the 2nd–98th percentile of what's shown (so a few outliers don't squash everything).
    private func ranges(_ list: [SectorStat]) -> (ClosedRange<Double>, ClosedRange<Double>) {
        var xs: [Double] = [100], ys: [Double] = [100]
        for s in list { for p in s.path { xs.append(p.ratio); ys.append(p.momentum) } }
        xs.sort(); ys.sort()
        func pr(_ v: [Double]) -> ClosedRange<Double> {
            let lo = min(PerfCompare.percentile(v, 0.02), 99.5), hi = max(PerfCompare.percentile(v, 0.98), 100.5)
            let pad = (hi - lo) * 0.06
            return (lo - pad)...(hi + pad)
        }
        return (pr(xs), pr(ys))
    }

    var body: some View {
        let list = shown
        let (xr, yr) = ranges(list)
        let labelled = Set(selected).union(
            list.compactMap { s -> (String, Double)? in point(s, day).map { (s.name, hypot($0.ratio - 100, $0.momentum - 100)) } }
                .sorted { $0.1 > $1.1 }.prefix(8).map(\.0))
        VStack(alignment: .leading, spacing: 6) {
            controls
            Chart {
                RectangleMark(xStart: .value("x", xr.lowerBound), xEnd: .value("x", 100), yStart: .value("y", 100), yEnd: .value("y", yr.upperBound))
                    .foregroundStyle(Color.blue.opacity(0.07))
                RectangleMark(xStart: .value("x", 100), xEnd: .value("x", xr.upperBound), yStart: .value("y", 100), yEnd: .value("y", yr.upperBound))
                    .foregroundStyle(Color.green.opacity(0.08))
                RectangleMark(xStart: .value("x", 100), xEnd: .value("x", xr.upperBound), yStart: .value("y", yr.lowerBound), yEnd: .value("y", 100))
                    .foregroundStyle(Color.yellow.opacity(0.08))
                RectangleMark(xStart: .value("x", xr.lowerBound), xEnd: .value("x", 100), yStart: .value("y", yr.lowerBound), yEnd: .value("y", 100))
                    .foregroundStyle(Color.red.opacity(0.07))
                RuleMark(x: .value("x", 100)).foregroundStyle(Color.secondary.opacity(0.35))
                RuleMark(y: .value("y", 100)).foregroundStyle(Color.secondary.opacity(0.35))

                ForEach(list, id: \.name) { s in
                    if let p = point(s, day) {
                        let q = Quadrant.of(ratio: p.ratio, momentum: p.momentum)
                        let focus = selected.isEmpty || selected.contains(s.name) || hover == s.name
                        if tails || selected.contains(s.name) {
                            ForEach(trail(s, selected.contains(s.name) ? 15 : 6), id: \.day) { t in
                                LineMark(x: .value("RS-Ratio", clamp(t.ratio, xr)), y: .value("RS-Momentum", clamp(t.momentum, yr)),
                                         series: .value("Sector", s.name))
                                    .foregroundStyle(quadrantColor(q).opacity(focus ? (selected.contains(s.name) ? 0.9 : 0.35) : 0.08))
                                    .lineStyle(StrokeStyle(lineWidth: selected.contains(s.name) ? 2 : 1))
                                    .interpolationMethod(.catmullRom)
                            }
                        }
                        PointMark(x: .value("RS-Ratio", clamp(p.ratio, xr)), y: .value("RS-Momentum", clamp(p.momentum, yr)))
                            .foregroundStyle(quadrantColor(q).opacity(focus ? 1 : 0.25))
                            .symbolSize(selected.contains(s.name) || hover == s.name ? 140 : CGFloat(max(30, min(110, s.priced * 3))))
                            .annotation(position: .top, spacing: 2) {
                                if labelled.contains(s.name) || hover == s.name {
                                    Text(s.name).font(.system(size: 10, weight: selected.contains(s.name) ? .bold : .regular))
                                        .padding(.horizontal, 3)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .windowBackgroundColor).opacity(0.75)))
                                }
                            }
                    }
                }
            }
            .chartXScale(domain: xr)
            .chartYScale(domain: yr)
            .chartXAxisLabel("RS-Ratio  (relative strength vs Nifty · 100 = its 50-day norm)")
            .chartYAxisLabel("RS-Momentum")
            .animation(.easeInOut(duration: 0.3), value: index)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc): hover = nearest(loc, proxy: proxy, geo: geo, list: list, xr: xr, yr: yr)
                            case .ended: hover = nil
                            }
                        }
                        .onTapGesture { loc in
                            if let n = nearest(loc, proxy: proxy, geo: geo, list: list, xr: xr, yr: yr) {
                                if selected.contains(n) { selected.remove(n) } else { selected.insert(n) }
                            } else {
                                selected.removeAll()
                            }
                        }
                }
            }
            .overlay(alignment: .topLeading) { corner("Improving", .blue) }
            .overlay(alignment: .topTrailing) { corner("Leading", .green) }
            .overlay(alignment: .bottomTrailing) { corner("Weakening", .orange).padding(.bottom, 34) }
            .overlay(alignment: .bottomLeading) { corner("Lagging", .red).padding(.bottom, 34).padding(.leading, 40) }
            .overlay(alignment: .topTrailing) { hoverCard.padding(.top, 28).padding(.trailing, 8) }

            Text("Press ▶ to watch the last \(days.count) trading days. Hover a dot for its name, click to follow it (click empty space to clear). Sectors usually turn clockwise: Improving → Leading → Weakening → Lagging. Approximation of a relative rotation graph built from Yahoo closes.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onDisappear { playing = false }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { togglePlay() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 16) }
                .help("Play / pause")
            Slider(value: Binding(get: { Double(index) }, set: { dayIndex = Int($0.rounded()); playing = false }),
                   in: 0...Double(max(1, days.count - 1)), step: 1)
                .frame(minWidth: 180)
            Text(HistoryStore.date(fromKey: day)?.formatted(.dateTime.day().month(.abbreviated).year()) ?? day)
                .font(.callout.monospacedDigit().bold()).frame(width: 100, alignment: .leading)
            Divider().frame(height: 16)
            Picker("", selection: $show) { ForEach(Show.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .labelsHidden().frame(width: 160)
            TextField("Find sector", text: $search).textFieldStyle(.roundedBorder).frame(width: 130)
            Stepper("≥ \(minStocks) stocks", value: $minStocks, in: 1...30).fixedSize()
            Toggle("Tails", isOn: $tails).toggleStyle(.checkbox)
            if !selected.isEmpty { Button("Clear \(selected.count)") { selected.removeAll() } }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var hoverCard: some View {
        if let h = hover, let s = report.sectors.first(where: { $0.name == h }), let p = point(s, day) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.caption.bold())
                Text("\(Quadrant.of(ratio: p.ratio, momentum: p.momentum).rawValue) · RS \(String(format: "%.1f", p.ratio)) · Mom \(String(format: "%.1f", p.momentum))")
                    .font(.caption2.monospacedDigit())
                Text("\(s.priced) stocks · score \(Int(s.score)) · #\(s.rank)").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        }
    }

    private func corner(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption.bold()).foregroundStyle(c).padding(6)
    }

    private func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }

    private func nearest(_ loc: CGPoint, proxy: ChartProxy, geo: GeometryProxy, list: [SectorStat],
                         xr: ClosedRange<Double>, yr: ClosedRange<Double>) -> String? {
        let origin = geo[proxy.plotAreaFrame].origin
        var best: (String, CGFloat)?
        for s in list {
            guard let p = point(s, day),
                  let x = proxy.position(forX: clamp(p.ratio, xr)), let y = proxy.position(forY: clamp(p.momentum, yr)) else { continue }
            let d = hypot(x + origin.x - loc.x, y + origin.y - loc.y)
            if d < 14, d < (best?.1 ?? .infinity) { best = (s.name, d) }
        }
        return best?.0
    }

    private func togglePlay() {
        if playing { playing = false; return }
        if index >= days.count - 1 { dayIndex = 0 }
        playing = true
        Task { @MainActor in
            while playing {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard playing else { break }
                if index >= days.count - 1 { playing = false; break }
                dayIndex = index + 1
            }
        }
    }
}
