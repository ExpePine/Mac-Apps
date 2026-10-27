import SwiftUI

/// Every window of the app, grouped by what it is for. Used by the toolbar "Open" menu, the Tools menu
/// and the Settings hub so the grouping is the same everywhere.
struct AppWindow: Identifiable {
    let title: String
    let id: String
    let icon: String
    let shortcut: String
    let note: String
}

struct AppWindowGroup: Identifiable {
    let name: String
    let icon: String
    let windows: [AppWindow]
    var id: String { name }
}

enum AppWindows {
    static let groups: [AppWindowGroup] = [
        AppWindowGroup(name: "Data", icon: "tablecells", windows: [
            AppWindow(title: "Data Import", id: "data", icon: "tablecells", shortcut: "", note: "the sheet as imported"),
            AppWindow(title: "Filter", id: "filter", icon: "line.3.horizontal.decrease.circle", shortcut: "⇧⌘1", note: "your conditions and colours"),
            AppWindow(title: "Changes", id: "changes", icon: "rectangle.grid.2x2", shortcut: "⇧⌘8", note: "what changed since yesterday"),
            AppWindow(title: "Symbols", id: "symbols", icon: "plus.rectangle.on.rectangle", shortcut: "⌥⌘Y", note: "add / hide symbols"),
            AppWindow(title: "Watchlists", id: "watch", icon: "star", shortcut: "", note: ""),
        ]),
        AppWindowGroup(name: "Market & gainers", icon: "flame", windows: [
            AppWindow(title: "Daily Gainers", id: "gainers", icon: "flame", shortcut: "⇧⌘G", note: "live, with indices and news"),
            AppWindow(title: "Multibaggers", id: "multibaggers", icon: "chart.line.uptrend.xyaxis.circle", shortcut: "⌥⌘M", note: "≥ 30% in a month"),
            AppWindow(title: "F Notes", id: "mbnotes", icon: "note.text", shortcut: "⌥⇧⌘N", note: "your notes per multibagger + patterns"),
            AppWindow(title: "F Combinations", id: "mbcombos", icon: "list.bullet.rectangle", shortcut: "⌥⌘F", note: "saved multibagger combinations"),
            AppWindow(title: "Sectors", id: "sectors", icon: "square.grid.3x3", shortcut: "⇧⌘0", note: "rotation and regimes"),
            AppWindow(title: "My Picks", id: "picks", icon: "star.square.on.square", shortcut: "⌥⌘P", note: "returns since picked"),
        ]),
        AppWindowGroup(name: "Charts", icon: "chart.xyaxis.line", windows: [
            AppWindow(title: "Chart viewer", id: "chart", icon: "chart.xyaxis.line", shortcut: "⇧⌘K", note: ""),
            AppWindow(title: "Chart Reel", id: "reel", icon: "film.stack", shortcut: "⌥⌘R", note: "flick through charts"),
            AppWindow(title: "Gainer Charts", id: "gainerCharts", icon: "rectangle.stack", shortcut: "⌥⌘G", note: "Chart 1 → Chart 2 per gainer"),
            AppWindow(title: "News & Deals", id: "newschart", icon: "newspaper", shortcut: "⌥⌘N", note: "news letters and bulk deals"),
        ]),
        AppWindowGroup(name: "Delivery", icon: "shippingbox", windows: [
            AppWindow(title: "Delivery Analysis", id: "delivery", icon: "shippingbox", shortcut: "⌥⌘D", note: "NSE delivery highs"),
            AppWindow(title: "Event Scan", id: "eventscan", icon: "scope", shortcut: "⌥⌘L", note: "days since a condition"),
        ]),
        AppWindowGroup(name: "Tests & evaluations", icon: "testtube.2", windows: [
            AppWindow(title: "Performance", id: "perf", icon: "chart.line.uptrend.xyaxis", shortcut: "⇧⌘9", note: "returns after an event"),
            AppWindow(title: "Experiments", id: "experiments", icon: "flask", shortcut: "⌥⌘E", note: "compare triggers"),
            AppWindow(title: "Timing Lab", id: "timinglab", icon: "timer", shortcut: "⌥⌘T", note: "buy triggers after a shortlist"),
            AppWindow(title: "Combinatorix", id: "combi", icon: "square.stack.3d.up", shortcut: "⌥⌘X", note: "combinations behind gainers"),
            AppWindow(title: "AUTO-PREDICT", id: "autopredict", icon: "wand.and.stars", shortcut: "⌥⌘A", note: "learns what comes before ≥ 30%"),
            AppWindow(title: "Neural Net", id: "nn", icon: "point.3.connected.trianglepath.dotted", shortcut: "", note: "shared values of top gainers"),
        ]),
        AppWindowGroup(name: "Alerts", icon: "bell", windows: [
            AppWindow(title: "Alerts", id: "alertlog", icon: "bell", shortcut: "⇧⌘3", note: "everything that fired"),
            AppWindow(title: "Alert Tracker", id: "tracker", icon: "binoculars", shortcut: "⌥⌘J", note: "% change since the alert"),
            AppWindow(title: "Email & Rules", id: "alerts", icon: "envelope.badge", shortcut: "⇧⌘2", note: "rules and email"),
        ]),
        AppWindowGroup(name: "Notes", icon: "doc.text", windows: [
            AppWindow(title: "Notes & Pine Scripts", id: "notes", icon: "doc.text", shortcut: "⇧⌘7", note: ""),
            AppWindow(title: "Screenshots", id: "shots", icon: "camera", shortcut: "", note: ""),
        ]),
    ]
}

