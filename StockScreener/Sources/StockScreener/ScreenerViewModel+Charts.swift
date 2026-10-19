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

    func chartURL(_ symbol: String, column: Int? = nil) -> URL? {
        let c = column ?? settings.chartLinkColumn
        let sheetCount = max(1, chartBook.columns.count)
        if c >= sheetCount {
            let extras = settings.extraChartTemplates.filter { !$0.isEmpty }
            let k = c - sheetCount
            if k < extras.count {
                return URL(string: extras[k].replacingOccurrences(of: "{SYMBOL}", with: ChartLinkBook.encode(symbol.uppercased())))
            }
        }
        return chartBook.url(for: symbol, column: min(c, sheetCount - 1), fallbackTemplate: settings.chartFallbackTemplate)
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
