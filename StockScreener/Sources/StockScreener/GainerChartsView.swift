import SwiftUI
import WebKit

/// Gainer Charts: today's top gainers (≥ 5% on the day) or monthly gainers (≥ 30% over a month), shown one
/// chart at a time — Chart 1 of stock #1, Chart 2 of stock #1, Chart 1 of stock #2, … — with the stock's
/// NSE delivery chart underneath.
struct GainerChartsView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var pool = ReelPool()
    @StateObject private var lw = LWChartHolder()

    @AppStorage("gc.mode") private var mode = GCMode.daily.rawValue
    @AppStorage("gc.dailyMin") private var dailyMin = 5.0
    @AppStorage("gc.monthlyMin") private var monthlyMin = 30.0
    @AppStorage("gc.monthWindow") private var monthWindow = GCMonthWindow.rolling.rawValue
    @AppStorage("gc.sec1") private var sec1 = 4.0
    @AppStorage("gc.sec2") private var sec2 = 4.0
    @AppStorage("gc.delivery") private var showDelivery = true
    @AppStorage("gc.sync") private var sync = true
    @AppStorage("gc.scope") private var scope = "Sheet stocks"

    @State private var pos = 0                 // step: stock = pos / perStock, chart = pos % perStock
    @State private var playing = false
    @State private var lastStep = Date()
    @State private var syncNote: String?
    @State private var lastTV = ""
    @State private var syncFails = 0
    @State private var pushedToTVAt = Date.distantPast

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private let syncTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    struct Item { let symbol: String; let change: Double; let row: SheetRow? }

    private var gcMode: GCMode { GCMode(rawValue: mode) ?? .daily }
    private var perStock: Int { vm.chartCount >= 2 ? 2 : 1 }
    private var day: String { vm.currentGainerDay }

    // MARK: Lists

    private var items: [Item] {
        guard let label = vm.labelIndex else { return [] }
        func sym(_ r: SheetRow) -> String { r.text(label).trimmingCharacters(in: .whitespaces).uppercased() }
        let rows = scope == "My Filter" ? vm.filterRows : vm.table.rows
        var out: [Item] = []
        switch gcMode {
        case .daily:
            let allowed = Set(rows.map(sym))
            for g in vm.yahooGainers(on: day, min: dailyMin) where allowed.contains(g.symbol) {
                out.append(Item(symbol: g.symbol, change: g.change, row: g.row))
            }
        case .monthly:
            let w = GCMonthWindow(rawValue: monthWindow) ?? .rolling
            for r in rows {
                guard let s = vm.priceBook.series(for: sym(r)), let c = Self.monthChange(s, day: day, window: w), c >= monthlyMin else { continue }
                out.append(Item(symbol: sym(r), change: c, row: r))
            }
        }
        var seen = Set<String>()
        return out.filter { !$0.symbol.isEmpty && seen.insert($0.symbol).inserted }.sorted { $0.change > $1.change }
    }

    /// % change over the last 21 trading days, or since the previous month's last close (month to date).
    static func monthChange(_ s: PriceSeries, day: String, window: GCMonthWindow) -> Double? {
        guard let i = s.index(onOrBefore: day), s.days[i] == day else { return nil }
        switch window {
        case .rolling: return s.change(over: 21, endingOn: day)
        case .calendar:
            let start = String(day.prefix(7)) + "-01"
            guard var b = s.index(onOrBefore: start) else { return nil }
            if s.days[b] >= start { b -= 1 }                   // the 1st itself was a trading day: use the bar before it
            guard b >= 0, s.closes[b] > 0 else { return nil }
            return (s.closes[i] / s.closes[b] - 1) * 100
        }
    }

    // MARK: Body

    var body: some View {
        let list = items
        let total = list.count * perStock
        let p = min(pos, max(0, total - 1))
        let cur = list.isEmpty ? nil : list[p / perStock]
        let chart = p % perStock
        VStack(spacing: 0) {
            topBar(count: list.count)
            Divider()
            if let cur {
                infoBar(cur, rank: p / perStock, count: list.count, chart: chart)
                Divider()
                VSplitView {
                    chartPane(cur, chart).frame(minHeight: 260)
                    if showDelivery {
                        DeliveryMiniChart(symbol: cur.symbol, lw: lw, syncNote: sync ? syncNote : nil, focus: day)
                            .frame(minHeight: 110, idealHeight: 220)
                    }
                }
                Divider()
                strip(list, current: p / perStock, chart: chart)
                controls(total: total, p: p)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Daily Gainers…") { openWindow(id: "gainers") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(cur.map { "Gainer Charts — \($0.symbol) · Chart \(chart + 1)" } ?? "Gainer Charts")
        .onAppear { vm.refreshChartLinksIfStale(); restart() }
        .task { await LiveQuotes.shared.keepLive(vm) }
        .onChange(of: mode) { _ in restart() }
        .onChange(of: dailyMin) { _ in restart() }
        .onChange(of: monthlyMin) { _ in restart() }
        .onChange(of: monthWindow) { _ in restart() }
        .onChange(of: scope) { _ in restart() }
        .onChange(of: vm.gainersDay) { _ in restart() }
        .onReceive(timer) { _ in
            guard playing else { return }
            let wait = chart == 0 ? sec1 : sec2
            guard Date().timeIntervalSince(lastStep) >= wait else { return }
            if p + 1 < total { go(p + 1, list) } else { playing = false }
        }
        .onReceive(syncTimer) { _ in pollTV(cur, chart) }
        .onAppear {
            lw.onUserRange = { from, to in
                guard sync, let f = TVRange.unix(from), let t = TVRange.unix(to), let web = currentWeb() else { return }
                pushedToTVAt = Date()
                TVRange.run(web, TVRange.setBody(from: f, to: t + 86_399)) { _ in }
            }
        }
        .background {
            Group {
                Button("") { go(p - 1, list) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { go(p + 1, list) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { go((p / perStock - 1) * perStock, list) }.keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("") { go((p / perStock + 1) * perStock, list) }.keyboardShortcut(.rightArrow, modifiers: .shift)
                Button("") { playing.toggle(); lastStep = Date() }.keyboardShortcut("p", modifiers: .command)
            }
            .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var emptyText: String {
        if vm.priceBook.series.isEmpty { return "No Yahoo prices yet — fetch them in Daily Gainers first." }
        switch gcMode {
        case .daily: return "No stock up ≥ \(CombiEngine.fmt(dailyMin))% on \(day)."
        case .monthly: return "No stock up ≥ \(CombiEngine.fmt(monthlyMin))% (\(monthWindow)) up to \(day)."
        }
    }

    // MARK: Bars

    private func topBar(count: Int) -> some View {
        FlowLayout(spacing: 12, lineSpacing: 6) {
            Picker("", selection: $mode) { ForEach(GCMode.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack(spacing: 4) {
                Text("≥").font(.caption)
                if gcMode == .daily {
                    TextField("", value: $dailyMin, format: .number).frame(width: 40).multilineTextAlignment(.trailing)
                    Text("% on the day").font(.caption)
                } else {
                    TextField("", value: $monthlyMin, format: .number).frame(width: 40).multilineTextAlignment(.trailing)
                    Text("% over").font(.caption)
                    Picker("", selection: $monthWindow) { ForEach(GCMonthWindow.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                        .labelsHidden()
                        .help("Last 21 trading days (rolling month) or month to date (since the previous month's last close)")
                }
            }.fixedSize()
            HStack(spacing: 4) {
                Text(gcMode == .daily ? "Day" : "Ending").font(.caption)
                Picker("", selection: Binding(get: { vm.currentGainerDay }, set: { vm.gainersDay = $0 })) {
                    ForEach(vm.gainerDays, id: \.self) { d in Text(d).tag(d) }
                    if !vm.gainerDays.contains(vm.currentGainerDay) { Text(vm.currentGainerDay).tag(vm.currentGainerDay) }
                }
                .labelsHidden()
            }.fixedSize()
            Picker("", selection: $scope) { ForEach(["Sheet stocks", "My Filter"], id: \.self) { Text($0).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            Text("\(count) stock\(count == 1 ? "" : "s") · \(count * perStock) charts").font(.caption.bold()).fixedSize()
            Toggle("Delivery chart", isOn: $showDelivery).toggleStyle(.checkbox).fixedSize()
            Toggle("🔗 Sync dates", isOn: $sync).toggleStyle(.checkbox).fixedSize()
                .help("Keep the delivery chart on the same dates as the TradingView chart (and back)")
            Menu {
                Button("Sign in — Chart 1 (\(TVAccounts.name(TVAccounts.account(forChart: 0))))") { pool.signIn(slot: 0) }
                Button("Sign in — Chart 2 (\(TVAccounts.name(TVAccounts.account(forChart: 1))))") { pool.signIn(slot: 1) }
                Divider()
                Button("Reload these charts") { pool.reloadAll() }
                Button("Chart settings… (Chart viewer)") { openWindow(id: "chart") }
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func infoBar(_ it: Item, rank: Int, count: Int, chart: Int) -> some View {
        HStack(spacing: 10) {
            Text("#\(rank + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            Text(it.symbol).font(.title3.bold())
            Text(String(format: "%+.1f%%", it.change)).font(.headline.monospacedDigit()).foregroundStyle(.green)
            if let r = it.row, let n = vm.companyNameIndex { Text(r.text(n)).foregroundStyle(.secondary).lineLimit(1) }
            if let r = it.row, let s = vm.sectorColumnIndex { Text(r.text(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if perStock == 2 {
                HStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { c in
                        Text("Chart \(c + 1)").font(.caption.bold())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(c == chart ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.1), in: Capsule())
                            .onTapGesture { go(rank * perStock + c, items) }
                    }
                }
            }
            Button { vm.openChart(it.symbol, queue: items.map(\.symbol), goTo: day, openWindow: openWindow) } label: { Label("Chart viewer", systemImage: "arrow.up.forward.app") }
            Text("\(rank + 1) / \(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func chartPane(_ it: Item, _ c: Int) -> some View {
        Group {
            if let u = vm.chartURL(it.symbol, column: min(c, vm.chartCount - 1)) {
                ReelWebView(web: pool.view(for: u, slot: c, goTo: day))
                    .overlay(alignment: .topTrailing) { zoomBar(c) }
            } else {
                Text("No chart link for \(it.symbol)").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @State private var zoomTick = 0
    private func zoomBar(_ c: Int) -> some View {
        _ = zoomTick
        let steps = ReelPool.zoomSteps(c)
        return HStack(spacing: 4) {
            Text("Chart \(c + 1)").font(.caption2.bold())
            Divider().frame(height: 12)
            Button { pool.nudge(slot: c, by: -1); zoomTick += 1 } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Show more bars — remembered for every Chart \(c + 1) (shared with Chart Reel)")
            Text(steps == 0 ? "0" : String(format: "%+d", steps)).font(.caption2.monospacedDigit()).frame(minWidth: 18)
            Button { pool.nudge(slot: c, by: 1); zoomTick += 1 } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Show fewer, wider bars — remembered for every Chart \(c + 1)")
            Button { pool.resetZoom(slot: c); zoomTick += 1 } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Back to the layout's own zoom")
            Divider().frame(height: 12)
            Button { pool.signIn(slot: c) } label: { Image(systemName: "person.crop.circle") }
                .help("Sign in to TradingView — \(TVAccounts.name(TVAccounts.account(forChart: c)))")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .padding(6).opacity(0.92)
    }

    private func strip(_ list: [Item], current: Int, chart: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, it in
                        Button { go(i * perStock, list) } label: {
                            VStack(spacing: 1) {
                                Text(it.symbol).font(.caption.bold()).lineLimit(1)
                                HStack(spacing: 3) {
                                    Text(String(format: "%+.1f%%", it.change)).font(.caption2.monospacedDigit())
                                    if i == current && perStock == 2 { Text(chart == 0 ? "①" : "②").font(.caption2) }
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(i == current ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain).id(i)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .frame(height: 40)
            .onChange(of: current) { i in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: .center) } }
        }
    }

    private func controls(total: Int, p: Int) -> some View {
        HStack(spacing: 8) {
            Button { go(p - 1, items) } label: { Image(systemName: "chevron.left") }.disabled(p == 0).help("Previous chart (←)")
            Button { playing.toggle(); lastStep = Date() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }.help("Autoplay (⌘P)")
            Text("Chart 1").font(.caption)
            Picker("", selection: $sec1) { ForEach(ChartReelView.speeds, id: \.self) { Text("\(CombiEngine.fmt($0)) s").tag($0) } }
                .labelsHidden().fixedSize().help("Seconds on Chart 1")
            if perStock == 2 {
                Text("→ Chart 2").font(.caption)
                Picker("", selection: $sec2) { ForEach(ChartReelView.speeds, id: \.self) { Text("\(CombiEngine.fmt($0)) s").tag($0) } }
                    .labelsHidden().fixedSize().help("Then seconds on Chart 2, then the next stock")
            }
            Slider(value: Binding(get: { Double(p) }, set: { go(Int($0.rounded()), items) }), in: 0...Double(max(1, total - 1)), step: 1)
                .disabled(total < 2)
            Button { go(p + 1, items) } label: { Image(systemName: "chevron.right") }.disabled(p >= total - 1).help("Next chart (→)")
            Text("⇧← ⇧→ previous / next stock").font(.caption2).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: Stepping

    private func restart() { pos = 0; lastTV = ""; syncFails = 0; preload(0, items) }

    private func go(_ i: Int, _ list: [Item]) {
        let total = list.count * perStock
        guard total > 0 else { return }
        let n = max(0, min(total - 1, i))
        if n / perStock != pos / perStock { lastTV = ""; syncFails = 0 }
        pos = n
        lastStep = Date()
        preload(n, list)
    }

    /// Keeps this stock's and the next two stocks' charts loading in the background.
    private func preload(_ p: Int, _ list: [Item]) {
        let s = p / perStock
        var urls: [(URL, Int, String?)] = []
        for j in [s, s + 1, s + 2, s - 1] where list.indices.contains(j) {
            for c in 0..<perStock { if let u = vm.chartURL(list[j].symbol, column: min(c, vm.chartCount - 1)) { urls.append((u, c, day)) } }
        }
        pool.preload(urls, keep: perStock * 4)
    }

    private func currentWeb() -> WKWebView? {
        let list = items
        guard !list.isEmpty else { return nil }
        let p = min(pos, list.count * perStock - 1)
        let c = p % perStock
        return vm.chartURL(list[p / perStock].symbol, column: min(c, vm.chartCount - 1)).map { pool.view(for: $0, slot: c, goTo: day) }
    }

    /// TradingView → delivery chart: follow the visible dates of the chart on screen.
    private func pollTV(_ cur: Item?, _ chart: Int) {
        guard sync, showDelivery, cur != nil, Date().timeIntervalSince(pushedToTVAt) > 0.8, syncFails < 25,
              let web = currentWeb(), !web.isLoading else { return }
        TVRange.run(web, TVRange.getBody) { r in
            let parts = r.split(separator: ",").compactMap { Int($0) }
            guard parts.count >= 2 else {
                syncFails += 1
                syncNote = syncFails >= 25 ? "Sync: TradingView doesn't expose its chart here" : "Sync: waiting for TradingView…"
                return
            }
            syncFails = 0
            syncNote = "🔗 synced"
            guard r != lastTV else { return }
            lastTV = r
            _ = lw.follow(tvResult: r)
        }
    }
}

enum GCMode: String, CaseIterable, Identifiable {
    case daily = "Daily gainers", monthly = "Monthly gainers"
    var id: String { rawValue }
}

enum GCMonthWindow: String, CaseIterable, Identifiable {
    case rolling = "last 21 trading days", calendar = "this calendar month"
    var id: String { rawValue }
}
