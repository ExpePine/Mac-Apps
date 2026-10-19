import SwiftUI
import AppKit

/// "Data Import" screen: import button, data status, quick search and the full sheet.
struct ImportView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false
    @State private var showColumnNames = false
    @StateObject private var finder = TableFinder()
    @State private var importSelection: [SheetRow] = []

    var body: some View {
        VStack(spacing: 0) {
            AlertsBanner()
            if vm.settings.sheetLink.isEmpty {
                connectState
            } else {
                FreshnessBar(showSettings: $showSettings)
                Divider()
                if vm.hasData {
                    if finder.isVisible { FindBar(finder: finder); Divider() }
                    SheetTableView(headers: vm.headers,
                                   originalHeaders: vm.table.originalHeaders,
                                   columns: Array(vm.headers.indices),
                                   rows: vm.importRows,
                                   version: vm.importVersion,
                                   sortColumn: vm.importSortColumn,
                                   sortDescending: vm.importSortDescending,
                                   frozenColumns: vm.settings.frozenColumns,
                                   onHeaderClick: { index in
                                       if vm.importSortColumn == index {
                                           vm.importSortDescending.toggle()
                                       } else {
                                           vm.importSortColumn = index
                                           vm.importSortDescending = false
                                       }
                                   },
                                   onSelectRow: { vm.selectStock(from: $0) },
                                   findQuery: finder.activeQuery,
                                   findCurrent: finder.currentMatch,
                                   onSelectRows: { importSelection = $0 },
                                   rowMenu: { row in vm.rowMenu(row, selection: importSelection, openWindow: openWindow) })
                    Divider()
                    statusBar
                } else {
                    notImportedState
                }
            }
        }
        .navigationTitle("Data Import")
        .onChange(of: vm.importVersion) { _ in finder.update(rows: vm.importRows, columns: Array(vm.headers.indices)) }
        .onChange(of: finder.isVisible) { v in if v { finder.update(rows: vm.importRows, columns: Array(vm.headers.indices)) } }
        .background(WindowReader { window in
            FindRouter.register(window) { [weak finder] in finder?.show() }
        })
        .searchable(text: $vm.importSearch, placement: .toolbar, prompt: "Search all columns…")
        .toolbar {
            ToolbarItemGroup {
                AlertsButton()
                AnimateButton()
                FreezeMenu()
                Button {
                    vm.importNow()
                } label: {
                    Label(vm.hasData ? "Re-import" : "Import data", systemImage: "square.and.arrow.down")
                }
                .disabled(vm.isLoading || vm.settings.sheetLink.isEmpty)
                .keyboardShortcut("r")
                .help("Download the sheet now (⌘R)")

                Button {
                    openWindow(id: "filter")
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle.fill")
                }
                .help("Open the Filter screen (⇧⌘1)")

                Button {
                    openWindow(id: "changes")
                } label: {
                    Label("Changes", systemImage: "rectangle.grid.2x2")
                }
                .help("Cards showing what changed since the previous day (⇧⌘8)")
                Button {
                    openWindow(id: "gainers")
                } label: {
                    Label("Gainers", systemImage: "flame")
                }
                .help("Daily gainers with NIFTY / SENSEX charts and news reasons (⇧⌘G)")
                Button {
                    openWindow(id: "sectors")
                } label: {
                    Label("Sectors", systemImage: "square.grid.3x3")
                }
                .help("Sector momentum & regime changes (⇧⌘0)")

                Button {
                    openWindow(id: "perf")
                } label: {
                    Label("Performance", systemImage: "chart.line.uptrend.xyaxis")
                }
                .help("How stocks did after an event such as D_Trigger (⇧⌘9)")

                Button {
                    openWindow(id: "notes")
                } label: {
                    Label("MV2 Requirements & Pine", systemImage: "doc.text")
                }
                .help("MV2 Build Requirements and Pine Script editor (⇧⌘7)")

                Button {
                    openWindow(id: "alerts")
                } label: {
                    Label("Alerts & Email", systemImage: "bell.badge")
                }
                .help("MV2 check, buy triggers and email (⇧⌘2)")

                Button {
                    showColumnNames = true
                } label: {
                    Label("Column names", systemImage: "character.cursor.ibeam")
                }
                .disabled(!vm.hasData)
                .help("Give columns like var 1 … var 10 their real names")

                Button {
                    showSettings = true
                } label: {
                    Label("Sheet settings", systemImage: "gearshape")
                }
                .help("Google Sheet link, refresh interval, open at login")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(vm)
        }
        .sheet(isPresented: $showColumnNames) {
            ColumnNamesEditor().environmentObject(vm)
        }
        .sheet(isPresented: $vm.showAlertsPopup) {
            ConditionsMetView().environmentObject(vm)
        }
        .task {
            LoginItem.enableOnFirstLaunch()
            vm.startAutoRefresh()
        }
    }

    private var connectState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("Connect your Google Sheet")
                .font(.title2.bold())
            Text("Paste the sheet link once — the app imports fresh data automatically.")
                .foregroundStyle(.secondary)
            Button("Add sheet link…") { showSettings = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notImportedState: some View {
        VStack(spacing: 14) {
            if vm.isLoading {
                ProgressView()
                Text("Importing data…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                Text("Data not imported yet")
                    .font(.title2.bold())
                Button {
                    vm.importNow()
                } label: {
                    Label("Import data", systemImage: "square.and.arrow.down")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if let error = vm.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if vm.importSearch.isEmpty {
                Text("\(vm.rows.count) rows · \(vm.headers.count) columns")
            } else {
                Text("\(vm.importRows.count) of \(vm.rows.count) rows match \"\(vm.importSearch)\"")
            }
            Spacer()
            Text("Click a column header to sort · Auto-import every \(vm.settings.refreshMinutes) min · v\(AppInfo.version)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Freshness bar ("is the data updated?")

struct FreshnessBar: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Binding var showSettings: Bool

    var body: some View {
        // Re-evaluates every 30 s so "x minutes ago" and the stale check stay current.
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let info = vm.freshnessInfo(now: context.date)

            HStack(spacing: 10) {
                Image(systemName: info.level.symbol)
                    .foregroundStyle(info.level.color)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .fontWeight(.semibold)
                    Text(info.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    mv2Line(vm.mv2Status(today: context.date))
                }
                Spacer()
                if let result = vm.manualResult, context.date.timeIntervalSince(result.at) < 120 {
                    Label(result.text, systemImage: result.isNew ? "arrow.down.circle.fill" : "equal.circle")
                        .font(.caption)
                        .foregroundStyle(result.isNew ? .green : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
                DownloadDetailsButton()
                if vm.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Importing…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button {
                        vm.importNow()
                    } label: {
                        Label(vm.hasData ? "Re-import now" : "Import data", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(info.level.color.opacity(0.12))
        }
    }

    @ViewBuilder
    func mv2Line(_ status: MV2Status) -> some View {
        switch status.state {
        case .ok:
            Label(status.text, systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        case .notUpdated:
            Label(status.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
        case .unknown:
            if vm.hasData {
                Label(status.text, systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Download details (to see exactly what was fetched)

enum AppInfo {
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }
}

struct DownloadDetailsButton: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @State private var show = false

    var body: some View {
        Button {
            show.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help("Download details")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Download details").font(.headline)
                row("App version", AppInfo.version)
                if let info = vm.lastFetchInfo {
                    row("Downloaded at", info.fetchedAt.formatted(date: .abbreviated, time: .standard))
                    row("Source", info.endpoint)
                    row("Tab", info.tab)
                    row("Result", info.changed ? "new content" : "same content as before")
                    row("HTTP status", "\(info.httpStatus)")
                    row("Size", ByteCountFormatter.string(fromByteCount: Int64(info.bytes), countStyle: .file))
                    row("Rows × columns", "\(info.rowCount) × \(info.columnCount)")
                    if let age = info.cacheAgeSeconds, age > 0 { row("Google cache age", "\(age) s") }
                    row("First row", info.firstRowSample)
                    row("URL", info.urlUsed)
                } else {
                    Text("Nothing downloaded since the app started. Click Re-import now.")
                        .foregroundStyle(.secondary)
                }
                if let error = vm.errorMessage {
                    row("Last error", error)
                }
                HStack {
                    Spacer()
                    Button("Copy details") { copy() }
                }
            }
            .padding(14)
            .frame(width: 520)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func copy() {
        var lines = ["App version: \(AppInfo.version)"]
        if let i = vm.lastFetchInfo {
            lines += ["Downloaded at: \(i.fetchedAt)", "Source: \(i.endpoint)", "Tab: \(i.tab)",
                      "Result: \(i.changed ? "new" : "same")", "HTTP: \(i.httpStatus)", "Bytes: \(i.bytes)",
                      "Rows x cols: \(i.rowCount) x \(i.columnCount)", "First row: \(i.firstRowSample)", "URL: \(i.urlUsed)"]
        }
        if let e = vm.errorMessage { lines.append("Error: \(e)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
