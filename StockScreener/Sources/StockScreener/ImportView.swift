import SwiftUI

/// "Data Import" screen: import button, data status, quick search and the full sheet.
struct ImportView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false
    @State private var showColumnNames = false

    var body: some View {
        VStack(spacing: 0) {
            if vm.settings.sheetLink.isEmpty {
                connectState
            } else {
                FreshnessBar(showSettings: $showSettings)
                Divider()
                if vm.hasData {
                    SheetTableView(headers: vm.headers,
                                   originalHeaders: vm.table.originalHeaders,
                                   columns: Array(vm.headers.indices),
                                   rows: vm.importRows,
                                   version: vm.importVersion,
                                   sortColumn: vm.importSortColumn,
                                   sortDescending: vm.importSortDescending,
                                   onHeaderClick: { index in
                                       if vm.importSortColumn == index {
                                           vm.importSortDescending.toggle()
                                       } else {
                                           vm.importSortColumn = index
                                           vm.importSortDescending = false
                                       }
                                   })
                    Divider()
                    statusBar
                } else {
                    notImportedState
                }
            }
        }
        .navigationTitle("Data Import")
        .searchable(text: $vm.importSearch, placement: .toolbar, prompt: "Search all columns…")
        .toolbar {
            ToolbarItemGroup {
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
            Text("Click a column header to sort · Auto-import every \(vm.settings.refreshMinutes) min")
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
        TimelineView(.periodic(from: .now, by: 30)) { context in
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
