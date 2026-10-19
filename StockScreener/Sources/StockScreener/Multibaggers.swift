import Foundation
import SwiftUI

// MARK: - Multibaggers: stocks that gained ≥ 30% in a calendar month (Yahoo closes, Jan 2023 → now)
//
// Gain for month M = close on M's last trading day ÷ close on the previous month's last trading day − 1
// (or, with "use the month's best close", the highest close in M instead of the last one).
// Each event keeps the dates you may want a chart centred on: the move's start, the day it crossed the
// threshold, the peak day and the month's last day.

struct MBEvent: Identifiable, Hashable {
    var id: String { symbol + "|" + month }
    let symbol: String
    let month: String           // "2024-03"
    let gain: Double            // %
    let peakGain: Double        // % at the best close in the month
    let baseDay: String         // previous month's last trading day (the base close)
    let startDay: String        // first trading day of the month
    let crossDay: String        // first day the close was ≥ threshold above the base
    let peakDay: String
    let endDay: String          // last trading day of the month

    func day(for center: MBCenter) -> String {
        switch center {
        case .start: return startDay
        case .cross: return crossDay
        case .peak: return peakDay
        case .end: return endDay
        }
    }

    var monthTitle: String { MBEngine.monthTitle(month) }
}

enum MBCenter: String, CaseIterable, Identifiable {
    case start = "Start of the month", cross = "Day it crossed the threshold", peak = "Peak day", end = "End of the month"
    var id: String { rawValue }
}

enum MBEngine {
    static func monthTitle(_ m: String) -> String {
        let p = m.split(separator: "-")
        guard p.count == 2, let mi = Int(p[1]), (1...12).contains(mi) else { return m }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[mi - 1]) \(p[0])"
    }

    /// Every (stock, month) from `fromMonth` with a gain ≥ `threshold` %.
    static func events(_ book: PriceBook, threshold: Double, fromMonth: String, usePeak: Bool) -> [MBEvent] {
        var out: [MBEvent] = []
        for (sym, s) in book.series where !sym.hasPrefix("^") {
            // month → indices
            var months: [(String, Range<Int>)] = []
            var i = 0
            while i < s.days.count {
                let m = String(s.days[i].prefix(7))
                var j = i
                while j < s.days.count && s.days[j].hasPrefix(m) { j += 1 }
                months.append((m, i..<j))
                i = j
            }
            for k in 1..<max(1, months.count) {
                let (m, r) = months[k]
                guard m >= fromMonth else { continue }
                let baseIdx = months[k - 1].1.upperBound - 1
                let base = s.closes[baseIdx]
                guard base > 0, !r.isEmpty else { continue }
                let end = s.closes[r.upperBound - 1]
                var peakIdx = r.lowerBound
                for x in r where s.closes[x] > s.closes[peakIdx] { peakIdx = x }
                let gain = (end / base - 1) * 100
                let peakGain = (s.closes[peakIdx] / base - 1) * 100
                guard (usePeak ? peakGain : gain) >= threshold else { continue }
                let cross = r.first { (s.closes[$0] / base - 1) * 100 >= threshold } ?? peakIdx
                out.append(MBEvent(symbol: sym, month: m, gain: gain, peakGain: peakGain, baseDay: s.days[baseIdx],
                                   startDay: s.days[r.lowerBound], crossDay: s.days[cross], peakDay: s.days[peakIdx],
                                   endDay: s.days[r.upperBound - 1]))
            }
        }
        return out.sorted { $0.month != $1.month ? $0.month > $1.month : (usePeak ? $0.peakGain > $1.peakGain : $0.gain > $1.gain) }
    }
}

/// Long Yahoo history for multibagger scans (kept separately from the 1-year price book), compressed on disk.
@MainActor final class MultibaggerCenter: ObservableObject {
    static let shared = MultibaggerCenter()

    @Published private(set) var book = PriceBook()
    @Published private(set) var events: [MBEvent] = []
    @Published private(set) var isFetching = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published var status: String?

