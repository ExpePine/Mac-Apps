import Foundation
import SwiftUI

// MARK: - Earnings (results) dates from NSE → the EARNINGS column
//
// EARNINGS = days from the results board meeting to the data day:
//   −10 = results in 10 days (still to come) · 0 = results today · +10 = results were 10 days ago.
// A stock with an announced upcoming results meeting shows that one; otherwise its latest past one.
// EARN_DATE = that meeting's date.
//
// Sources (unofficial NSE web APIs — they need NSE's cookies, may change or be blocked):
//   https://www.nseindia.com/api/event-calendar?index=equities&from_date=dd-MM-yyyy&to_date=dd-MM-yyyy
//   https://www.nseindia.com/api/corporate-board-meetings?index=equities&from_date=…&to_date=…
// Only meetings whose purpose mentions results / financial results are used.

struct EarningsEvent: Codable, Hashable {
    let symbol: String
    let day: String          // yyyy-MM-dd
    let purpose: String
}

@MainActor final class EarningsCenter: ObservableObject {
    static let shared = EarningsCenter()
    @Published private(set) var bySymbol: [String: [EarningsEvent]] = [:]   // sorted by day
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var busy = false
    @Published var status: String?
    var onReload: (() -> Void)?

    private struct Saved: Codable { var events: [EarningsEvent]; var fetchedAt: Date }
    private static var url: URL { AppFolders.base.appendingPathComponent("earnings_calendar.json") }
    private static let api: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "dd-MM-yyyy"; return f
    }()

    private init() {
        if let d = try? Data(contentsOf: Self.url), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            bySymbol = Self.group(s.events); fetchedAt = s.fetchedAt
        }
    }

    var eventCount: Int { bySymbol.values.reduce(0) { $0 + $1.count } }
    var summary: String {
        guard let f = fetchedAt else { return "not downloaded yet" }
        return "\(bySymbol.count) companies · \(eventCount) results dates · updated \(f.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Once a day (and the first time).
    func refreshIfDue() {
        guard !busy else { return }
        if let f = fetchedAt, Calendar.current.isDateInToday(f) { return }
        refresh()
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        status = "Downloading results dates from NSE…"
        Task {
            let res = await Self.download()
            busy = false
            if res.events.isEmpty {
                status = "No results dates from NSE" + (res.errors.isEmpty ? "" : " — " + res.errors.joined(separator: " · "))
                return
            }
            bySymbol = Self.group(res.events)
            fetchedAt = Date()
            status = nil
            if let d = try? JSONEncoder().encode(Saved(events: res.events, fetchedAt: Date())) { try? d.write(to: Self.url, options: .atomic) }
            onReload?()
        }
    }

    private static func group(_ ev: [EarningsEvent]) -> [String: [EarningsEvent]] {
        var m: [String: [EarningsEvent]] = [:]
        for e in Set(ev) { m[e.symbol, default: []].append(e) }
        for k in m.keys { m[k]!.sort { $0.day < $1.day } }
        return m
    }

    func value(_ symbol: String, on day: String) -> (days: Int, date: String)? {
        guard let ev = bySymbol[symbol.uppercased()] else { return nil }
        return EarningsMath.pick(ev, on: day)
    }

    // MARK: Download

    private static func download() async -> (events: [EarningsEvent], errors: [String]) {
        let now = Date()
        let from = now.addingTimeInterval(-150 * 86_400), to = now.addingTimeInterval(120 * 86_400)
        var out: [EarningsEvent] = [], errors: [String] = []
        let sources: [(String, String)] = [
            ("event-calendar", "https://www.nseindia.com/companies-listing/corporate-filings-event-calendar"),
            ("corporate-board-meetings", "https://www.nseindia.com/companies-listing/corporate-filings-board-meetings"),
        ]
        for (path, referer) in sources {
            // whole range first; if NSE refuses a long range, month by month
            var got = await fetch(path, referer: referer, from: from, to: to)
            if got.events.isEmpty {
                var a = from
                var chunk: [EarningsEvent] = []
                while a < to {
                    let b = min(to, a.addingTimeInterval(30 * 86_400))
                    let r = await fetch(path, referer: referer, from: a, to: b)
                    chunk += r.events
                    if r.error != nil && chunk.isEmpty { got.error = r.error; break }
                    a = b.addingTimeInterval(86_400)
                }
                if !chunk.isEmpty { got = (chunk, nil) }
            }
            out += got.events
            if let e = got.error, got.events.isEmpty { errors.append("\(path): \(e)") }
        }
        return (out, errors)
    }

    private static func fetch(_ path: String, referer: String, from: Date, to: Date) async -> (events: [EarningsEvent], error: String?) {
        guard let url = URL(string: "https://www.nseindia.com/api/\(path)?index=equities&from_date=\(api.string(from: from))&to_date=\(api.string(from: to))") else { return ([], "bad url") }
        do {
            let obj = try await NSEDealsClient.json(url, referer: referer)
            let rows = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            return (rows.compactMap(EarningsMath.parse), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

}

enum EarningsMath {
    static let iso: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// The results meeting that matters on `day`: the next upcoming one, else the latest past one.
    /// Returns (signed days: negative = to go, positive = past, the meeting's date).
    static func pick(_ events: [EarningsEvent], on day: String) -> (days: Int, date: String)? {
        guard let today = iso.date(from: day) else { return nil }
        let next = events.first { $0.day >= day }
        guard let e = next ?? events.last(where: { $0.day < day }), let d = iso.date(from: e.day) else { return nil }
        let n = Int((today.timeIntervalSince(d) / 86_400).rounded())
        return (n, e.day)
    }

    /// One NSE row → a results meeting (nil for other purposes: dividends, fund raising…).
    static func parse(_ r: [String: Any]) -> EarningsEvent? {
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = r[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v } }
            return nil
        }
        guard let sym = str(["symbol", "bm_symbol", "sm_symbol"])?.trimmingCharacters(in: .whitespaces).uppercased(),
              let rawDate = str(["date", "bm_date", "meetingDate", "bm_timestamp"]) else { return nil }
        let purpose = str(["purpose", "bm_purpose", "bm_desc", "desc"]) ?? ""
        let p = purpose.lowercased()
        guard p.contains("result") || p.contains("financial") else { return nil }
        guard let day = normalise(rawDate) else { return nil }
        return EarningsEvent(symbol: sym, day: day, purpose: purpose)
    }

    /// "12-Nov-2026", "12-Nov-2026 10:30:00", "12-11-2026", "2026-11-12" → "2026-11-12".
    static func normalise(_ s: String) -> String? {
        let t = String(s.trimmingCharacters(in: .whitespaces).prefix(11)).trimmingCharacters(in: .whitespaces)
        for f in ["dd-MMM-yyyy", "dd-MM-yyyy", "yyyy-MM-dd", "dd MMM yyyy"] {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "Asia/Kolkata"); df.dateFormat = f
            if let d = df.date(from: t) { return iso.string(from: d) }
        }
        return nil
    }
}


/// Settings row: EARNINGS column status + "Update now".
struct EarningsSettingsRow: View {
    @ObservedObject private var ec = EarningsCenter.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("EARNINGS — days to (−) / since (+) results, from NSE:").font(.callout)
                Text(ec.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if ec.busy { ProgressView().controlSize(.small) }
                Button("Update now") { ec.refresh() }.disabled(ec.busy)
            }
            if let s = ec.status { Text(s).font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }
    }
}
