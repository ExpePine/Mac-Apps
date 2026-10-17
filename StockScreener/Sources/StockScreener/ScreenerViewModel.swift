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
    @Published var settings: AppSettings { didSet { Persistence.save(settings) } }

    @Published private(set) var headers: [String] = []
    @Published private(set) var rows: [SheetRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var freshness: FreshnessState
    @Published private(set) var lastFetchFailed = false
    @Published var errorMessage: String?

    @Published var searchText = ""
    @Published var sortColumn: String?
    @Published var sortAscending = true
    @Published var showOnlyHighlighted = false

    private var refreshTask: Task<Void, Never>?

    init() {
        settings = Persistence.load()
        freshness = Persistence.loadFreshness()
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
            headers = []
            rows = []
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

    func refresh() async {
        guard !settings.sheetLink.isEmpty else { return }
        guard let url = SheetService.csvURL(from: settings.sheetLink) else {
            errorMessage = "Couldn't understand the sheet link. Open Settings and paste it again."
            lastFetchFailed = true
            return
        }
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await SheetService.fetch(from: url)
            let now = Date()
            if result.hash != freshness.dataHash {
                freshness.dataHash = result.hash
                freshness.lastChangedAt = now
            }
            freshness.lastCheckedAt = now
            Persistence.saveFreshness(freshness)

            headers = result.headers
            rows = result.rows
            errorMessage = nil
            lastFetchFailed = false
            if let col = sortColumn, !headers.contains(col) { sortColumn = nil }
        } catch {
            errorMessage = error.localizedDescription   // keep showing the last good data
            lastFetchFailed = true
        }
    }

    // MARK: Freshness ("is the data updated?")

    /// Newest date found in the chosen date column, if one is set.
    var latestDataDate: Date? {
        let col = settings.dateColumn
        guard !col.isEmpty, headers.contains(col) else { return nil }
        return rows.compactMap { DateParser.parse($0.values[col] ?? "") }.max()
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
            return FreshnessInfo(level: .waiting, title: "Waiting for data", detail: "First download in progress…")
        }

        var parts = ["New data seen \(changed.formatted(.relative(presentation: .named)))"]
        if let checked = freshness.lastCheckedAt {
            parts.append("last checked \(checked.formatted(date: .omitted, time: .shortened))")
        }

        var level: FreshnessLevel = .fresh
        var title = "Data is up to date"

        if now.timeIntervalSince(changed) > Double(settings.staleAfterHours) * 3600 {
            level = .stale
            title = "No new data for over \(settings.staleAfterHours) h"
        }

        if let latest = latestDataDate {
            parts.append("latest row dated \(latest.formatted(date: .abbreviated, time: .omitted))")
            if latest < Self.startOfLastWeekday(before: now) {
                level = .stale
                title = "Sheet not updated for the latest trading day"
            }
        }

        return FreshnessInfo(level: level, title: title, detail: parts.joined(separator: " · "))
    }

    /// Start of today, or of the previous Friday on weekends. Exchange holidays are not known.
    private static func startOfLastWeekday(before date: Date) -> Date {
        let cal = Calendar.current
        var day = cal.startOfDay(for: date)
        while cal.isDateInWeekend(day) {
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return day
    }

    // MARK: Filtering, highlighting, sorting

    var displayedRows: [SheetRow] {
        let filters = settings.filterRules.filter { $0.isEnabled && !$0.column.isEmpty }

        var result = rows.filter { row in
            guard !filters.isEmpty else { return true }
            switch settings.matchMode {
            case .all: return filters.allSatisfy { $0.matches(row.values) }
            case .any: return filters.contains { $0.matches(row.values) }
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { row in
                row.values.values.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }

        if showOnlyHighlighted {
            result = result.filter { highlight(for: $0) != nil }
        }

        if let col = sortColumn {
            let asc = sortAscending
            result.sort { a, b in
                let x = a.values[col] ?? "", y = b.values[col] ?? ""
                return asc ? Self.ascending(x, y) : Self.ascending(y, x)
            }
        }
        return result
    }

    /// First enabled highlight rule that matches wins.
    func highlight(for row: SheetRow) -> HighlightColor? {
        settings.highlightRules
            .first { $0.isEnabled && !$0.column.isEmpty && $0.matches(row.values) }?
            .color
    }

    func toggleSort(_ column: String) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    private static func ascending(_ a: String, _ b: String) -> Bool {
        switch (NumberParser.parse(a), NumberParser.parse(b)) {
        case let (x?, y?): return x < y
        case (nil, _?):    return false
        case (_?, nil):    return true
        default:           return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}