/// One toolbar menu that opens any window, grouped by category — replaces the long rows of window buttons.
struct OpenMenu: View {
    @Environment(\.openWindow) private var openWindow
    var title = "Open"

    var body: some View {
        Menu {
            ForEach(AppWindows.groups) { g in
                Section(g.name) {
                    ForEach(g.windows) { w in
                        Button { openWindow(id: w.id) } label: {
                            Label(w.shortcut.isEmpty ? w.title : "\(w.title)   \(w.shortcut)", systemImage: w.icon)
                        }
                    }
                }
            }
            Divider()
            Button { openWindow(id: "hub") } label: { Label("Settings…   ⌥⌘,", systemImage: "gearshape") }
        } label: {
            Label(title, systemImage: "square.grid.2x2")
        }
        .help("Open any window — grouped into Data, Market & gainers, Charts, Delivery, Tests & evaluations, Alerts")
    }
}

/// Gear button that opens the Settings hub, optionally with one section expanded.
struct SettingsHubButton: View {
    @Environment(\.openWindow) private var openWindow
    var section: String? = nil

    var body: some View {
        Button {
            if let section { UserDefaults.standard.set(true, forKey: "hub.\(section)") }
            openWindow(id: "hub")
        } label: { Label("Settings", systemImage: "gearshape") }
            .help("All settings in one place, in collapsible sections (⌥⌘,)")
    }
}

/// The quick-chart (dots) settings as plain controls.
struct PeekSettings: View {
    @AppStorage("peek.enabled") private var enabled = true
    @AppStorage("peek.seconds") private var seconds = 3.0
    @AppStorage("peek.size") private var size = "Medium"
    @AppStorage("peek.preload") private var preload = true
    @AppStorage("peek.hoverDelay") private var hoverDelay = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show the two dots after each symbol (blue = Chart 1, orange = Chart 2)", isOn: $enabled)
            Picker("Rest on a dot for", selection: $hoverDelay) {
                ForEach([0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { Text("\(CombiEngine.fmt($0)) s").tag($0) }
            }.fixedSize()
            Picker("Show the chart for", selection: $seconds) {
                ForEach([2.0, 3, 5, 8, 10, 15, 30], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                Text("Until I close it").tag(0.0)
            }.fixedSize()
            Picker("Size", selection: $size) {
                ForEach(ChartPeek.sizes, id: \.0) { s in Text("\(s.0) (\(Int(s.1.width))×\(Int(s.1.height)))").tag(s.0) }
                Text("Custom (resize the window once)").tag("Custom")
            }.fixedSize()
            Toggle("Preload both charts of the selected row (faster)", isOn: $preload)
        }
    }
}

private enum HubSheet: String, Identifiable {
    case sheet, news, sectors, chartLinks, columns
    var id: String { rawValue }
}

/// Settings hub: every setting of the app in collapsible sections. Each section remembers whether it is open.
struct SettingsHubView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hub.indicators") private var indicators = true
    @AppStorage("filter.dayChange") private var dayChange = true
    @AppStorage("hub.streak") private var streak = false
    @AppStorage("hub.t3") private var t3 = false
    @AppStorage("hub.priceT3") private var priceT3 = false
    @AppStorage("hub.peek") private var peek = false
    @AppStorage("hub.alerts") private var alerts = false
    @AppStorage("hub.data") private var data = false
    @AppStorage("hub.windows") private var windows = false
    @AppStorage("alerts.endOfDay") private var endOfDay = true
    @AppStorage("alerts.at") private var alertAt = 15 * 60 + 45
    @State private var sheet: HubSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings").font(.largeTitle.bold())
                Text("Click a heading to open or close it. Changes apply at once unless a section has an Apply button.")
                    .font(.callout).foregroundStyle(.secondary)

