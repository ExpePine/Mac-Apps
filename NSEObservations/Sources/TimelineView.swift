import SwiftUI
import Charts
import AppKit

// MARK: - Options

enum TimelineGrouping: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month"
    var id: String { rawValue }

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    func title(for start: Date) -> String {
        switch self {
        case .day: return TimelineFmt.dayHeader.string(from: start)
        case .week: return "Week of \(TimelineFmt.weekHeader.string(from: start))"
        case .month: return TimelineFmt.monthHeader.string(from: start)
        }
    }

    func shortTitle(for start: Date) -> String {
        switch self {
        case .day: return TimelineFmt.short.string(from: start)
        case .week: return TimelineFmt.short.string(from: start)
        case .month: return TimelineFmt.monthShort.string(from: start)
        }
    }
}

enum OutcomeHorizon: String, CaseIterable, Identifiable {
    case s5 = "After 5 sessions", s20 = "After 20 sessions", now = "Up to today"
    var id: String { rawValue }

    func move(_ o: ObservationOutcome?) -> Double? {
        guard let o else { return nil }
        switch self {
        case .s5: return o.after5
        case .s20: return o.after20
        case .now: return o.sinceThen
        }
    }
}

private enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All", bullish = "Bullish", bearish = "Bearish", neutral = "Neutral", trades = "Trades",
         shots = "Screenshots", news = "News", scripts = "Pine Scripts"
    var id: String { rawValue }
}

private enum TimelineFmt {
    static func make(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.dateFormat = f
        d.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return d
    }
    static let dayHeader = make("EEEE, d MMMM yyyy")
    static let weekHeader = make("d MMM yyyy")
    static let monthHeader = make("MMMM yyyy")
    static let monthShort = make("MMM yy")
    static let short = make("d MMM")
    static let time = make("HH:mm")
    static let dayInMonth = make("EEE d")
}

// MARK: - Entries

enum Verdict {
    case worked, failed, flat, tooEarly, noData, info

    /// "Worked" = moved the way you called by more than 0.5%.
    static func judge(expectsUp: Bool?, move: Double?, hasPrices: Bool) -> Verdict {
        guard let up = expectsUp else { return .info }   // neutral notes, news and scripts aren't scored
        guard hasPrices else { return .noData }
        guard let move else { return .tooEarly }
        let inFavour = up ? move : -move
        if inFavour > 0.5 { return .worked }
        if inFavour < -0.5 { return .failed }
        return .flat
    }

    var label: String {
        switch self {
        case .worked: return "Worked"
        case .failed: return "Didn't work"
        case .flat: return "Flat"
        case .tooEarly: return "Too early"
        case .noData: return "No price data"
        case .info: return ""
        }
    }

