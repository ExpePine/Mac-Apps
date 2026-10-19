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

    func chartURL(_ symbol: String, column: Int? = nil) -> URL? {
        chartBook.url(for: symbol, column: column ?? settings.chartLinkColumn, fallbackTemplate: settings.chartFallbackTemplate)
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