    // Set in the Multibaggers window (@AppStorage there); read here.
    var threshold: Double { let v = UserDefaults.standard.double(forKey: "mb.threshold"); return v == 0 ? 30 : v }
    var fromMonth: String { UserDefaults.standard.string(forKey: "mb.from") ?? "2023-01" }
    var usePeak: Bool { UserDefaults.standard.bool(forKey: "mb.usePeak") }
    var center: MBCenter { MBCenter(rawValue: UserDefaults.standard.string(forKey: "mb.center") ?? "") ?? .start }
    private var loaded = false
    private var task: Task<Void, Never>?

    nonisolated private static var url: URL { AppFolders.base.appendingPathComponent("multibagger_prices.json.lzfse") }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        Task {
            let b = await Task.detached(priority: .userInitiated) { () -> PriceBook in
                guard let d = try? Data(contentsOf: Self.url),
                      let raw = try? (d as NSData).decompressed(using: .lzfse) as Data,
                      let b = try? JSONDecoder().decode(PriceBook.self, from: raw) else { return PriceBook() }
                return b
            }.value
            self.book = b
            self.recompute()
        }
    }

    private func save() {
        let b = book
        Task.detached(priority: .utility) {
            guard let d = try? JSONEncoder().encode(b), let c = try? (d as NSData).compressed(using: .lzfse) as Data else { return }
            try? FileManager.default.createDirectory(at: AppFolders.base, withIntermediateDirectories: true)
            try? c.write(to: Self.url, options: .atomic)
        }
    }

    func recompute() {
        let b = book, t = threshold, f = fromMonth, p = usePeak
        Task {
            let e = await Task.detached(priority: .userInitiated) { MBEngine.events(b, threshold: t, fromMonth: f, usePeak: p) }.value
            self.events = e
        }
    }

    /// Downloads Yahoo history for `symbols`: 5 years the first time (kept from two months before `fromMonth`),
    /// then only the last 3 months, merged into what's stored.
    func fetch(_ symbols: [String]) {
        guard !isFetching, !symbols.isEmpty else { return }
        isFetching = true
        let fresh = Set(symbols.map { $0.uppercased() }).subtracting(book.series.keys)
        let update = Set(symbols.map { $0.uppercased() }).intersection(book.series.keys)
        status = "Yahoo: \(fresh.count) new stock\(fresh.count == 1 ? "" : "s") (5 years), \(update.count) to update…"
        let keepFrom = Self.monthBefore(fromMonth, 2) + "-01"
        task = Task {
            var b = self.book
            var failedAll: [String] = []
            for (list, range) in [(Array(fresh), "5y"), (Array(update), "3mo")] where !list.isEmpty {
                let (got, failed) = await YahooClient.fetchAll(list, range: range) { d, t in
                    MultibaggerCenter.shared.progress = (d, t)
                }
                failedAll += failed
                for (sym, s) in got.series {
                    let trimmed = Self.trim(s, from: keepFrom)
                    b.series[sym] = b.series[sym].map { $0.merged(with: trimmed) } ?? trimmed
                }
                if Task.isCancelled { break }
            }
            b.fetchedAt = Date()
            self.book = b
            self.save()
            self.isFetching = false
            self.status = "\(b.series.count) stocks with history" + (failedAll.isEmpty ? "" : " · \(failedAll.count) not on Yahoo (e.g. \(failedAll.prefix(4).joined(separator: ", ")))")
            self.recompute()
        }
    }

    func cancel() { task?.cancel() }

    nonisolated static func trim(_ s: PriceSeries, from day: String) -> PriceSeries {
        guard let i = s.days.firstIndex(where: { $0 >= day }) else { return s }
        return PriceSeries(days: Array(s.days[i...]), closes: Array(s.closes[i...]))
    }

    nonisolated static func monthBefore(_ m: String, _ n: Int) -> String {
        let p = m.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return m }
        var y = p[0], mo = p[1] - n
        while mo < 1 { mo += 12; y -= 1 }
        return String(format: "%04d-%02d", y, mo)
    }

    var months: [String] { Array(Set(events.map(\.month))).sorted(by: >) }
}
