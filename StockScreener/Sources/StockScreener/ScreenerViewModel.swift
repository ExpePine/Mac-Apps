import SwiftUI

enum FreshnessLevel {
    case waiting, fresh, stale, offline

    var color: Color {
        switch self {
        case .waiting: return .secondary
        case .fresh:   return .green
        case .stale:   return .orange
        case .offline: return .red
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "hourglass"
        case .fresh:   return "checkmark.circle.fill"
        case .stale:   return "exclamationmark.triangle.fill"
        case .offline: return "wifi.exclamationmark"
        }
    }
}

struct FreshnessInfo {
    let level: FreshnessLevel
    let title: String
    let detail: String
}

@MainActor
final class ScreenerViewModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            Persistence.save(settings)
            settingsChanged(from: oldValue)
        }
    }

    // Data
    @Published private(set) var table = SheetTable()
    @Published private(set) var isLoading = false
    @Published private(set) var freshness: FreshnessState
    @Published private(set) var lastFetchFailed = false
    @Published var errorMessage: String?

    // Alerts
    @Published var alertState: AlertState { didSet { Persistence.saveAlertState(alertState) } }
    @Published var isSendingEmail = false
    @Published private(set) var triggerMatchCounts: [UUID: Int] = [:]

    // Data Import screen (search + sort run in the background)
    @Published var importSearch = "" { didSet { scheduleImportRecompute(delayMs: 250) } }
    @Published var importSortColumn: Int? { didSet { scheduleImportRecompute(delayMs: 0) } }
    @Published var importSortDescending = false { didSet { scheduleImportRecompute(delayMs: 0) } }
    @Published private(set) var importRows: [SheetRow] = []
    @Published private(set) var importVersion = 0

    // Filter screen
    @Published private(set) var filterRows: [SheetRow] = []
    @Published private(set) var filterIssues: [String] = []
    @Published private(set) var filterVersion = 0
    @Published private(set) var isFiltering = false
    private(set) var painter = CellPainter()

    private var refreshTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var countsTask: Task<Void, Never>?

    var headers: [String] { table.headers }
    var rows: [SheetRow] { table.rows }
    var hasData: Bool { !table.rows.isEmpty }

    init() {
        settings = Persistence.load()
        freshness = Persistence.loadFreshness()
        alertState = Persistence.loadAlertState()
    }

    // MARK: Data source

    func updateSource(link: String, minutes: Int, staleHours: Int, dateColumn: String) {
        let newLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkChanged = newLink != settings.sheetLink

        settings.sheetLink = newLink
        settings.refreshMinutes = minutes
        settings.staleAfterHours = staleHours
        settings.dateColumn = dateColumn

        if linkChanged {
            setTable(SheetTable())
            errorMessage = nil
            lastFetchFailed = false
            freshness = FreshnessState()
            Persistence.saveFreshness(freshness)
        }
        startAutoRefresh()
    }

    /// Fetches now, then again every `refreshMinutes`.
    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let seconds = UInt64(max(1, self.settings.refreshMinutes)) * 60
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    /// "Import data" button.
    func importNow() {
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard !settings.sheetLink.isEmpty else { return }
        guard let url = SheetService.csvURL(from: settings.sheetLink) else {
            errorMessage = "Couldn't understand the sheet link. Open Sheet settings and paste it again."
            lastFetchFailed = true
            return
        }
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await SheetService.fetch(from: url)
            let now = Date()
            let contentChanged = result.hash != freshness.dataHash
            if contentChanged {
                freshness.dataHash = result.hash
                freshness.lastChangedAt = now
            }
            freshness.lastCheckedAt = now
            Persistence.saveFreshness(freshness)
            errorMessage = nil
            lastFetchFailed = false

            // Only swap in the new table if something changed (or nothing is loaded yet):
            // re-filtering identical data every few minutes would just waste time.
            if contentChanged || !hasData || force {
                setTable(result.table)
                adoptColumnSpelling()
            }

            // Alerts run only after the sheet's data has actually been updated.
            if contentChanged {
                await runAlertChecks()
            }
        } catch {
            errorMessage = error.localizedDescription   // keep showing the last good data
            lastFetchFailed = true
        }
    }

    private func setTable(_ newTable: SheetTable) {
        table = newTable
        if let c = importSortColumn, c >= newTable.headers.count { importSortColumn = nil }
        painter = CellPainter(settings.cellRules, table: newTable)
        scheduleImportRecompute(delayMs: 0)
        scheduleFilterRecompute(delayMs: 0)
        scheduleTriggerCounts(delayMs: 0)
    }

    /// If a configured column matches the sheet only by letter case (D_Trigger vs D_TRIGGER),
    /// switch the setting to the sheet's exact spelling so pickers show it selected.
    private func adoptColumnSpelling() {
        func fix(_ name: String) -> String {
            guard !name.isEmpty, !headers.contains(name), let i = table.index(of: name) else { return name }
            return headers[i]
        }
        var s = settings
        s.triggerColumn = fix(s.triggerColumn)
        s.labelColumn = fix(s.labelColumn)
        s.filterSortColumn = fix(s.filterSortColumn)
        s.filterColumns = s.filterColumns.map(fix)
        s.mv2.monthColumn = fix(s.mv2.monthColumn)
        s.mv2.dayColumn = fix(s.mv2.dayColumn)
        if s.triggerColumn != settings.triggerColumn || s.labelColumn != settings.labelColumn
            || s.filterSortColumn != settings.filterSortColumn || s.filterColumns != settings.filterColumns
            || s.mv2 != settings.mv2 {
            settings = s
        }
    }

    // MARK: React to settings edits

    private func settingsChanged(from old: AppSettings) {
        if old.filterGroup != settings.filterGroup {
            scheduleFilterRecompute(delayMs: 300)        // wait for typing to pause
        } else if old.filterSortColumn != settings.filterSortColumn
                    || old.filterSortDescending != settings.filterSortDescending {
            scheduleFilterRecompute(delayMs: 0)
        }
        if old.cellRules != settings.cellRules {
            painter = CellPainter(settings.cellRules, table: table)
            filterVersion += 1                           // repaint
        }
        if old.buyTriggers.map(\.filter) != settings.buyTriggers.map(\.filter) {
            scheduleTriggerCounts(delayMs: 400)
        }
    }

    // MARK: Background recomputation

    private func scheduleImportRecompute(delayMs: UInt64) {
        importTask?.cancel()
        let table = self.table
        let query = importSearch.trimmingCharacters(in: .whitespaces)
        let sortColumn = importSortColumn
        let descending = importSortDescending
        importTask = Task { [weak self] in
            if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) { () -> [SheetRow] in
                var rows = table.rows
                if !query.isEmpty {
                    rows = rows.filter { row in
                        row.cells.contains { $0.range(of: query, options: .caseInsensitive) != nil }
                    }
                }
                if let c = sortColumn { rows = Sorter.sort(rows, column: c, descending: descending) }
                return rows
            }.value
            if Task.isCancelled { return }
            self?.importRows = result
            self?.importVersion += 1
        }
    }

    private func scheduleFilterRecompute(delayMs: UInt64) {
        filterTask?.cancel()
        let table = self.table
        let group = settings.filterGroup
        let sortColumn = table.index(of: settings.filterSortColumn)
        let descending = settings.filterSortDescending
        filterTask = Task { [weak self] in
            if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
            if Task.isCancelled { return }
            self?.isFiltering = true
            var issues: [String] = []
            let predicate = FilterCompiler.compile(group, table: table, issues: &issues)
            let result = await Task.detached(priority: .userInitiated) { () -> [SheetRow] in
                var rows = predicate.map { table.rows.filter($0) } ?? table.rows
                if let c = sortColumn { rows = Sorter.sort(rows, column: c, descending: descending) }
                return rows
            }.value
            if Task.isCancelled { return }
            guard let self else { return }
            self.filterRows = result
            self.filterIssues = issues
            self.filterVersion += 1
            self.isFiltering = false
        }
    }

    private func scheduleTriggerCounts(delayMs: UInt64) {
        countsTask?.cancel()
        let table = self.table
        let triggers = settings.buyTriggers
        countsTask = Task { [weak self] in
            if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
            if Task.isCancelled { return }
            var compiled: [(UUID, RowPredicate?)] = []
            for t in triggers {
                var ignored: [String] = []
                compiled.append((t.id, FilterCompiler.compile(t.filter, table: table, issues: &ignored)))
            }
            let counts = await Task.detached(priority: .utility) { () -> [UUID: Int] in
                var out: [UUID: Int] = [:]
                for (id, p) in compiled {
                    out[id] = p.map { pred in table.rows.reduce(0) { $0 + (pred($1) ? 1 : 0) } } ?? 0
                }
                return out
            }.value
            if Task.isCancelled { return }
            self?.triggerMatchCounts = counts
        }
    }

    // MARK: Filter screen columns

    /// Visible columns on the Filter screen, as indices. Default: the trigger column and everything after it.
    var filterColumnIndices: [Int] {
        if !settings.filterColumns.isEmpty {
            var seen = Set<Int>()
            return settings.filterColumns.compactMap { table.index(of: $0) }.filter { seen.insert($0).inserted }
        }
        if let t = table.index(of: settings.triggerColumn) { return Array(t..<headers.count) }
        return Array(headers.indices)
    }

    var labelIndex: Int? {
        table.index(of: settings.labelColumn) ?? (headers.isEmpty ? nil : 0)
    }

    // MARK: Freshness ("is the data updated?")

    /// Newest date found in the chosen date column, if one is set.
    var latestDataDate: Date? {
        guard let col = table.index(of: settings.dateColumn) else { return nil }
        return rows.compactMap { DateParser.parse($0.text(col)) }.max()
    }

    func freshnessInfo(now: Date = Date()) -> FreshnessInfo {
        if lastFetchFailed {
            var detail = errorMessage ?? "Couldn't download the sheet."
            if let checked = freshness.lastCheckedAt {
                detail += " Showing data from \(checked.formatted(date: .abbreviated, time: .shortened))."
            }
            return FreshnessInfo(level: .offline, title: "Can't reach the sheet", detail: detail)
        }

        guard let changed = freshness.lastChangedAt else {
            return FreshnessInfo(level: .waiting, title: "Not imported yet", detail: "Click Import data to download the sheet.")
        }

        var parts = ["\(rows.count) rows × \(headers.count) columns",
                     "new data seen \(changed.formatted(.relative(presentation: .named)))"]
        if let checked = freshness.lastCheckedAt {
            parts.append("last checked \(checked.formatted(date: .omitted, time: .shortened))")
        }

        var level: FreshnessLevel = .fresh
        var title = "Data imported and up to date"

        if now.timeIntervalSince(changed) > Double(settings.staleAfterHours) * 3600 {
            level = .stale
            title = "No new data for over \(settings.staleAfterHours) h"
        }

        if let latest = latestDataDate {
            parts.append("latest row dated \(latest.formatted(date: .abbreviated, time: .omitted))")
        }

        return FreshnessInfo(level: level, title: title, detail: parts.joined(separator: " · "))
    }
}
