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

    private var symbol: String { vm.chartSymbol ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if symbol.isEmpty {
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
                WebView(holder: web)
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
        .onChange(of: vm.chartSymbol) { _ in load() }
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
            TextField("Symbol", text: $typed)
                .textFieldStyle(.roundedBorder).frame(width: 130)
                .onSubmit { if !typed.isEmpty { vm.chartSymbol = typed.uppercased() } }
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
                Button("Sign in to TradingView…") { web.openSignIn() }
                Button("Sign out (clear in-app browser data)") { web.signOut() }
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
        vm.chartStatus = status
        web.view.stopLoading()
        web.view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
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

/// Keeps one web view alive for the window (logins and cookies persist in the app's default web store).
/// Also opens sign-in pop-ups (e.g. "Continue with Google") in their own small window.
final class WebHolder: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    let view: WKWebView
    private var popups: [(window: NSWindow, web: WKWebView)] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let v = WKWebView(frame: .zero, configuration: config)
        v.allowsBackForwardNavigationGestures = true
        v.customUserAgent = Self.userAgent
        view = v
        super.init()
        v.uiDelegate = self
        v.navigationDelegate = self
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
        if navigationAction.targetFrame == nil, webView === view, let u = navigationAction.request.url {
            webView.load(URLRequest(url: u))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Opens TradingView's sign-in page in the chart window (email / password works without pop-ups).
    func openSignIn() {
        if let u = URL(string: "https://in.tradingview.com/accounts/signin/") { view.load(URLRequest(url: u)) }
    }

    /// Clears the in-app browser's cookies (sign out everywhere in this window).
    func signOut() {
        let store = view.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.view.reload()
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