                group("Filter columns & indicators", "function", $indicators) {
                    Toggle("Show today's % change in brackets after each symbol in the Filter", isOn: $dayChange)
                    sub("STREAK — days in a row of the delivery condition", $streak) { StreakSettings() }
                    sub("T3 on delivery — line on delivery charts, t3Color", $t3) { T3Settings() }
                    sub("T3 Fast / Slow on prices — T3_FAST, T3_SLOW, T3F, T3S", $priceT3) { PriceT3Settings() }
                    HStack {
                        Text("MOR / DAY use Yahoo 5-minute bars:").font(.callout)
                        Text(Intraday5mCenter.shared.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Update 5-min now") { Intraday5mCenter.shared.update(Intraday5mCenter.allSheetSymbols, force: true) }
                    }
                    HStack {
                        Text("Delivery signal, JUMP, scope:").font(.callout)
                        Spacer()
                        Button("Open Delivery Analysis") { openWindow(id: "delivery") }
                    }
                }

                group("Quick chart dots", "eye", $peek) { PeekSettings() }

                group("Alerts timing", "bell", $alerts) {
                    Picker("Show alerts", selection: $endOfDay) {
                        Text("once a day").tag(true)
                        Text("as data arrives").tag(false)
                    }.pickerStyle(.segmented).fixedSize()
                    if endOfDay {
                        Picker("at (IST, Mon–Fri)", selection: $alertAt) {
                            ForEach(AlertsBrowserView.alertTimes, id: \.self) { (m: Int) in Text(AlertsBrowserView.hhmm(m)).tag(m) }
                        }.fixedSize()
                    }
                    HStack(spacing: 10) {
                        Button("Shortlist alerts & Alerts list") { openWindow(id: "alertlog") }
                        Button("Email & Rules") { openWindow(id: "alerts") }
                        Button("Alert Tracker") { openWindow(id: "tracker") }
                    }
                }

                group("Data, sources & keys", "externaldrive", $data) {
                    row("Google Sheet link, refresh, open at login", "Edit…") { sheet = .sheet }
                    row("Filter columns shown and their order", "Choose…") { sheet = .columns }
                    row("Groq key and news (labels, reasons)", "Edit…") { sheet = .news }
                    row("Sectors: column, regime settings", "Edit…") { sheet = .sectors }
                    row("Chart links (Chart 1 / Chart 2)", "Edit…") { sheet = .chartLinks }
                }

                group("All windows", "square.grid.2x2", $windows) {
                    ForEach(AppWindows.groups) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(g.name, systemImage: g.icon).font(.callout.bold())
                            FlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(g.windows) { w in
                                    Button { openWindow(id: w.id) } label: { Label(w.title, systemImage: w.icon) }
                                        .help(w.note.isEmpty ? w.title : "\(w.title) — \(w.note) \(w.shortcut)")
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .sheet: SettingsView()
                case .news: NewsAISettings()
                case .sectors: SectorSettings()
                case .chartLinks: ChartLinkSettings()
                case .columns: ColumnChooser()
                }
            }
            .environmentObject(vm)
        }
    }

    private func group<C: View>(_ title: String, _ icon: String, _ open: Binding<Bool>, @ViewBuilder _ content: @escaping () -> C) -> some View {
        DisclosureGroup(isExpanded: open) {
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(.top, 8).padding(.leading, 4)
        } label: {
            Label(title, systemImage: icon).font(.title3.weight(.semibold))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { open.wrappedValue.toggle() } }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    private func sub<C: View>(_ title: String, _ open: Binding<Bool>, @ViewBuilder _ content: @escaping () -> C) -> some View {
        DisclosureGroup(isExpanded: open) {
            content().padding(.vertical, 6)
        } label: {
            Text(title).font(.callout.weight(.medium))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { open.wrappedValue.toggle() } }
        }
    }

    private func row(_ text: String, _ button: String, _ action: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.callout)
            Spacer()
            Button(button, action: action)
        }
    }
}
