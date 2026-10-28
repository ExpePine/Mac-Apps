import SwiftUI
import WebKit

/// In-app chart window: opens the stock's chart link (e.g. TradingView) in a built-in browser that keeps your login,
/// with ◀ ▶ through the list it was opened from, and one-click snapshots stored per stock.
struct ChartViewer: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var web = WebHolder()
    @State private var typed = ""
    @State private var showSettings = false
    @AppStorage("viewer.showDelivery") private var showDelivery = true
    @AppStorage("viewer.syncDelivery") private var syncDelivery = true
    @AppStorage("viewer.showNews") private var showNews = true
    @State private var crossDay: String?
    @State private var crossFails = 0
    @StateObject private var mini = LWChartHolder()
    @State private var lastTV: String = ""          // last range read from TradingView
    @State private var pushedToTVAt = Date.distantPast
    @State private var syncFails = 0
    @State private var syncNote: String?
    @State private var lastSyncReport = ""
    @State private var pendingGoTo: String?
    private let syncTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private var symbol: String { vm.chartSymbol ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if symbol.isEmpty && !web.signingIn {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Type a symbol above, or double-click / right-click a stock anywhere in the app").font(.title3)
                    Text("Charts open from your chart-links sheet (Chart settings). Log in to TradingView once here — it stays logged in.")
                        .foregroundStyle(.secondary)
                    Button(vm.chartBook.links.isEmpty ? "Set up chart links…" : "Chart settings…") { showSettings = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if showNews && !symbol.isEmpty {
                    NewsStrip(symbol: symbol, crossDay: crossDay)
                    Divider()
                }
                if showDelivery && !symbol.isEmpty {
                    VSplitView {
                        ReelWebView(web: web.view).frame(minHeight: 260)
                        DeliveryMiniChart(symbol: symbol, lw: mini, syncNote: syncNote, focus: vm.chartGoTo).frame(minHeight: 110, idealHeight: 200)
                    }
                } else {
                    ReelWebView(web: web.view)
                }
                if let s = vm.chartStatus {
                    Divider()
                    HStack {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        let c = min(vm.settings.chartLinkColumn, vm.chartCount - 1)
                        if vm.duplicateChartLayouts(for: symbol)[c] != nil, let id = vm.suggestedLayout(column: c) {
                            Button("Use layout \(id) for every stock in \(vm.chartBook.columns[c])") {
                                vm.settings.chartLayoutOverride[vm.chartBook.columns[c]] = id
                                load()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 3)
                }
            }
        }
        .navigationTitle(symbol.isEmpty ? "Chart" : "Chart — \(symbol)")
        .onAppear { load(); vm.refreshChartLinksIfStale() }
        .onChange(of: vm.chartBook.importedAt) { _ in load() }
        .onChange(of: vm.chartSymbol) { _ in load(); lastTV = ""; syncFails = 0 }
        .onReceive(syncTimer) { _ in pollTVRange(); pollCross() }
        .onChange(of: mini.crossDay) { d in if let d { crossDay = d } }
        .onChange(of: symbol) { _ in crossDay = nil; crossFails = 0 }
        .onAppear {
            mini.onUserRange = { from, to in
                guard UserDefaults.standard.object(forKey: "viewer.syncDelivery") as? Bool ?? true,
                      let f = TVRange.unix(from), let t = TVRange.unix(to) else { return }
                pushedToTVAt = Date()
                TVRange.run(web.view, TVRange.setBody(from: f, to: t + 86_399)) { r in
                    if r != "ok" {
                        // No chart controller on this page: centre TradingView on the middle day with its Go to date box instead
                        goToCenterLater(TVRange.day((f + t) / 2))
                    }
                }
            }
        }
        .onChange(of: vm.settings.chartLinkColumn) { _ in load() }
        .sheet(isPresented: $showSettings) { ChartLinkSettings().environmentObject(vm) }
    }

    private var toolbar: some View {
        let pos = vm.chartQueue.firstIndex(of: symbol)
        return HStack(spacing: 8) {
            Button { vm.stepChart(-1) } label: { Image(systemName: "chevron.left") }
                .disabled((pos ?? 0) == 0).keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .help("Previous stock in the list (⌥⌘←)")
            Button { vm.stepChart(1) } label: { Image(systemName: "chevron.right") }
                .disabled(pos == nil || pos! >= vm.chartQueue.count - 1).keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .help("Next stock in the list (⌥⌘→)")
            if let p = pos, vm.chartQueue.count > 1 {
                Text("\(p + 1) / \(vm.chartQueue.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            SymbolField(vm: vm, placeholder: "Symbol", text: $typed) {
                let s = SymbolBook.clean(typed)
                if !s.isEmpty { vm.chartSymbol = s }
            }
            .frame(width: 150)
            Text(symbol).font(.headline)
            Picker("", selection: Binding(get: { min(vm.settings.chartLinkColumn, vm.chartCount - 1) },
                                          set: { vm.settings.chartLinkColumn = $0 })) {
                ForEach(0..<vm.chartCount, id: \.self) { i in
                    Text("Chart \(i + 1)").tag(i)
                        .help("\(vm.chartName(i)) · \(vm.chartURL(symbol, column: i)?.absoluteString ?? "no link")")
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(vm.chartCount > 1 ? "Switch chart layout (⌘1, ⌘2…)" : "Add a Link2 column to your chart sheet (or an extra layout in Chart settings) for Chart 2")
            ForEach(0..<min(vm.chartCount, 9), id: \.self) { i in
                Button("") { vm.settings.chartLinkColumn = i }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0)
            }
            Spacer()
            Toggle(isOn: $showNews) { Label("News", systemImage: "newspaper") }
                .toggleStyle(.button)
                .help("A one-line strip of this stock's important news above the chart (Groq-labelled, impact ≥ your level)")
            Toggle(isOn: $showDelivery) { Label("Delivery", systemImage: "shippingbox") }
                .toggleStyle(.button)
                .help("Show NSE delivery (with its ta.highest line and signal days) under the chart")
            if showDelivery {
                Toggle(isOn: $syncDelivery) { Image(systemName: "link") }
                    .toggleStyle(.button)
                    .help("Move the TradingView chart and the delivery chart together")
                    .onChange(of: syncDelivery) { _ in syncFails = 0; syncNote = nil; lastTV = "" }
                    .contextMenu {
                        Button("Copy sync report") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("TradingView sync: \(lastSyncReport) · fails \(syncFails) · url \(web.view.url?.absoluteString ?? "-")", forType: .string)
                        }
                        Button("Retry sync") { syncFails = 0; lastTV = "" }
                    }
            }
            Button { web.view.goBack() } label: { Image(systemName: "arrow.backward") }.help("Back")
            Button { web.view.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
            Button { snapshot() } label: { Label("Save snapshot", systemImage: "camera") }
                .disabled(symbol.isEmpty)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Store the chart as a dated screenshot of \(symbol) (⇧⌘S) — the S column turns green")
            Button { vm.shotSymbol = symbol; openWindow(id: "shots") } label: { Label("Annotate", systemImage: "pencil.tip.crop.circle") }
                .disabled(symbol.isEmpty).help("Open this stock's screenshots to draw on them")
            Menu {
                Button("Open in browser") { if let u = web.view.url ?? vm.chartURL(symbol) { NSWorkspace.shared.open(u) } }
                Button("Copy chart link") {
                    if let u = web.view.url ?? vm.chartURL(symbol) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string) }
                }
                Divider()
                ForEach(0..<TVAccounts.count, id: \.self) { a in
                    Button("Sign in — \(TVAccounts.name(a)) (\(a == 0 ? "Chart 1" : "Chart 2"))…") {
                        web.openSignIn(account: a)
                        vm.chartStatus = "Signing in \(TVAccounts.name(a)) — used for \(a == 0 ? "Chart 1" : "Chart 2 and later charts"). Use a different TradingView account for each. Then open a stock."
                            + (a == 1 && !TVAccounts.secondIsPersistent ? " (On macOS 13 this sign-in lasts until the app quits.)" : "")
                    }
                }
                Menu("Sign out") {
                    ForEach(0..<TVAccounts.count, id: \.self) { a in
                        Button("Sign out \(TVAccounts.name(a))") { web.signOut(account: a) }
                    }
                }
                Toggle("Separate TradingView accounts for Chart 1 and Chart 2", isOn: Binding(
                    get: { TVAccounts.separate }, set: { TVAccounts.separate = $0; load() }))
                Divider()
                Button("Chart settings…") { showSettings = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func load() {
        guard !symbol.isEmpty else { return }
        typed = symbol
        let c = min(vm.settings.chartLinkColumn, vm.chartCount - 1)
        let src = vm.chartSource(symbol, column: c)
        guard let url = src.url else { vm.chartStatus = "No chart link for \(symbol)"; return }
        let layout = ChartLinkBook.layoutID(url.absoluteString)
        var status = "Chart \(c + 1) · \(src.from) · layout \(layout.isEmpty ? "default" : layout)"
        if let first = vm.duplicateChartLayouts(for: symbol)[c] {
            status += " ⚠️ same layout as Chart \(first + 1) — paste a link from a different layout in Chart settings"
        } else if vm.chartCount == 1 {
            status += " · only one chart: your sheet has no Link2 column yet"
        }
        let acct = TVAccounts.account(forChart: c)
        if TVAccounts.separate { status += " · \(TVAccounts.name(acct))" }
        vm.chartStatus = status
        web.use(account: acct)
        web.signingIn = false
        web.view.stopLoading()
        web.view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        centreOnGoTo()
    }

    /// Opened from Daily Gainers: once TradingView has loaded, centre it on the gainer's day (the current bar).
    private func centreOnGoTo() {
        guard let day = vm.chartGoTo else { return }
        let sym = symbol
        func attempt(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard symbol == sym, vm.chartGoTo == day else { return }
                if web.view.isLoading && n > 0 { attempt(n - 1); return }
                ReelPool.helper.centre(web.view, date: day, tries: 4)
            }
        }
        attempt(8)
    }

    /// TradingView → delivery chart: follow TradingView's visible dates (and delivery → TradingView via onUserRange).
    /// TradingView crosshair → the news strip shows that day's news.
    private func pollCross() {
        guard showNews, !symbol.isEmpty, !web.view.isLoading, crossFails < 30 else { return }
        TVRange.run(web.view, TVRange.crossBody) { r in
            guard let t = Int(r) else { crossFails += 1; return }
            crossFails = 0
            if t > 0 { let d = TVRange.day(t); if d != crossDay { crossDay = d } }
        }
    }

    private func pollTVRange() {
        guard showDelivery, syncDelivery, !symbol.isEmpty, !web.view.isLoading,
              Date().timeIntervalSince(pushedToTVAt) > 0.8 else { return }
        if syncFails >= 25 { return }              // gave up on this page: only delivery → TradingView (Go to date) works
        TVRange.run(web.view, TVRange.getBody) { r in
            let parts = r.split(separator: ",").compactMap { Int($0) }
            guard parts.count >= 2 else {
                syncFails += 1
                lastSyncReport = r
                if syncFails >= 25 {
                    syncNote = "Sync: TradingView doesn't expose its chart here (\(r.prefix(60))) — moving the delivery chart still re-centres TradingView"
                } else { syncNote = "Sync: waiting for TradingView… (\(r.prefix(40)))" }
                return
            }
            syncFails = 0
            lastSyncReport = "ok \(r)"
            syncNote = "🔗 synced"
            guard r != lastTV else { return }
            lastTV = r
            _ = mini.follow(tvResult: r)
        }
    }

    /// Fallback when there's no chart controller: after you stop moving the delivery chart, TradingView jumps to its middle day.
    private func goToCenterLater(_ day: String) {
        pendingGoTo = day
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pendingGoTo == day else { return }
            pendingGoTo = nil
            ReelPool.helper.goTo(web.view, date: day, tries: 2, native: true)
        }
    }

    private func snapshot() {
        let sym = symbol
        let config = WKSnapshotConfiguration()
        web.view.takeSnapshot(with: config) { image, error in
            DispatchQueue.main.async {
                if let image { vm.saveChartSnapshot(image, symbol: sym) }
                else { vm.chartStatus = "Snapshot failed: \(error?.localizedDescription ?? "unknown")" }
            }
        }
    }
}

/// TradingView sign-ins: Account 1 (Chart 1) and Account 2 (Chart 2 and later charts) keep separate cookies,
/// so each chart can stay signed in to a different TradingView account at the same time.
enum TVAccounts {
    static let count = 2
    private static let secondID = UUID(uuidString: "6B1F0C4E-2F7A-4D8E-9C1B-5A3E7D2F9B40")!
    private static var cache: [Int: WKWebsiteDataStore] = [:]

    static var separate: Bool {
        get { UserDefaults.standard.object(forKey: "tv.separateAccounts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tv.separateAccounts") }
    }

    /// Which account a chart uses: Chart 1 → Account 1; Chart 2 (and extra layouts) → Account 2.
    static func account(forChart c: Int) -> Int { separate && c >= 1 ? 1 : 0 }

    static func name(_ a: Int) -> String { "Account \(a + 1)" }

    /// Account 2 keeps its sign-in across restarts on macOS 14+; on macOS 13 it lasts until the app quits.
    static var secondIsPersistent: Bool { if #available(macOS 14.0, *) { return true } else { return false } }

    static func store(_ a: Int) -> WKWebsiteDataStore {
        if a == 0 { return .default() }
        if let s = cache[a] { return s }
        let s: WKWebsiteDataStore
        if #available(macOS 14.0, *) { s = WKWebsiteDataStore(forIdentifier: secondID) } else { s = .nonPersistent() }
        cache[a] = s
        return s
    }
}

/// One web view per TradingView account for the window (logins and cookies persist per account).
/// Also opens sign-in pop-ups (e.g. "Continue with Google") in their own small window.
final class WebHolder: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    @Published private(set) var account = 0
    @Published var signingIn = false         // show the web view even without a stock (sign-in page)
    private var views: [Int: WKWebView] = [:]
    private var popups: [(window: NSWindow, web: WKWebView)] = []

    var view: WKWebView { webView(for: account) }

    private func webView(for a: Int) -> WKWebView {
        if let v = views[a] { return v }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = TVAccounts.store(a)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let v = WKWebView(frame: .zero, configuration: config)
        v.allowsBackForwardNavigationGestures = true
        v.customUserAgent = Self.userAgent
        v.uiDelegate = self
        v.navigationDelegate = self
        views[a] = v
        return v
    }

    /// Switches the window to an account's web view (its own cookies / sign-in).
    func use(account a: Int) {
        guard a != account else { return }
        account = a
    }

    // window.open(...) → a real window that shares the session, so the login flows back to the chart page
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.customUserAgent = Self.userAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in"
        w.contentView = popup
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append((w, popup))
        return popup
    }

    // the pop-up closes itself after signing in
    func webViewDidClose(_ webView: WKWebView) {
        if let i = popups.firstIndex(where: { $0.web === webView }) {
            popups[i].window.close()
            popups.remove(at: i)
            view.reload()                        // pick up the new login
        }
    }

    // JavaScript alert / confirm (some sites use them during login)
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    // links that want a new tab (target=_blank) without a pop-up: open in the same view
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil, views.values.contains(where: { $0 === webView }), let u = navigationAction.request.url {
            webView.load(URLRequest(url: u))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Opens TradingView's sign-in page for an account in the chart window.
    func openSignIn(account a: Int) {
        use(account: a)
        signingIn = true
        if let u = URL(string: "https://in.tradingview.com/accounts/signin/") { view.load(URLRequest(url: u)) }
    }

    /// Clears one account's cookies (signs that account out).
    func signOut(account a: Int) {
        TVAccounts.store(a).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.views[a]?.reload()
        }
    }
}

struct WebView: NSViewRepresentable {
    let holder: WebHolder
    func makeNSView(context: Context) -> WKWebView { holder.view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Chart-links sheet and how charts open.
struct ChartLinkSettings: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        Form {
            Section {
                TextField("Chart-links sheet link", text: $link)
                HStack {
                    Button(vm.chartBook.links.isEmpty ? "Import" : "Re-import") {
                        vm.settings.chartSheetLink = link
                        vm.importChartLinks()
                    }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || vm.isImportingCharts)
                    if vm.isImportingCharts { ProgressView().controlSize(.small) }
                    if let s = vm.chartStatus { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                TextField("Symbol column", text: $vm.settings.chartSymbolColumn)
            } header: { Text("Chart links") } footer: {
                Text("A Google Sheet with a Symbol column and one or more link columns (Link1, Link2…), shared as “Anyone with the link can view”. For stocks not in the sheet, the app reuses the sheet's link pattern with the stock's symbol.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(vm.settings.extraChartTemplates.enumerated()), id: \.offset) { i, _ in
                    HStack {
                        Text("Chart \(max(1, vm.chartBook.columns.count) + i + 1)").frame(width: 60, alignment: .leading)
                        TextField("https://in.tradingview.com/chart/XXXX/?symbol=NSE%3ATCS", text: Binding(
                            get: { vm.settings.extraChartTemplates.indices.contains(i) ? vm.settings.extraChartTemplates[i] : "" },
                            set: { v in if vm.settings.extraChartTemplates.indices.contains(i) { vm.settings.extraChartTemplates[i] = ScreenerViewModel.templateFromLink(v) } }))
                            .font(.caption.monospaced())
                        Button { vm.settings.extraChartTemplates.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    let t = vm.settings.extraChartTemplates.indices.contains(i) ? vm.settings.extraChartTemplates[i] : ""
                    let id = ChartLinkBook.layoutID(t)
                    let sheetIDs = vm.chartBook.templates.map(ChartLinkBook.layoutID)
                    if !t.isEmpty {
                        Text(sheetIDs.contains(id)
                             ? "⚠️ Layout \(id.isEmpty ? "default" : id) is the same as your sheet's link — this chart will look like Chart 1. Open the other layout in TradingView and copy its link."
                             : "Layout \(id.isEmpty ? "default" : id)" + (t.contains("{SYMBOL}") ? "" : " · ⚠️ no NSE: symbol found in the link"))
                            .font(.caption).foregroundStyle(sheetIDs.contains(id) || !t.contains("{SYMBOL}") ? .orange : .secondary)
                    }
                }
                Button("Add a chart layout") { vm.settings.extraChartTemplates.append("") }
            } header: { Text("Extra chart layouts") } footer: {
                Text("Paste a TradingView chart link of any stock in another layout; the app swaps in each stock's symbol. These appear after the sheet's columns as Chart 2, Chart 3…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Learned patterns") {
                if vm.chartBook.templates.isEmpty {
                    Text("Import the sheet to learn its pattern.").foregroundStyle(.secondary)
                }
                ForEach(Array(vm.chartBook.templates.enumerated()), id: \.offset) { i, t in
                    let col = i < vm.chartBook.columns.count ? vm.chartBook.columns[i] : "Link \(i + 1)"
                    LabeledContent(col) {
                        Text(t.isEmpty ? "—" : t).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    }
                    let found = vm.chartBook.layouts(column: i)
                    Picker("Layout for \(col)", selection: Binding(
                        get: { vm.settings.chartLayoutOverride[col] ?? "" },
                        set: { vm.settings.chartLayoutOverride[col] = $0.isEmpty ? nil : $0 })) {
                        Text("Each stock's own link from the sheet").tag("")
                        ForEach(found.filter { !$0.id.isEmpty }, id: \.id) { l in
                            Text("\(l.id) for every stock  (in \(l.count) rows)").tag(l.id)
                        }
                        if let o = vm.settings.chartLayoutOverride[col], !o.isEmpty, !found.contains(where: { $0.id == o }) {
                            Text("\(o) for every stock").tag(o)
                        }
                    }
                    .font(.caption)
                }
                TextField("Fallback when nothing else fits", text: $vm.settings.chartFallbackTemplate)
                    .font(.caption.monospaced())
            }
            Section("Opening charts") {
                Toggle("Open charts inside the app (otherwise in your browser)", isOn: $vm.settings.chartOpenInApp)
                Text("Double-click a stock in the Data, Filter or Gainers tables, or right-click any stock → Open chart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 560)
        .onAppear { link = vm.settings.chartSheetLink }
    }
}