    var systemImage: String {
        switch self {
        case .worked: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .flat: return "equal.circle.fill"
        case .tooEarly: return "hourglass"
        case .noData: return "questionmark.circle"
        case .info: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .worked: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

struct TimelineEntry: Identifiable {
    enum Kind { case observation(Observation), trade(Trade), news(NewsItem), script(PineScript, ScriptVersion), shot(ChartShot) }
    let id: UUID
    let date: Date
    let symbol: TrackedSymbol?
    let kind: Kind

    var heading: String {
        if let symbol { return symbol.ticker }
        switch kind {
        case .news: return "Market"
        case .script(let s, _): return s.name
        default: return ""
        }
    }

    /// Where clicking the row goes.
    var target: SidebarItem {
        if case .script = kind { return .scripts }
        if let symbol { return .symbol(symbol.id) }
        return .news
    }
    /// true = you expected a rise (bullish note / buy), false = a fall (bearish note / sell), nil = neutral.
    let expectsUp: Bool?
    let outcome: ObservationOutcome?
    let hasPrices: Bool

    func move(_ h: OutcomeHorizon) -> Double? { h.move(outcome) }
    func verdict(_ h: OutcomeHorizon) -> Verdict { Verdict.judge(expectsUp: expectsUp, move: move(h), hasPrices: hasPrices) }
    /// Move in the direction you called (positive = good for you). Nil for neutral notes.
    func moveInFavour(_ h: OutcomeHorizon) -> Double? {
        guard let up = expectsUp, let m = move(h) else { return nil }
        return up ? m : -m
    }
}

private struct PeriodPoint: Identifiable {
    let id: Date
    let label: String
    let value: Double
}

private struct PeriodGroup: Identifiable {
    let id: Date          // period start
    let title: String
    let short: String
    let entries: [TimelineEntry]

    func stats(_ h: OutcomeHorizon) -> (worked: Int, judged: Int, avgFavour: Double?) {
        var worked = 0, judged = 0
        var favours: [Double] = []
        for e in entries {
            switch e.verdict(h) {
            case .worked: worked += 1; judged += 1
            case .failed, .flat: judged += 1
            default: break
            }
            if let f = e.moveInFavour(h) { favours.append(f) }
        }
        let avg = favours.isEmpty ? nil : favours.reduce(0, +) / Double(favours.count)
        return (worked, judged, avg)
    }
}

// MARK: - View

struct TimelineView: View {
    @EnvironmentObject private var store: Store
    var open: (SidebarItem) -> Void

    @State private var grouping: TimelineGrouping = .month
    @State private var horizon: OutcomeHorizon = .s20
    @State private var filter: KindFilter = .all
    @State private var series: [String: QuoteSeries] = [:]
    @State private var loading = false
    @State private var collapsed: Set<Date> = []

    private var calendar: Calendar {
        var c = Calendar.ist
        c.firstWeekday = 2   // weeks start on Monday
        return c
    }

    private var entries: [TimelineEntry] {
        var out: [TimelineEntry] = []
        for s in store.symbols {
            let candles = series[s.yahooSymbol]?.candles
            let has = !(candles ?? []).isEmpty
            if [.all, .bullish, .bearish, .neutral].contains(filter) {
                for o in store.observations(for: s.id) {
                    switch filter {
                    case .bullish where o.sentiment != .bullish: continue
                    case .bearish where o.sentiment != .bearish: continue
                    case .neutral where o.sentiment != .neutral: continue
                    default: break
                    }
                    let up: Bool? = o.sentiment == .bullish ? true : (o.sentiment == .bearish ? false : nil)
                    out.append(TimelineEntry(id: o.id, date: o.date, symbol: s, kind: .observation(o), expectsUp: up,
                                             outcome: candles.flatMap { ObservationOutcome.compute(for: o.date, candles: $0) },
                                             hasPrices: has))
                }
            }
            if filter == .all || filter == .trades {
                for t in store.trades(for: s.id) {
                    out.append(TimelineEntry(id: t.id, date: t.date, symbol: s, kind: .trade(t), expectsUp: t.side == .buy,
                                             outcome: candles.flatMap { ObservationOutcome.compute(for: t.date, candles: $0) },
                                             hasPrices: has))
                }
            }
        }
        if filter == .all || filter == .news {
            for n in store.data.news {
                let s = n.symbolID.flatMap { store.symbol($0) }
                let candles = s.flatMap { series[$0.yahooSymbol]?.candles }
                out.append(TimelineEntry(id: n.id, date: n.date, symbol: s, kind: .news(n), expectsUp: nil,
                                         outcome: candles.flatMap { ObservationOutcome.compute(for: n.date, candles: $0) },
                                         hasPrices: candles != nil))
            }
        }
        if filter == .all || filter == .shots {
            for sh in store.data.chartShots {
                guard let s = store.symbol(sh.symbolID) else { continue }
                let candles = series[s.yahooSymbol]?.candles
                out.append(TimelineEntry(id: sh.id, date: sh.date, symbol: s, kind: .shot(sh), expectsUp: nil,
                                         outcome: candles.flatMap { ObservationOutcome.compute(for: sh.date, candles: $0) },
                                         hasPrices: candles != nil))
            }
        }
        if filter == .all || filter == .scripts {
            for sc in store.data.scripts {
                for v in sc.versions {
                    out.append(TimelineEntry(id: v.id, date: v.date, symbol: nil, kind: .script(sc, v), expectsUp: nil,
                                             outcome: nil, hasPrices: false))
                }
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    private func groups(_ entries: [TimelineEntry]) -> [PeriodGroup] {
        let cal = calendar
        let byStart = Dictionary(grouping: entries) { e in
            cal.dateInterval(of: grouping.component, for: e.date)?.start ?? cal.startOfDay(for: e.date)
        }
        return byStart.keys.sorted(by: >).map { start in
            PeriodGroup(id: start, title: grouping.title(for: start), short: grouping.shortTitle(for: start),
                        entries: byStart[start] ?? [])
        }
    }

    var body: some View {
        let all = entries
        let periods = groups(all)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timeline")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Every note, trade, news summary and Pine Script version, by date — and whether the price moved the way you called.")
                        .foregroundStyle(.secondary)
                }

                controls

                if all.isEmpty {
                    Card {
                        Text(store.data.observations.isEmpty
                             ? "No observations yet. Add a symbol and write your first note — it will appear here with what the price did next."
                             : "Nothing matches this filter.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    summary(all)
                    if periods.count > 1 { periodChart(periods) }
                    ForEach(periods) { g in periodSection(g) }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Timeline")
        .toolbar {
            ToolbarItem {
                Button { Task { await loadPrices(force: true) } } label: {
                    Label("Refresh Prices", systemImage: "arrow.clockwise")
                }
                .help("Refresh prices from Yahoo Finance")
                .disabled(loading)
            }
        }
        .task { await loadPrices(force: false) }
    }

    // MARK: Pieces

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Group by", selection: $grouping) {
                ForEach(TimelineGrouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Picker("Judge", selection: $horizon) {
                ForEach(OutcomeHorizon.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 230)

            Picker("Show", selection: $filter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 150)

            if loading {
                ProgressView().controlSize(.small)
                Text("Loading prices…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func summary(_ all: [TimelineEntry]) -> some View {
        let judged = all.filter { [.worked, .failed, .flat].contains($0.verdict(horizon)) }
        let worked = judged.filter { $0.verdict(horizon) == .worked }.count
        let early = all.filter { $0.verdict(horizon) == .tooEarly }.count
        let favours = all.compactMap { $0.moveInFavour(horizon) }
        let avg = favours.isEmpty ? nil : favours.reduce(0, +) / Double(favours.count)
        let best = all.filter { $0.moveInFavour(horizon) != nil }.max { ($0.moveInFavour(horizon) ?? 0) < ($1.moveInFavour(horizon) ?? 0) }
        let worst = all.filter { $0.moveInFavour(horizon) != nil }.min { ($0.moveInFavour(horizon) ?? 0) < ($1.moveInFavour(horizon) ?? 0) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatTile(title: "Calls that worked",
                         value: judged.isEmpty ? "—" : "\(worked) of \(judged.count)",
                         detail: judged.isEmpty ? "Needs bullish/bearish notes with price data"
                                                : "\(Int((Double(worked) / Double(judged.count) * 100).rounded()))% · \(horizon.rawValue.lowercased())",
                         tint: judged.isEmpty ? .primary : (Double(worked) / Double(judged.count) >= 0.5 ? .green : .red))
                StatTile(title: "Avg move your way", value: Fmt.pct(avg),
                         detail: "\(favours.count) directional entr\(favours.count == 1 ? "y" : "ies")",
                         tint: avg?.changeColor ?? .primary)
                StatTile(title: "Best call", value: Fmt.pct(best?.moveInFavour(horizon)),
                         detail: best.map { "\($0.heading) · \(Fmt.day.string(from: $0.date))" },
                         tint: .green)
                StatTile(title: "Worst call", value: Fmt.pct(worst?.moveInFavour(horizon)),
                         detail: worst.map { "\($0.heading) · \(Fmt.day.string(from: $0.date))" },
                         tint: .red)
            }
            Text("“Worked” = price moved more than 0.5% in the direction of your bullish/bearish note or trade (buy = up, sell = down), measured from that day's close. Neutral notes show the move but aren't scored.\(early > 0 ? " \(early) entr\(early == 1 ? "y is" : "ies are") too recent for this horizon." : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func periodChart(_ groups: [PeriodGroup]) -> some View {
        let points: [PeriodPoint] = groups.prefix(18).reversed().compactMap { g in
            guard let v = g.stats(horizon).avgFavour else { return nil }
            return PeriodPoint(id: g.id, label: g.short, value: v)
        }
        return Group {
            if points.count > 1 {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Average move in your direction, by \(grouping.rawValue.lowercased())")
                            .font(.headline)
                        Chart(points) { p in
                            BarMark(x: .value("Period", p.label), y: .value("Move %", p.value))
                                .foregroundStyle(p.value >= 0 ? Color.green.gradient : Color.red.gradient)
                                .cornerRadius(3)
                            RuleMark(y: .value("Zero", 0))
                                .foregroundStyle(Color.secondary.opacity(0.4))
                        }
                        .chartYAxis {
                            AxisMarks { v in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let d = v.as(Double.self) { Text("\(Int(d))%") }
                                }
                            }
                        }
                        .frame(height: 170)
                    }
                }
            }
        }
    }

    private func periodSection(_ g: PeriodGroup) -> some View {
        let st = g.stats(horizon)
        let isCollapsed = collapsed.contains(g.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isCollapsed { collapsed.remove(g.id) } else { collapsed.insert(g.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                    Text(g.title).font(.title3.weight(.semibold))
                    Text("\(g.entries.count) entr\(g.entries.count == 1 ? "y" : "ies")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if st.judged > 0 {
                        Text("\(st.worked)/\(st.judged) worked")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Double(st.worked) / Double(st.judged) >= 0.5 ? .green : .red)
                    }
                    if let a = st.avgFavour {
                        Text("avg \(Fmt.pct(a))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(a.changeColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                Card {
                    VStack(spacing: 0) {
                        ForEach(g.entries) { e in
                            TimelineRow(entry: e, horizon: horizon, showDay: grouping != .day) {
                                if case .shot(let sh) = e.kind { store.focusShotID = sh.id }
                                open(e.target)
                            }
                            if e.id != g.entries.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func loadPrices(force: Bool) async {
        let symbols = store.symbols.filter { s in
            store.observationCount(for: s.id) > 0 || !store.trades(for: s.id).isEmpty || store.data.news.contains { $0.symbolID == s.id }
                || store.data.chartShots.contains { $0.symbolID == s.id }
        }
        guard !symbols.isEmpty else { return }
        loading = true
        defer { loading = false }
        if force {
            // Refresh each symbol's cache, then rebuild.
            for s in symbols {
                let earliest = (store.observations(for: s.id).map(\.date) + store.trades(for: s.id).map(\.date)).min() ?? Date()
                _ = try? await MarketDataService.shared.series(for: s.yahooSymbol,
                                                               from: earliest.addingTimeInterval(-30 * 86_400), force: true)
            }
        }
        series = await loadSeries(for: symbols, store: store)
    }
}

private struct TimelineRow: View {
    @EnvironmentObject private var store: Store
    let entry: TimelineEntry
    let horizon: OutcomeHorizon
    let showDay: Bool
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        let verdict = entry.verdict(horizon)
        let move = entry.move(horizon)
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .trailing, spacing: 1) {
                    if showDay {
                        Text(TimelineFmt.dayInMonth.string(from: entry.date))
                            .font(.caption.weight(.semibold))
                    }
                    Text(TimelineFmt.time.string(from: entry.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 52, alignment: .trailing)

                if let img = shotThumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.primary.opacity(0.1)))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(entry.heading)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                        badge
                        if let name = entry.symbol?.displayName, !name.isEmpty {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(detailText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.pct(move))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(move?.changeColor ?? .secondary)
                    if verdict != .info {
                        Label(verdict.label, systemImage: verdict.systemImage)
                            .font(.caption)
                            .foregroundStyle(verdict.color)
                    }
                    if let oc = entry.outcome {
                        Text("from \(Fmt.rupees(oc.referenceClose))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minWidth: 110, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(hovering ? Color.primary.opacity(0.04) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(entry.heading)")
    }

    private var shotThumbnail: NSImage? {
        if case .shot(let sh) = entry.kind { return store.thumbnail(sh.imageFile, maxPixel: 220) }
        return nil
    }

    private var imageCount: Int {
        if case .observation(let o) = entry.kind { return o.imageFiles.count }
        return 0
    }

    private var detailText: String {
        switch entry.kind {
        case .observation(let o):
            return o.text.replacingOccurrences(of: "\n", with: " ")
        case .trade(let t):
            return "\(t.side.title) \(AIContext.formatQty(t.quantity)) @ \(Fmt.rupees(t.price))\(t.note.isEmpty ? "" : " — \(t.note)")"
        case .news(let n):
            return n.title + (n.source.isEmpty ? "" : " — \(n.source)")
        case .script(_, let v):
            let delta = v.linesAdded.map { a in " (+\(a) / −\(v.linesRemoved ?? 0) lines)" } ?? ""
            return (v.note.isEmpty ? "New version" : v.note) + delta
        case .shot(let sh):
            let labels = sh.annotations.map(\.text).filter { !$0.isEmpty }.joined(separator: " · ")
            let text = [sh.caption.replacingOccurrences(of: "\n", with: " "), labels].filter { !$0.isEmpty }.joined(separator: " — ")
            return text.isEmpty ? "Chart screenshot" : text
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch entry.kind {
        case .observation(let o):
            Label(o.sentiment.title, systemImage: o.sentiment.systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(o.sentiment.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(o.sentiment.color.opacity(0.12), in: Capsule())
            Text(o.timeframe.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .trade(let t):
            Text(t.side.title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(t.side.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(t.side.color.opacity(0.12), in: Capsule())
        case .news(let n):
            Label("News", systemImage: "newspaper")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.indigo)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.indigo.opacity(0.12), in: Capsule())
            NewsTagChips(tags: store.tags(for: n))
        case .shot(let sh):
            Label("Chart", systemImage: "photo")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12), in: Capsule())
            Text(sh.timeframe.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .script(_, let v):
            Label("Pine v\(v.number)", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())
        }
        if imageCount > 0 {
            Label("\(imageCount)", systemImage: "photo")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
