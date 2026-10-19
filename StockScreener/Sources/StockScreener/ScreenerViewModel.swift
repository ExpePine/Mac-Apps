import SwiftUI
import AppKit

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
    private var rawTable = SheetTable()          // as downloaded, before your column names
    @Published private(set) var isLoading = false
    @Published private(set) var freshness: FreshnessState
    @Published private(set) var lastFetchFailed = false
    @Published private(set) var lastFetchInfo: FetchInfo?

    // In-app alerts ("E" rules)
    @Published var inAppAlerts: [InAppAlert] = []
    @Published var showAlertsPopup = false
    @Published var showAlertsBanner = false
    @Published var showRulesEditor = false        // the "E" sheet on the Filter screen
    private var launchAlertDone = false

    // History / animation
    @Published var selectedStock: String?        // stock picked in a table
    // Filter time slider: nil = live data; otherwise an index into timelineDays
    @Published var showTimeline = false
    @Published var timelineDays: [String] = []
    @Published var timelineIndex: Int?
    @Published var timelineTable: SheetTable?
    @Published var isTimelineLoading = false
    @Published var isTimelinePlaying = false
    var timelineCache: [String: SheetTable] = [:]
    var timelineCacheOrder: [String] = []
    var timelinePlayTask: Task<Void, Never>?
    var timelineLoadTask: Task<Void, Never>?

    // Yahoo prices, Top Gainers, neural net, change flash
    @Published var priceBook: PriceBook = PriceStore.load()
    @Published var isFetchingPrices = false
    @Published var priceProgress: (Int, Int) = (0, 0)
    @Published var priceError: String?
    var priceTask: Task<Void, Never>?
    @Published var tgMode = false
    @Published var tgSummary: TGSummary?
    @Published var isTraining = false
    @Published var nnStatus: String?
    @Published var nnError: String?
    @Published var nnReport: NNReport?
    @Published var nnScores: [String: Double] = [:]
    @Published var nnConf: [String: Double] = [:]      // ensemble agreement 0–100 (ranking model)
    @Published var flashSpec: FlashSpec?
    @Published var flashSummary: String?

    // Screenshots (S column), watchlists
    @Published var shotIndex: [String: Date] = ScreenshotStore.index()
    @Published var shotSymbol: String?
    @Published var watchlists: [Watchlist] = WatchlistStore.load() { didSet { WatchlistStore.save(watchlists) } }
    @Published var selectedWatchlistID: UUID?
    @Published var isFetchingWatch = false
    @Published var watchError: String?
    @Published var filterSelection: [SheetRow] = []

    // Changes screen
    @Published var changeResults: [UUID: ChangeResult] = [:]
    @Published var changeCompareDay: String?          // nil = the previous stored day
    @Published var changeComparedDay: String?         // the day actually used
    @Published var changeStatus: String?
    @Published var isComputingChanges = false

    // Performance pane
    @Published var expTable: SheetTable = ExperimentStore.load()
    @Published var expStatus: String?
    @Published var isLoadingExp = false
    @Published var perfResults: [UUID: PerfResult] = [:]
    @Published var perfRunning: UUID?
    @Published var perfStatus: String?
    @Published var perfProgress: (Int, Int) = (0, 0)
    @Published var perfRuns: [PerfRun] = PerfRunStore.loadAll()
    @Published var compareSelection: Set<UUID> = []
    @Published var compareResult: ComparisonResult?
    @Published var isComparing = false

    // Sectors & regime alerts
    @Published var sectorReport: SectorReport?
    @Published var isComputingSectors = false
    @Published var sectorFetch: (Int, Int)?
    @Published var regimeLog: [RegimeLogEntry] = RegimeLogStore.load()
    @Published var regimeLastSeen: Date = (UserDefaults.standard.object(forKey: "StockScreener.regimeLastSeen") as? Date) ?? .distantPast
    @Published var regimeBanner: [RegimeChange] = []

    // Daily gainers
    @Published var indexIntraday: [String: IntradaySeries] = [:]     // ^NSEI, ^BSESN
    @Published var gainersDay: String?                                // nil = latest trading day
    @Published var newsCache = NewsCache.load()
    @Published var isExplaining = false
    @Published var explainProgress: (Int, Int)?
    @Published var newsStatus: String?

    // Chart links & in-app chart viewer
    @Published var chartBook = ChartLinkBook.load()
    @Published var chartSymbol: String?
    @Published var chartQueue: [String] = []        // the list the chart was opened from (for ◀ ▶)
    @Published var chartStatus: String?
    @Published var isImportingCharts = false

    // My picks
    @Published var picks: [Pick] = PickStore.load() { didSet { PickStore.save(picks) } }

    // Manual / hidden symbols
    @Published var symbolBook = SymbolBook.load()
    @Published var isCheckingSymbols = false
    @Published var symbolStatus: String?
    var flashToken = 0

    // E column: per-row status on the Filter screen
    @Published private(set) var eStatus: [Int: EState] = [:]

    // Alerts browser
    @Published var alertEvents: [AlertEvent] = AlertEventStore.load()
    @Published var alertsLastSeen: Date = (UserDefaults.standard.object(forKey: "StockScreener.alertsLastSeen") as? Date) ?? .distantPast
    @Published private(set) var historyDays: [String] = HistoryStore.days()
    @Published private(set) var historyBytes: Int = HistoryStore.totalBytes()
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
    private var appNapActivity: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    @Published private(set) var lastAttemptAt: Date?
    /// Result of the last "Import / Re-import now" click, shown next to the button.
    @Published private(set) var manualResult: (text: String, isNew: Bool, at: Date)?
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
        FindRouter.install()
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
    ///
    /// Robust against macOS App Nap and sleep: instead of one long sleep (which macOS may postpone
    /// for a background app), it wakes every 20 seconds and checks the wall clock.
    func startAutoRefresh() {
        keepAwakeForChecks()
        observeWakeAndActivation()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isRefreshDue(now: Date()) {
                    await self.refresh()
                }
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            }
        }
    }

    /// When the next automatic check should happen.
    var nextCheckDate: Date? {
        guard !settings.sheetLink.isEmpty else { return nil }
        let interval = TimeInterval(max(1, settings.refreshMinutes) * 60)
        let last = max(lastAttemptAt ?? .distantPast, freshness.lastCheckedAt ?? .distantPast)
        return last == .distantPast ? Date() : last.addingTimeInterval(interval)
    }

    private func isRefreshDue(now: Date) -> Bool {
        guard let next = nextCheckDate else { return false }
        return now >= next
    }

    /// Stops App Nap from throttling the timer while still letting the Mac sleep normally.
    private func keepAwakeForChecks() {
        guard appNapActivity == nil else { return }
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Checking the Google Sheet for new data")
    }

    /// Check right after the Mac wakes, and when you switch back to the app if the data is over a minute old.
    private func observeWakeAndActivation() {
        guard wakeObservers.isEmpty else { return }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)   // let Wi-Fi reconnect
                await self?.refresh()
            }
        }
        let active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let last = self.freshness.lastCheckedAt ?? .distantPast
                if Date().timeIntervalSince(last) > 60 { await self.refresh() }
            }
        }
        wakeObservers = [wake, active]
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
        lastAttemptAt = Date()
        defer { isLoading = false }

        do {
            let result = try await SheetService.fetch(from: url)
            let now = Date()
            let src = SheetService.describe(settings.sheetLink)
            let contentChanged = result.hash != freshness.dataHash
            var info = FetchInfo(sourceKind: src.kind, tab: src.tab,
                                 cacheAgeSeconds: result.ageSeconds, lastModified: result.lastModified)
            info.fetchedAt = now
            info.urlUsed = result.urlUsed.absoluteString
            info.endpoint = result.endpoint
            info.httpStatus = result.httpStatus
            info.bytes = result.bytes
            info.rowCount = result.table.rows.count
            info.columnCount = result.table.headers.count
            info.firstRowSample = result.table.rows.first.map { row in
                row.cells.prefix(12).filter { !$0.isEmpty }.prefix(8).joined(separator: " · ")
            } ?? ""
            info.changed = contentChanged
            lastFetchInfo = info
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
            if force {
                let rowsNow = result.table.rows.count
                manualResult = contentChanged
                    ? ("Imported new data · \(rowsNow) rows at \(now.formatted(date: .omitted, time: .standard))", true, now)
                    : ("Downloaded at \(now.formatted(date: .omitted, time: .standard)) — Google's copy is identical to what's shown (unchanged since \((freshness.lastChangedAt ?? now).formatted(date: .omitted, time: .shortened)))", false, now)
            }
            if contentChanged || !hasData || force {
                setTable(result.table)
                adoptColumnSpelling()
            }

            saveSnapshotIfNeeded(raw: result.raw, table: result.table, changed: contentChanged)

            // Alerts run only after the sheet's data has actually been updated.
            if contentChanged {
                await runAlertChecks()
                Task { [weak self] in await self?.sectorDailyUpdate() }
            } else if sectorReport == nil {
                Task { [weak self] in await self?.computeSectors(notify: true) }      // from cached prices
            }
            // In-app alert: once when the app opens (first data), then whenever new data arrives.
            if !launchAlertDone {
                launchAlertDone = true
                raiseInAppAlerts(asPopup: true)
            } else if contentChanged {
                raiseInAppAlerts(asPopup: false)
            }
        } catch {
            errorMessage = error.localizedDescription   // keep showing the last good data
            lastFetchFailed = true
            if force { manualResult = ("Import failed: \(error.localizedDescription)", false, Date()) }
        }
    }

    /// Rebuilds the table from the last download (e.g. after new NN scores).
    func setTableKeepingRaw() { setTable(rawTable) }

    /// Adds the neural net's NN_score column (0–100) when a model has been trained.
    private func withScores(_ t: SheetTable) -> SheetTable {
        guard !nnScores.isEmpty, let label = t.index(of: settings.labelColumn) ?? (t.headers.isEmpty ? nil : 0) else { return t }
        let addConf = !nnConf.isEmpty
        let rows = t.rows.map { row -> SheetRow in
            let key = row.text(label).trimmingCharacters(in: .whitespaces).uppercased()
            let score = nnScores[key]
            var cells = row.cells + [score.map { String(format: "%.1f", $0) } ?? ""]
            var numbers = row.numbers + [score]
            if addConf {
                let c = nnConf[key]
                cells.append(c.map { String(format: "%.0f", $0) } ?? "")
                numbers.append(c)
            }
            return SheetRow(id: row.id, cells: cells, numbers: numbers)
        }
        let extra = addConf ? ["NN_score", "NN_conf"] : ["NN_score"]
        return SheetTable(headers: t.headers + extra, rows: rows, originalHeaders: t.originalHeaders + extra)
    }

    private func setTable(_ downloaded: SheetTable) {
        rawTable = downloaded
        let newTable = withScores(withManualSymbols(downloaded.renamed(with: settings.columnAliases)))
        table = newTable
        if let c = importSortColumn, c >= newTable.headers.count { importSortColumn = nil }
        painter = CellPainter(settings.cellRules, table: newTable)
        clearTimelineCache()
        if let i = timelineIndex { setTimelinePosition(i) }   // re-align the past day to the new columns
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
        if old.columnAliases != settings.columnAliases {
            setTable(rawTable)                            // re-apply names, then re-filter everything
            return
        }
        if old.filterGroup != settings.filterGroup {
            scheduleFilterRecompute(delayMs: 300)        // wait for typing to pause
        } else if old.filterSortColumn != settings.filterSortColumn
                    || old.filterSortDescending != settings.filterSortDescending {
            scheduleFilterRecompute(delayMs: 0)
        }
        if old.tgThreshold != settings.tgThreshold && tgMode {
            scheduleFilterRecompute(delayMs: 200)
        }
        if old.cellRules != settings.cellRules {
            painter = CellPainter(settings.cellRules, table: table)
            filterVersion += 1                           // repaint
        }
        if old.buyTriggers != settings.buyTriggers {
            scheduleTriggerCounts(delayMs: 400)
            scheduleFilterRecompute(delayMs: 300)        // refresh E column colors
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

    func scheduleFilterRecompute(delayMs: UInt64) {
        filterTask?.cancel()
        let table = self.timelineTable ?? self.table      // a past day while the time slider is used
        let group = settings.filterGroup
        let rules = settings.buyTriggers.filter { $0.isEnabled }
        let labelCol = labelIndex
        let tg = tgMode ? tgChanges(for: table, day: displayedDayKey) : nil
        let tgMin = settings.tgThreshold
        let tgDay = displayedDayKey
        let safetyCol = table.index(of: "Safety_limit") ?? table.index(of: "safety limit")
        let sortColumn = table.index(of: settings.filterSortColumn)
        let descending = settings.filterSortDescending
        filterTask = Task { [weak self] in
            if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
            if Task.isCancelled { return }
            self?.isFiltering = true
            var issues: [String] = []
            let predicate = FilterCompiler.compile(group, table: table, issues: &issues)
            let compiledRules = Self.compileRules(rules, table: table)
            let (result, status) = await Task.detached(priority: .userInitiated) { () -> ([SheetRow], [Int: EState]) in
                var rows = predicate.map { table.rows.filter($0) } ?? table.rows
                if let tg { rows = rows.filter { (tg[$0.id]?.0 ?? -.infinity) > tgMin } }
                if let c = sortColumn { rows = Sorter.sort(rows, column: c, descending: descending) }
                let status = Self.eStatuses(rows: rows, rules: compiledRules, labelColumn: labelCol)
                return (rows, status)
            }.value
            if Task.isCancelled { return }
            guard let self else { return }
            if let tg {
                let yahoo = result.filter { tg[$0.id]?.1 == true }.count
                let safety = safetyCol.map { c in result.reduce(0.0) { $0 + ($1.number(c) ?? 0) } }
                self.tgSummary = TGSummary(day: tgDay, count: result.count, safetySum: safety,
                                           fromYahoo: yahoo, fromSheet: result.count - yahoo)
            } else {
                self.tgSummary = nil
            }
            self.filterRows = result
            self.eStatus = status
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
            let compiled = Self.compileRules(triggers, table: table)
            let labelCol = self?.labelIndex
            let counts = await Task.detached(priority: .utility) { () -> [UUID: Int] in
                var out: [UUID: Int] = [:]
                for rule in compiled {
                    out[rule.id] = table.rows.reduce(0) { $0 + (rule.matches($1, labelCol) ? 1 : 0) }
                }
                return out
            }.value
            if Task.isCancelled { return }
            self?.triggerMatchCounts = counts
        }
    }

    // MARK: Daily history (for the animation)

    /// The trading day the data belongs to: from D_MONTH / D_DAY if readable, otherwise today.
    func dataDay(of table: SheetTable, now: Date = Date()) -> Date {
        let cal = Calendar.current
        guard let mi = table.index(of: settings.mv2.monthColumn), let di = table.index(of: settings.mv2.dayColumn) else {
            return now
        }
        var counts: [String: Int] = [:]
        for row in table.rows.prefix(500) {
            guard let m = row.number(mi), let d = row.number(di),
                  (1...12).contains(Int(m)), (1...31).contains(Int(d)) else { continue }
            counts["\(Int(m))-\(Int(d))", default: 0] += 1
        }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else { return now }
        let parts = top.split(separator: "-").compactMap { Int($0) }
        var comps = cal.dateComponents([.year], from: now)
        comps.month = parts[0]; comps.day = parts[1]
        guard var date = cal.date(from: comps) else { return now }
        // December data read in January belongs to last year.
        if date > now.addingTimeInterval(2 * 86400) {
            comps.year = (comps.year ?? 0) - 1
            date = cal.date(from: comps) ?? date
        }
        return date
    }

    private func saveSnapshotIfNeeded(raw: Data, table: SheetTable, changed: Bool) {
        let day = HistoryStore.dayKey(dataDay(of: table))
        guard changed || !HistoryStore.exists(day) else { return }
        let keep = settings.historyKeepForever ? Int.max : max(5, settings.historyKeepDays)
        Task { [weak self] in
            let info = await Task.detached(priority: .utility) { () -> ([String], Int) in
                try? HistoryStore.save(csv: raw, day: day, keepDays: keep)
                return (HistoryStore.days(), HistoryStore.totalBytes())
            }.value
            self?.historyDays = info.0
            self?.historyBytes = info.1
        }
    }

    func refreshHistoryInfo() {
        historyDays = HistoryStore.days()
        historyBytes = HistoryStore.totalBytes()
    }

    /// Loads one stock's stored days (background).
    func loadHistory(for symbol: String) async -> [HistoryStore.Point] {
        let labelOriginal: String = {
            guard let i = labelIndex, i < table.originalHeaders.count else { return "" }
            return table.originalHeaders[i]
        }()
        let originals = table.originalHeaders
        return await Task.detached(priority: .userInitiated) {
            HistoryStore.series(symbol: symbol, labelOriginalHeader: labelOriginal, currentOriginalHeaders: originals)
        }.value
    }

    /// All stock names in today's data (for the picker).
    var allSymbols: [String] {
        guard let i = labelIndex else { return [] }
        return rows.map { $0.text(i).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func selectStock(from row: SheetRow?) {
        guard let row, let i = labelIndex else { return }
        let name = row.text(i).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { selectedStock = name }
    }

    // MARK: Column names

    /// Sheet column names, exactly as in Google Sheets.
    var sheetColumnNames: [String] { rawTable.headers }

    /// Saves your real column names and updates every filter, formula, color rule and trigger to use them.
    func applyColumnNames(_ aliases: [String: String]) {
        var cleaned: [String: String] = [:]
        for (orig, name) in aliases {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty && n != orig { cleaned[orig] = n }
        }
        let before = table
        let after = rawTable.renamed(with: cleaned)

        var pairs: [(old: String, new: String)] = []
        for i in after.headers.indices {
            if i < before.headers.count, before.headers[i] != after.headers[i] {
                pairs.append((before.headers[i], after.headers[i]))
            }
            // References still using the sheet's own name also move to the new name.
            if after.originalHeaders[i] != after.headers[i] {
                pairs.append((after.originalHeaders[i], after.headers[i]))
            }
        }

        var s = ColumnRenamer.rename(settings, pairs: pairs)
        s.columnAliases = cleaned
        settings = s          // didSet re-applies names and re-filters
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
                     "data last changed \(changed.formatted(.relative(presentation: .named)))"]
        if let checked = freshness.lastCheckedAt {
            parts.append("last checked \(checked.formatted(date: .omitted, time: .shortened))")
        }
        if let next = nextCheckDate {
            parts.append(next <= now ? "checking now" : "next check \(next.formatted(date: .omitted, time: .shortened))")
        }
        let src = SheetService.describe(settings.sheetLink)
        parts.append("\(src.kind.lowercased()), \(src.tab)")
        if let age = lastFetchInfo?.cacheAgeSeconds, age > 0 {
            parts.append("Google served a cached copy \(age / 60 > 0 ? "\(age / 60) min" : "\(age) s") old")
        }

        var level: FreshnessLevel = .fresh
        var title = "Data imported"
        if src.isPublished {
            parts.append("published copies can lag the live sheet — use the normal share link for live data")
        }

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
