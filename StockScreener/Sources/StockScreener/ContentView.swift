import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            RulesView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 360)
        } detail: {
            VStack(spacing: 0) {
                if vm.settings.sheetLink.isEmpty {
                    emptyState
                } else {
                    FreshnessBar()
                    Divider()
                    DataGridView()
                    Divider()
                    statusBar
                }
            }
        }
        .navigationTitle("Data")
        .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search symbol, sector…")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openWindow(id: "active-filter")
                } label: {
                    Label("Active Filter", systemImage: "line.3.horizontal.decrease.circle.fill")
                }
                .help("Open the Active Filter window (⇧⌘1)")

                Button {
                    openWindow(id: "alerts")
                } label: {
                    Label("Alerts & Email", systemImage: "bell.badge")
                }
                .help("MV2 check, buy triggers and email (⇧⌘2)")

                Toggle(isOn: $vm.showOnlyHighlighted) {
                    Label("Only highlighted", systemImage: "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .help("Show only rows that meet a highlight rule")

                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(vm.isLoading || vm.settings.sheetLink.isEmpty)
                .help("Refresh now (⌘R)")

                Button {
                    showSettings = true
                } label: {
                    Label("Sheet settings", systemImage: "gearshape")
                }
                .help("Google Sheet link, refresh interval and freshness checks")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(vm)
        }
        .task {
            LoginItem.enableOnFirstLaunch()
            vm.startAutoRefresh()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("Connect your Google Sheet")
                .font(.title2.bold())
            Text("Paste the sheet link once — the app pulls fresh data automatically.")
                .foregroundStyle(.secondary)
            Button("Add sheet link…") { showSettings = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        let shown = vm.displayedRows
        let highlighted = shown.filter { vm.highlight(for: $0) != nil }.count

        return HStack(spacing: 14) {
            Text("Showing \(shown.count) of \(vm.rows.count)")
            Text("\(highlighted) highlighted")
            Spacer()
            Text("Auto-refresh every \(vm.settings.refreshMinutes) min")
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(info.level.color.opacity(0.12))
        }
    }
}

extension FreshnessBar {
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
            if !vm.rows.isEmpty {
                Label(status.text, systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Data grid (dynamic columns, sticky header, colored rows)

struct DataGridView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    private let columnWidth: CGFloat = 130

    var body: some View {
        let rows = vm.displayedRows

        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: index)
                    }
                } header: {
                    headerView
                }
            }
        }
    }

    private var headerView: some View {
        HStack(spacing: 0) {
            ForEach(vm.headers, id: \.self) { header in
                Button {
                    vm.toggleSort(header)
                } label: {
                    HStack(spacing: 4) {
                        Text(header)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        if vm.sortColumn == header {
                            Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: columnWidth)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sort by \(header)")
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func rowView(_ row: SheetRow, index: Int) -> some View {
        let color = vm.highlight(for: row)

        return HStack(spacing: 0) {
            ForEach(vm.headers, id: \.self) { header in
                let text = row.values[header] ?? ""
                Text(text)
                    .lineLimit(1)
                    .frame(width: columnWidth,
                           alignment: NumberParser.parse(text) != nil ? .trailing : .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .help(text)
            }
        }
        .background(
            color.map { $0.color.opacity(0.28) }
                ?? Color.primary.opacity(index.isMultiple(of: 2) ? 0 : 0.035)
        )
        .overlay(alignment: .leading) {
            if let color {
                Rectangle().fill(color.color).frame(width: 3)
            }
        }
        .textSelection(.enabled)
    }
}
