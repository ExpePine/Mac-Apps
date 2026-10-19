import AppKit
import SwiftUI

extension ScreenerViewModel {

    func importChartLinks() {
        let link = settings.chartSheetLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = SheetService.csvURL(from: link) else { chartStatus = "Paste the chart-links sheet link first."; return }
        isImportingCharts = true
        chartStatus = "Downloading…"
        Task { [weak self] in
            do {
                let result = try await SheetService.fetch(from: url)
                guard let self else { return }
                let book = ChartLinkBook.from(result.table, symbolColumn: self.settings.chartSymbolColumn)
                book.save()
                self.chartBook = book
                self.chartStatus = "\(book.links.count) stocks · link columns: \(book.columns.joined(separator: ", "))"
                    + (book.templates.first.map { $0.isEmpty ? "" : " · pattern learned for other stocks" } ?? "")
            } catch {
                self?.chartStatus = "Couldn't download: \(error.localizedDescription)"
            }
            self?.isImportingCharts = false
        }
    }

    /// Chart 1, Chart 2… = the sheet's link columns, then any extra layouts from Chart settings.
    var chartCount: Int { max(1, chartBook.columns.count) + settings.extraChartTemplates.filter { !$0.isEmpty }.count }

    func chartName(_ i: Int) -> String {
        if i < chartBook.columns.count { return chartBook.columns[i] }
        return i < max(1, chartBook.columns.count) ? "Link1" : "Extra layout \(i - max(1, chartBook.columns.count) + 1)"
    }

    func chartURL(_ symbol: String, column: Int? = nil) -> URL? { chartSource(symbol, column: column).url }

    /// The link a chart opens and where it came from (shown under the chart so Chart 1 / Chart 2 can be checked).
    func chartSource(_ symbol: String, column: Int? = nil) -> (url: URL?, from: String) {
        let c = column ?? settings.chartLinkColumn
        let sym = SymbolBook.clean(symbol)
        if let m = symbolBook.manual.first(where: { $0.symbol == sym }), c < m.links.count,
           !m.links[c].trimmingCharacters(in: .whitespaces).isEmpty, let u = URL(string: m.links[c].trimmingCharacters(in: .whitespaces)) {
            return (u, "your link in Symbols")
        }
        let sheetCount = max(1, chartBook.columns.count)
        if c >= sheetCount {
            let extras = settings.extraChartTemplates.filter { !$0.isEmpty }
            let k = c - sheetCount
            if k < extras.count {
                return (URL(string: extras[k].replacingOccurrences(of: "{SYMBOL}", with: ChartLinkBook.encode(symbol.uppercased()))),
                        "Extra layout \(k + 1) (Chart settings)")
            }
        }
        let col = min(c, sheetCount - 1)
        let name = col < chartBook.columns.count ? chartBook.columns[col] : "Link1"
        let own = chartBook.links[sym].map { col < $0.count && !$0[col].isEmpty } ?? false
        var u = chartBook.url(for: symbol, column: col, fallbackTemplate: settings.chartFallbackTemplate)
        var from = own ? "sheet column \(name)" : "\(name) pattern"
        if let id = settings.chartLayoutOverride[name], !id.isEmpty, let s = u?.absoluteString {
            u = URL(string: ChartLinkBook.withLayout(s, id))
            from += ", layout set to \(id) for all stocks"
        }
        return (u, from)
    }

    /// For a sheet column whose links mostly repeat Chart 1's layout: another layout found in it (to use for every stock).
    func suggestedLayout(column c: Int) -> String? {
        guard c > 0, c < chartBook.columns.count,
              (settings.chartLayoutOverride[chartBook.columns[c]] ?? "").isEmpty else { return nil }
        let first = Set(chartBook.layouts(column: 0).prefix(1).map(\.id))
        return chartBook.layouts(column: c).map(\.id).first { !first.contains($0) && !$0.isEmpty }
    }

    /// Charts whose TradingView layout is the same as an earlier chart's (so they would look identical).
    func duplicateChartLayouts(for symbol: String) -> [Int: Int] {
        var seen: [String: Int] = [:], dup: [Int: Int] = [:]
        for i in 0..<chartCount {
            guard let u = chartURL(symbol, column: i)?.absoluteString else { continue }
            let id = ChartLinkBook.layoutID(u)
            if let first = seen[id] { dup[i] = first } else { seen[id] = i }
        }
        return dup
    }

    /// Turns a pasted chart link for any stock into a pattern: …symbol=NSE%3ATCS → …symbol=NSE%3A{SYMBOL}.
    static func templateFromLink(_ link: String) -> String {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("{SYMBOL}") else { return t }
        for marker in ["NSE%3A", "NSE:", "BSE%3A", "BSE:"] {
            if let r = t.range(of: marker) {
                let rest = t[r.upperBound...]
                let end = rest.firstIndex(where: { $0 == "&" || $0 == "#" || $0 == "/" }) ?? rest.endIndex
                return t.replacingCharacters(in: r.upperBound..<end, with: "{SYMBOL}")
            }
        }
        return t
    }

    /// Re-reads the chart-links sheet if it's older than 30 minutes (picks up new Link2… columns).
    func refreshChartLinksIfStale() {
        guard !settings.chartSheetLink.isEmpty, !isImportingCharts,
              Date().timeIntervalSince(chartBook.importedAt) > 1800 else { return }
        importChartLinks()
    }

    /// Opens a stock's chart (in the app's chart window, or the browser). `queue` = the list for ◀ ▶.
    func openChart(_ symbol: String, queue: [String] = [], openWindow: OpenWindowAction) {
        let sym = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !sym.isEmpty else { return }
        if !queue.isEmpty { chartQueue = queue.map { $0.uppercased() } } else if !chartQueue.contains(sym) { chartQueue = [sym] }
        if settings.chartOpenInApp {
            chartSymbol = sym
            openWindow(id: "chart")
        } else if let u = chartURL(sym) {
            NSWorkspace.shared.open(u)
        }
    }

    func stepChart(_ delta: Int) {
        guard let s = chartSymbol, let i = chartQueue.firstIndex(of: s) else { return }
        let j = i + delta
        guard chartQueue.indices.contains(j) else { return }
        chartSymbol = chartQueue[j]
    }

    /// Saves an image as a dated screenshot of the stock (shows in the S column / Screenshots window).
    func saveChartSnapshot(_ image: NSImage, symbol: String) {
        do {
            let shot = try ScreenshotStore.save(image, symbol: symbol)
            refreshShotIndex()
            chartStatus = "Saved to \(symbol)'s screenshots · \(shot.date.formatted(date: .omitted, time: .shortened))"
        } catch {
            chartStatus = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
