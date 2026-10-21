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
            for nd in news.days(symbol) {
                out.append(Event(id: "n" + nd.day, day: nd.day, kind: "News", text: nd.label ?? "…",
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
                Toggle("News", isOn: $showNews).toggleStyle(.checkbox).fixedSize()
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

    private var eventTable: some View {
        let list = events
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(list.count) events · click = jump the chart there · double-click news = open the article")
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
        if news.history(s) == nil { news.fetch(symbol: s, company: company, months: months, groqModel: vm.settings.groqModel) }
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
