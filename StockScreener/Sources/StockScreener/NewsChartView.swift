import SwiftUI
import AppKit

/// News & Deals: a TradingView-style candle chart of one stock with every news day marked by a 3–4 word
/// Groq label (blue ●) and NSE bulk / block deals (green B▲ buys, red S▼ sells), plus the list of events.
struct NewsChartView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var news = NewsTimeline.shared
    @ObservedObject private var deals = DealsCenter.shared
    @ObservedObject private var dc = DeliveryCenter.shared
    @StateObject private var lw = LWChartHolder()

    @AppStorage("news.symbol") private var symbol = ""
    @AppStorage("news.months") private var months = 12
    @AppStorage("news.showNews") private var showNews = true
    @AppStorage("news.showDeals") private var showDeals = true
    @AppStorage("news.showDeliv") private var showDeliv = false
    @AppStorage("news.range") private var range = "1Y"
    @AppStorage("deliv.metric") private var metricRaw = DeliveryMetric.value.rawValue
    @AppStorage("deliv.length") private var length = 300
    @State private var search = ""
    @State private var candles: [YahooClient.Candle] = []
    @State private var chartError: String?
    @State private var selected: String?
    @State private var showCodes = false
    @AppStorage("news.minImpact") private var minImpact = 2
    @AppStorage(EventCodes.key) private var codesData = Data()

    struct Event: Identifiable {
        let id: String
        let day: String
        let kind: String          // News / Bulk buy / Block sell …
        let text: String
        let detail: String
        let link: String?
    }

    private var events: [Event] {
        _ = news.revision; _ = deals.revision
        var out: [Event] = []
        if showNews {
            for nd in news.days(symbol) where (nd.impact ?? 0) >= minImpact && nd.label != "Not company news" || minImpact == 0 {
                let code = EventCodes.code(for: nd.category)
                out.append(Event(id: "n" + nd.day, day: nd.day, kind: "News",
                                 text: "\(NewsImpact.dots(nd.impact)) \(code) · \(nd.label ?? "…")" + (nd.impactOn.map { "  → \($0)" } ?? ""),
                                 detail: nd.headlines.prefix(3).map { "\($0.title) (\($0.source))" }.joined(separator: " · "),
                                 link: nd.headlines.first?.link))
            }
        }
        if showDeals {
            for d in deals.bySymbol[symbol.uppercased()] ?? [] {
                out.append(Event(id: "d" + d.id, day: d.day, kind: "\(d.kind) \(d.isBuy ? "buy" : "sell")",
                                 text: String(format: "%@ %.2f Cr", d.isBuy ? "Bought" : "Sold", d.valueCr),
                                 detail: "\(d.client) · \(DeliveryView.short(d.qty)) shares @ \(String(format: "%.2f", d.price))", link: nil))
            }
        }
        return out.sorted { $0.day > $1.day }
    }

    private var company: String? {
        guard let label = vm.labelIndex, let n = vm.companyNameIndex else { return nil }
        let s = symbol.uppercased()
        return vm.table.rows.first { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() == s }?.text(n)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if symbol.isEmpty {
                Text("Search a stock above.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    VStack(spacing: 0) {
                        if let e = chartError { Text("Yahoo: \(e)").font(.caption).foregroundStyle(.orange).padding(4) }
                        if let e = lw.lastError { Text(e).font(.caption2).foregroundStyle(.red) }
                        LWChartView(holder: lw)
                        hoverPanel
                    }
                    .frame(minHeight: 300)
                    eventTable.frame(minHeight: 140, idealHeight: 220)
                }
            }
        }
        .navigationTitle(symbol.isEmpty ? "News & Deals" : "News & Deals — \(symbol)")
        .onAppear {
            deals.update(days: 730)
            if symbol.isEmpty, let c = vm.chartSymbol, !c.isEmpty { symbol = c.uppercased() }
            load()
        }
        .onChange(of: symbol) { _ in load() }
        .onChange(of: news.revision) { _ in push() }
        .onChange(of: deals.revision) { _ in push() }
        .onChange(of: showNews) { _ in push() }
        .onChange(of: showDeals) { _ in push() }
        .onChange(of: showDeliv) { _ in push() }
        .onChange(of: range) { _ in push() }
        .onChange(of: colorScheme) { _ in push() }
        .onChange(of: candles.count) { _ in push() }
        .onChange(of: codesData) { _ in push() }
        .onChange(of: minImpact) { _ in news.touch() }              // redraws this and the delivery charts
        .sheet(isPresented: $showCodes) { EventCodesEditor() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 12, lineSpacing: 6) {
                SymbolField(vm: vm, placeholder: "Stock (e.g. TATAMOTORS)", text: $search, onSubmit: {
                    let t = search.trimmingCharacters(in: .whitespaces).uppercased()
                    if !t.isEmpty { symbol = t; search = "" }
                }).frame(width: 200)
                if !symbol.isEmpty {
                    HStack(spacing: 6) {
                        Text(symbol).font(.title3.bold())
                        if let c = company { Text(c).foregroundStyle(.secondary).lineLimit(1) }
                        if let c = candles.last { Text(String(format: "%.2f", c.close)).font(.headline.monospacedDigit()) }
                    }.fixedSize()
                }
                HStack(spacing: 4) {
                    Button { news.fetch(symbol: symbol, company: company, months: months, groqModel: vm.settings.groqModel) } label: {
                        Label("Get news", systemImage: "newspaper")
                    }
                    .disabled(symbol.isEmpty || news.busy != nil)
                    Picker("", selection: $months) {
                        ForEach([3, 6, 12, 24], id: \.self) { Text("last \($0) months").tag($0) }
                    }
                    .labelsHidden()
                    Menu {
                        Button("Re-fetch all months and re-label") { news.fetch(symbol: symbol, company: company, months: months, groqModel: vm.settings.groqModel, force: true) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
                }.fixedSize()
                Button { deals.update(days: 730, force: true) } label: { Label("Update deals", systemImage: "arrow.down.circle") }
                    .disabled(deals.busy).fixedSize()
                    .help("NSE bulk & block deals for every stock, last 2 years (then only new days)")
                Button { showCodes = true } label: { Label("Event letters…", systemImage: "character.book.closed") }.fixedSize()
                    .help("The dictionary of news events → letters on the chart (Dividend = D, Factory fire = FF …) — edit any time")
                Button { news.reclassify(symbol: symbol, company: company, groqModel: vm.settings.groqModel) } label: { Label("Re-classify", systemImage: "tag") }
                    .disabled(symbol.isEmpty || news.busy != nil).fixedSize()
                    .help("Ask Groq again which event each news day is (use after editing the event list)")
                Toggle("News", isOn: $showNews).toggleStyle(.checkbox).fixedSize()
                HStack(spacing: 4) {
                    Text("Impact ≥").font(.caption)
                    Picker("", selection: $minImpact) { ForEach(0..<4) { Text(NewsImpact.names[$0]).tag($0) } }
                        .labelsHidden().fixedSize()
                }
                .fixedSize()
                .help("Only news that can change the company's own revenue, profit or market position (Groq's 0–3 rating). 0 shows every mention.")
                Toggle("Bulk / block deals", isOn: $showDeals).toggleStyle(.checkbox).fixedSize()
                Toggle("Delivery bars", isOn: $showDeliv).toggleStyle(.checkbox).fixedSize()
                Picker("", selection: $range) { ForEach(["6M", "1Y", "2Y", "All"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button("TradingView") { if !symbol.isEmpty { vm.openChart(symbol, queue: [symbol], openWindow: openWindow) } }.fixedSize()
            }
            .controlSize(.small)
            HStack(spacing: 12) {
                if news.busy != nil || deals.busy { ProgressView().controlSize(.small) }
                if let s = news.status { Text(s).lineLimit(1) }
                Text(deals.status ?? deals.summary).lineLimit(1)
                if vm.settings.groqModel.isEmpty || GroqClient.apiKey.isEmpty {
                    Text("No Groq key / model — labels will be the first words of each headline").foregroundStyle(.orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Under the chart: the full headlines (Google News title — source) of the day under the crosshair.
    private var hoverPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            if lw.hoverLines.isEmpty {
                Text("Move the crosshair over a letter to read that day's news here").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(lw.hoverLines.prefix(6).enumerated()), id: \.offset) { _, l in
                    Text(l).font(.callout).lineLimit(1).truncationMode(.tail).textSelection(.enabled).help(l)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var eventTable: some View {
        let list = events
        return VStack(alignment: .leading, spacing: 0) {
            let all = news.days(symbol).count, shownNews = list.filter { $0.kind == "News" }.count
            Text("\(list.count) events · \(all - shownNews) of \(all) news days hidden below impact \(minImpact) (\(NewsImpact.short[minImpact])) · ●●● = impact on revenue / profit / market position · click = jump the chart there · double-click news = open the article")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
            Table(list, selection: $selected) {
                TableColumn("Day") { e in Text(e.day).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("Type") { e in
                    Text(e.kind).font(.caption.bold())
                        .foregroundStyle(e.kind == "News" ? Color.blue : (e.kind.hasSuffix("buy") ? Color.green : Color.red))
                }.width(min: 70, ideal: 85)
                TableColumn("What") { e in Text(e.text).bold() }.width(min: 120, ideal: 170)
                TableColumn("Details") { e in Text(e.detail).foregroundStyle(.secondary).lineLimit(2).help(e.detail) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let e = list.first(where: { $0.id == id }) {
                    if let l = e.link, let u = URL(string: l) { Button("Open article") { NSWorkspace.shared.open(u) } }
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(e.day) \(e.kind): \(e.text) — \(e.detail)", forType: .string) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let e = list.first(where: { $0.id == id }), let l = e.link, let u = URL(string: l) { NSWorkspace.shared.open(u) }
            }
            .onChange(of: selected) { id in
                guard let id, let e = list.first(where: { $0.id == id }), let w = DeliveryMiniChart.window(around: e.day) else { return }
                lw.setRange(from: w.0, to: w.1)
            }
        }
    }

    private func load() {
        candles = []; chartError = nil
        let s = symbol.uppercased()
        guard !s.isEmpty else { return }
        dc.loadIfNeeded()
        if news.needsUpdate(s) { news.fetch(symbol: s, company: company, months: months, groqModel: vm.settings.groqModel) }
        Task {
            do { let c = try await YahooClient.candles(s, range: "5y"); if symbol.uppercased() == s { candles = c } }
            catch { if symbol.uppercased() == s { chartError = error.localizedDescription } }
        }
        push()
    }

    private func push() {
        let s = symbol.uppercased()
        guard !s.isEmpty else { return }
        var layers: Set<ChartLayer> = [.candles]
        if showDeliv { layers.insert(.deliv) }
        if showNews { layers.insert(.news) }
        if showDeals { layers.insert(.deals) }
        let metric = DeliveryMetric(rawValue: metricRaw) ?? .value
        lw.show(LWChartData.make(symbol: s, series: dc.book.series[s], candles: candles, metric: metric, length: max(2, length),
                                 full: true, onlyRises: true, range: range, dark: colorScheme == .dark, calendar: dc.calendar,
                                 layers: layers, events: LWChartData.eventMarkers(s, layers: layers)))
    }
}


/// Edit the dictionary of news events → letters drawn on the chart.
struct EventCodesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [EventCode] = EventCodes.all

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Event letters").font(.title2.bold())
            Text("Each news day gets one event from this list (Groq picks it from the headlines; without Groq the keywords are used). The letters are what the chart shows. Changes apply to the chart at once; press Re-classify for Groq to re-pick events after adding new ones.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Text("Event").bold().frame(width: 200, alignment: .leading); Text("Letters").bold().frame(width: 70, alignment: .leading); Text("Keywords (comma-separated)").bold(); Spacer() }
                .font(.caption)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($rows) { $r in
                        HStack {
                            TextField("Event", text: $r.name).frame(width: 200)
                            TextField("Letters", text: $r.code).frame(width: 70).font(.body.monospaced())
                            TextField("keywords", text: $r.keywords)
                            Button { rows.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .frame(minHeight: 320)
            HStack {
                Button { rows.insert(EventCode(name: "New event", code: "X", keywords: ""), at: max(0, rows.count - 1)) } label: { Label("Add event", systemImage: "plus") }
                Button("Reset to defaults") { rows = EventCodes.defaults }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    EventCodes.all = rows.map { var r = $0; r.code = r.code.trimmingCharacters(in: .whitespaces).uppercased(); return r }
                        .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.code.isEmpty }
                    NewsTimeline.shared.touch()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }
}

/// One-line strip of a stock's important news (impact ≥ the chosen level), newest first — for the top of the
/// Chart viewer. Hover a chip for the headlines, click to open the article. Fetches news the first time.
struct NewsStrip: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    let symbol: String
    var crossDay: String? = nil          // day under the chart's crosshair
    @ObservedObject private var news = NewsTimeline.shared
    @AppStorage("news.minImpact") private var minImpact = 2
    @AppStorage("news.months") private var months = 12
    @AppStorage("viewer.newsAll") private var showAll = false
    @State private var expanded: String?

    /// The news shown for the crosshair: the latest news on or before that day — it stays until the crosshair
    /// reaches the next news day. Also returns the news before it.
    private func atCross(_ list: [NewsDay]) -> (now: NewsDay, prev: NewsDay?)? {
        guard let c = crossDay else { return nil }
        let before = list.filter { $0.day <= c }.sorted { $0.day > $1.day }       // newest first
        guard let n = before.first else { return nil }
        return (n, before.dropFirst().first)
    }

    /// "21 Oct" (and the year when it isn't this year).
    static func dm(_ day: String) -> String {
        guard let d = DealsCenter.date(day) else { return day }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_IN"); f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.dateFormat = day.prefix(4) == DealsCenter.ymd(Date()).prefix(4) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }

    private var company: String? {
        guard let label = vm.labelIndex, let n = vm.companyNameIndex else { return nil }
        let s = symbol.uppercased()
        return vm.table.rows.first { $0.text(label).trimmingCharacters(in: .whitespaces).uppercased() == s }?.text(n)
    }

    private var items: [NewsDay] {
        _ = news.revision
        return news.days(symbol).filter { ($0.impact ?? 0) >= minImpact && $0.label != "Not company news" }.reversed()
    }

    var body: some View {
        let list = items
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "newspaper").foregroundStyle(.blue).font(.caption)
                if news.busy == symbol.uppercased() {
                    ProgressView().controlSize(.mini)
                    Text(news.status ?? "Fetching news…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if list.isEmpty {
                    Text(news.history(symbol) == nil ? "No news fetched for \(symbol) yet" : "No news with impact ≥ \(NewsImpact.short[minImpact]) for \(symbol)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if showAll {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(list.prefix(60)) { nd in chip(nd) }      // newest first
                        }
                    }
                } else if let hit = atCross(list) {
                    crossLine(hit.now, prev: hit.prev)
                    Spacer(minLength: 0)
                } else {
                    Text(crossDay.map { "No important news up to \(Self.dm($0))" } ?? "Move the crosshair over the chart: the latest news up to that day appears here")
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Button { showAll.toggle(); expanded = nil } label: {
                    Text(showAll ? "Crosshair" : "All news (\(list.count))").font(.caption)
                }
                .controlSize(.mini)
                .help(showAll ? "Back to: news follows the crosshair" : "List every important news item, most recent first")
                Picker("", selection: $minImpact) { ForEach(0..<4) { Text("≥ " + NewsImpact.short[$0]).tag($0) } }
                    .labelsHidden().fixedSize().controlSize(.mini)
                    .help("Show only news that can change the company's revenue, profit or market position (Groq's 0–3 rating)")
                Button { news.fetch(symbol: symbol, company: company, months: months, groqModel: vm.settings.groqModel) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).controlSize(.mini).disabled(news.busy != nil).help("Fetch the latest news")
                Button { UserDefaults.standard.set(symbol.uppercased(), forKey: "news.symbol"); openWindow(id: "newschart") } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless).controlSize(.mini).help("Open News & Deals (chart of all news and bulk deals)")
            }
            if showAll, let d = expanded, let nd = list.first(where: { $0.day == d }) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(nd.headlines.prefix(4).enumerated()), id: \.offset) { _, h in
                        Text("\(nd.day) · \(h.title)" + (h.source.isEmpty ? "" : " — \(h.source)")).font(.caption).lineLimit(1).textSelection(.enabled)
                    }
                }
                .padding(.leading, 22).padding(.top, 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .task(id: symbol) {
            expanded = nil
            // on every visit: only the new news (current month, if last checked over 2 h ago); saved months stay as they are
            if !symbol.isEmpty, news.busy == nil, news.needsUpdate(symbol) {
                news.fetch(symbol: symbol, company: company, months: months, groqModel: vm.settings.groqModel)
            }
        }
    }

    /// Crosshair mode: the day's code, label, impact and its top headline — one line.
    private func crossLine(_ nd: NewsDay, prev: NewsDay?) -> some View {
        let code = EventCodes.code(for: nd.category)
        let h = nd.headlines.first
        let ago: Int? = crossDay.flatMap { c in
            guard let a = DealsCenter.date(nd.day), let b = DealsCenter.date(c) else { return nil }
            return Int((b.timeIntervalSince(a) / 86_400).rounded())
        }
        return HStack(spacing: 6) {
            Text(Self.dm(nd.day)).font(.caption.bold().monospacedDigit())
            if let ago, ago > 0 { Text("(\(ago)d before)").font(.caption2).foregroundStyle(.tertiary) }
            Text(code).font(.caption.bold()).foregroundStyle(.white)
                .padding(.horizontal, 4).background(Color.blue, in: RoundedRectangle(cornerRadius: 3))
            Text(nd.label ?? "").font(.caption.bold())
            Text(NewsImpact.dots(nd.impact)).font(.system(size: 8)).foregroundStyle(.orange)
            if let h {
                Text(h.title + (h.source.isEmpty ? "" : " — \(h.source)")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if nd.headlines.count > 1 { Text("+\(nd.headlines.count - 1)").font(.caption2).foregroundStyle(.tertiary) }
            }
            if let p = prev {
                Divider().frame(height: 12)
                Text("previous: \(Self.dm(p.day)) · \(EventCodes.code(for: p.category)) \(p.label ?? "")")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .help(p.headlines.prefix(4).map { "• \($0.title)" }.joined(separator: "\n"))
            }
        }
        .help(nd.headlines.prefix(6).map { "• \($0.title)" + ($0.source.isEmpty ? "" : " — \($0.source)") }.joined(separator: "\n") + "\n\nClick: open the article")
        .onTapGesture { if let l = h?.link, let u = URL(string: l) { NSWorkspace.shared.open(u) } }
        .transition(.opacity)
    }

    private func chip(_ nd: NewsDay) -> some View {
        let code = EventCodes.code(for: nd.category)
        return Button {
            if expanded == nd.day, let l = nd.headlines.first?.link, let u = URL(string: l) { NSWorkspace.shared.open(u) }
            else { expanded = nd.day }
        } label: {
            HStack(spacing: 4) {
                Text(String(nd.day.dropFirst(5))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(code).font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 4).background(Color.blue, in: RoundedRectangle(cornerRadius: 3))
                Text(nd.label ?? "").font(.caption).lineLimit(1)
                Text(NewsImpact.dots(nd.impact)).font(.system(size: 7)).foregroundStyle(.orange)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(expanded == nd.day ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(nd.headlines.prefix(4).map { "• \($0.title)" + ($0.source.isEmpty ? "" : " — \($0.source)") }.joined(separator: "\n")
              + "\n\nClick: show the headlines · click again: open the article")
    }
}
