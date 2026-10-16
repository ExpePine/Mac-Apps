import SwiftUI

enum SidebarItem: Hashable {
    case screenshots
    case timeline
    case news
    case scripts
    case patterns
    case chat
    case symbol(UUID)
}

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var directory: SymbolDirectory
    @State private var selection: SidebarItem?

    init(initialSelection: SidebarItem? = .screenshots) {
        _selection = State(initialValue: initialSelection)
    }
    @State private var search = ""
    @State private var showAddSymbol = false
    @State private var capturing = false
    @State private var editingShot: ScreenshotLibraryView.ShotRef?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, search: search, showAddSymbol: $showAddSymbol)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Symbols, notes, tags")
        .sheet(isPresented: $showAddSymbol) {
            SymbolEditor(existing: nil) { saved in selection = .symbol(saved.id) }
                .environmentObject(store)
                .environmentObject(directory)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newSymbol)) { _ in
            showAddSymbol = true
        }
        .task { await directory.refreshIfStale() }
        .onReceive(NotificationCenter.default.publisher(for: .newScreenshot)) { _ in capturing = true }
        .sheet(isPresented: $capturing) {
            NewScreenshotSheet(presetSymbolID: { if case .symbol(let id) = selection { return id }; return nil }()) { ids in
                if ids.count == 1, let id = ids.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editingShot = .init(id: id) }
                }
            }
            .environmentObject(store)
            .environmentObject(directory)
        }
        .sheet(item: $editingShot) { ref in
            ChartShotEditor(shotID: ref.id).environmentObject(store)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .screenshots?:
            ScreenshotLibraryView { id in selection = .symbol(id) }
        case .timeline?:
            TimelineView { selection = $0 }
        case .news?:
            NewsListView { id in selection = .symbol(id) }
        case .scripts?:
            PineScriptsView { id in selection = .symbol(id) }
        case .patterns?:
            PatternsView()
        case .chat?:
            ChatView()
        case .symbol(let id)?:
            if store.symbol(id) != nil {
                SymbolDetailView(symbolID: id).id(id)
            } else {
                EmptyStateView(systemImage: "chart.xyaxis.line",
                               title: "No Symbol Selected",
                               message: "Pick a symbol in the sidebar, or add one with ⇧⌘N.")
            }
        case nil:
            EmptyStateView(systemImage: "chart.xyaxis.line",
                           title: "No Symbol Selected",
                           message: "Pick a symbol in the sidebar, or add one with ⇧⌘N.")
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var directory: SymbolDirectory
    @Binding var selection: SidebarItem?
    var search: String
    @Binding var showAddSymbol: Bool
    @State private var pendingDelete: TrackedSymbol?

    var body: some View {
        List(selection: $selection) {
            Section("Journal") {
                Label("Screenshots", systemImage: "photo.on.rectangle.angled")
                    .tag(SidebarItem.screenshots)
                Label("Timeline", systemImage: "calendar")
                    .tag(SidebarItem.timeline)
                Label("News", systemImage: "newspaper")
                    .tag(SidebarItem.news)
                Label("Pine Scripts", systemImage: "chevron.left.forwardslash.chevron.right")
                    .tag(SidebarItem.scripts)
                Label("Patterns", systemImage: "sparkles")
                    .tag(SidebarItem.patterns)
                Label("Ask Your Notes", systemImage: "bubble.left.and.bubble.right")
                    .tag(SidebarItem.chat)
            }

            if store.symbols.isEmpty {
                Section("Symbols") {
                    Button {
                        showAddSymbol = true
                    } label: {
                        Label("Add your first symbol", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            ForEach(SymbolStatus.allCases) { status in
                let items = store.symbols(with: status).filter { store.matches($0, query: search) }
                if !items.isEmpty {
                    Section(status.title) {
                        ForEach(items) { s in
                            SymbolRow(symbol: s)
                                .tag(SidebarItem.symbol(s.id))
                                .contextMenu { contextMenu(for: s) }
                        }
                    }
                }
            }

            let listed = directory.search(search, limit: 8).filter { store.existingSymbol(ticker: $0.symbol) == nil }
            if !listed.isEmpty {
                Section("Add from NSE") {
                    ForEach(listed) { item in
                        Button {
                            let s = TrackedSymbol(ticker: item.symbol, displayName: item.name, status: .watching)
                            store.upsert(s)
                            selection = .symbol(s.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.symbol).font(.system(.body, design: .rounded).weight(.medium))
                                    Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add \(item.symbol) to Watching")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    showAddSymbol = true
                } label: {
                    Label("Add Symbol", systemImage: "plus")
                }
                .help("Add Symbol (⇧⌘N)")
            }
        }
        .confirmationDialog("Delete \(pendingDelete?.ticker ?? "")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { s in
            Button("Delete Symbol and All Its Notes", role: .destructive) {
                if selection == .symbol(s.id) { selection = .screenshots }
                store.deleteSymbol(s.id)
            }
        } message: { _ in
            Text("This removes every observation, trade and AI summary for this symbol. Export a backup first if you might need them.")
        }
    }

    @ViewBuilder
    private func contextMenu(for s: TrackedSymbol) -> some View {
        Menu("Move to") {
            ForEach(SymbolStatus.allCases) { st in
                Button(st.title) { store.setStatus(st, for: s.id) }
                    .disabled(st == s.status)
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = s }
    }
}

struct SymbolRow: View {
    @EnvironmentObject private var store: Store
    let symbol: TrackedSymbol

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(symbol.ticker)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                if !symbol.displayName.isEmpty {
                    Text(symbol.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            let shots = store.data.chartShots.reduce(0) { $0 + ($1.symbolID == symbol.id ? 1 : 0) }
            if shots > 0 {
                Label("\(shots)", systemImage: "photo")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("\(shots) screenshot\(shots == 1 ? "" : "s")")
            }
        }
        .padding(.vertical, 1)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
