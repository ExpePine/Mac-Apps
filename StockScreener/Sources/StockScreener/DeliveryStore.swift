import Foundation
import SwiftUI

// MARK: - NSE delivery data (sec_bhavdata_full_DDMMYYYY.csv)
//
// One file per trading day from nsearchives.nseindia.com, kept on disk compressed (LZFSE) as
// "SYMBOL,SERIES,CLOSE,TTL_TRD_QNTY,DELIV_QTY,DELIV_PER" lines — the original download is never needed again.
// Days that NSE has no file for (weekends are never asked; holidays return nothing) are remembered so they
// aren't requested again. New days are added every day; old days are kept.

struct DeliveryRow {
    let symbol: String
    let series: String
    let close: Double
    let tradedQty: Double
    let delivQty: Double
    let delivPer: Double
}

enum DeliveryFiles {
    static var folder: URL { AppFolders.folder("Delivery") }
    private static var missingURL: URL { folder.appendingPathComponent("no_file_days.json") }

    static func url(_ day: String) -> URL { folder.appendingPathComponent("\(day).csv.lzfse") }

    /// Stored trading days, oldest first.
    static func days() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".csv.lzfse") }.map { String($0.dropLast(".csv.lzfse".count)) }.sorted()
    }

    static func save(_ rows: [DeliveryRow], day: String) throws {
        var s = "SYMBOL,SERIES,CLOSE,TTL_TRD_QNTY,DELIV_QTY,DELIV_PER\n"
        s.reserveCapacity(rows.count * 48)
        for r in rows {
            s += "\(r.symbol),\(r.series),\(r.close),\(Int(r.tradedQty)),\(Int(r.delivQty)),\(r.delivPer)\n"
        }
        let data = try (Data(s.utf8) as NSData).compressed(using: .lzfse) as Data
        try data.write(to: url(day), options: .atomic)
    }

    static func load(_ day: String) -> [DeliveryRow] {
        guard let d = try? Data(contentsOf: url(day)),
              let raw = try? (d as NSData).decompressed(using: .lzfse) as Data,
              let text = String(data: raw, encoding: .utf8) else { return [] }
        var out: [DeliveryRow] = []
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 6 else { continue }
            out.append(DeliveryRow(symbol: String(f[0]), series: String(f[1]), close: Double(f[2]) ?? 0,
                                   tradedQty: Double(f[3]) ?? 0, delivQty: Double(f[4]) ?? 0, delivPer: Double(f[5]) ?? 0))
        }
        return out
    }

    static func missing() -> Set<String> {
        guard let d = try? Data(contentsOf: missingURL), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(a)
    }
    static func saveMissing(_ s: Set<String>) {
        if let d = try? JSONEncoder().encode(s.sorted()) { try? d.write(to: missingURL, options: .atomic) }
    }

    static func totalBytes() -> Int {
        days().reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: url($1).path))?[.size] as? Int) ?? 0) }
    }
}

enum NSEDeliveryClient {
    enum Result { case rows([DeliveryRow]), noFile, blocked(String) }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 90
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    static func fileName(_ day: String) -> String {
        // "2026-10-19" → "19102026"
        let p = day.split(separator: "-")
        return p.count == 3 ? "\(p[2])\(p[1])\(p[0])" : day
    }

    static func url(_ day: String) -> URL? {
        URL(string: "https://nsearchives.nseindia.com/products/content/sec_bhavdata_full_\(fileName(day)).csv")
    }

    static func fetch(_ day: String) async -> Result {
        guard let u = url(day) else { return .noFile }
        var req = URLRequest(url: u)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("text/csv,*/*", forHTTPHeaderField: "Accept")
        req.setValue("https://www.nseindia.com/", forHTTPHeaderField: "Referer")
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 404 { return .noFile }
                if status == 403 || status == 429 || status >= 500 {
                    try? await Task.sleep(nanoseconds: UInt64(2 + attempt * 3) * 1_000_000_000)
                    if attempt == 2 { return .blocked("NSE answered HTTP \(status)") }
                    continue
                }
                guard status == 200 else { return .noFile }
                let rows = parse(data)
                return rows.isEmpty ? .noFile : .rows(rows)
            } catch {
                if attempt == 2 { return .blocked(error.localizedDescription) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        return .noFile
    }

    /// Reads NSE's CSV by header names (values carry leading spaces; DELIV_QTY is "-" when not available).
    static func parse(_ data: Data) -> [DeliveryRow] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        var lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })[...]
        guard let header = lines.popFirst() else { return [] }
        let h = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        func col(_ names: String...) -> Int? { names.lazy.compactMap { n in h.firstIndex(of: n) }.first }
        guard let sym = col("SYMBOL"), let dq = col("DELIV_QTY") else { return [] }
        let ser = col("SERIES"), cl = col("CLOSE_PRICE", "CLOSE"), tq = col("TTL_TRD_QNTY"), dp = col("DELIV_PER")
        var out: [DeliveryRow] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count > max(sym, dq), let q = Double(f[dq]) else { continue }
            func num(_ i: Int?) -> Double { i.flatMap { $0 < f.count ? Double(f[$0]) : nil } ?? 0 }
            out.append(DeliveryRow(symbol: f[sym].uppercased(), series: ser.map { $0 < f.count ? f[$0] : "" } ?? "",
                                   close: num(cl), tradedQty: num(tq), delivQty: q, delivPer: num(dp)))
        }
        return out
    }
}

// MARK: - Per-symbol series and the "new highest delivery" signal

struct DeliverySeries {
    var days: [String] = []
    var qty: [Double] = []
    var per: [Double] = []
    var close: [Double] = []

    /// What the signal is computed on: DELIV_QTY × CLOSE_PRICE (delivered value, ₹) or DELIV_QTY alone.
    func metric(value: Bool) -> [Double] {
        value ? zip(qty, close).map { $0 * $1 } : qty
    }
}

struct DeliveryBook {
    var days: [String] = []
    var series: [String: DeliverySeries] = [:]

    /// Builds per-symbol series from stored days (EQ preferred when a symbol trades in several series).
    static func build(days: [String], load: (String) -> [DeliveryRow]) -> DeliveryBook {
        var book = DeliveryBook(days: days)
        for d in days {
            var best: [String: DeliveryRow] = [:]
            for r in load(d) {
                if let e = best[r.symbol], e.series == "EQ" || (r.series != "EQ" && e.delivQty >= r.delivQty) { continue }
                best[r.symbol] = r
            }
            for (s, r) in best {
                book.series[s, default: DeliverySeries()].days.append(d)
                book.series[s]!.qty.append(r.delivQty)
                book.series[s]!.per.append(r.delivPer)
                book.series[s]!.close.append(r.close)
            }
        }
        return book
    }
}

enum DeliverySignal {
    /// Rolling highest of `x` over the last `length` bars (like Pine's ta.highest). nil until `length` bars
    /// exist when `full` is on (Pine returns na then); otherwise uses what's there.
    static func highest(_ x: [Double], length: Int, full: Bool) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        var dq: [Int] = []          // indices, values decreasing
        var head = 0
        for i in x.indices {
            while dq.count > head, x[dq[dq.count - 1]] <= x[i] { dq.removeLast() }
            dq.append(i)
            while dq[head] <= i - length { head += 1 }
            if !full || i >= length - 1 { out[i] = x[dq[head]] }
            if head > 4096 { dq.removeFirst(head); head = 0 }
        }
        return out
    }

    /// Bars where ta.highest(DELIV_QTY, length) updates. `onlyRises`: only when it goes UP (a new high);
    /// off = any change, including when an old high leaves the window (exactly `ta.change(...) != 0`).
    static func signals(_ x: [Double], length: Int, full: Bool, onlyRises: Bool) -> [Int] {
        let h = highest(x, length: length, full: full)
        var out: [Int] = []
        for i in 1..<max(1, x.count) {
            guard let a = h[i], let b = h[i - 1] else { continue }
            if onlyRises ? a > b : a != b { out.append(i) }
        }
        return out
    }
}

// MARK: - Shared state (download, daily update, the book)

@MainActor final class DeliveryCenter: ObservableObject {
    static let shared = DeliveryCenter()

    @Published private(set) var book = DeliveryBook()
    @Published private(set) var storedDays: [String] = []
    @Published private(set) var isFetching = false
    @Published private(set) var isLoading = false
    @Published var status: String?
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var revision = 0

    private var task: Task<Void, Never>?
    private var lastAutoCheck = Date.distantPast
    private var loaded = false

    static let istCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
        return c
    }()
    static func key(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = istCalendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func loadIfNeeded() {
        guard !loaded, !isLoading else { return }
        loaded = true
        reload()
    }

    func reload() {
        isLoading = true
        Task {
            let days = DeliveryFiles.days()
            let b = await Task.detached(priority: .userInitiated) { DeliveryBook.build(days: days, load: DeliveryFiles.load) }.value
            self.book = b
            self.storedDays = days
            self.isLoading = false
            self.revision += 1
        }
    }

    /// Weekdays from today back until `target` trading days are covered (holidays allowed for), newest first.
    private func wantedDays(target: Int) -> [String] {
        let have = Set(DeliveryFiles.days()), none = DeliveryFiles.missing()
        var out: [String] = []
        var d = Date()
        var weekdays = 0
        let limit = target + target / 12 + 25                  // ~15 NSE holidays a year
        while weekdays < limit {
            let wd = Self.istCalendar.component(.weekday, from: d)   // 1 = Sunday, 7 = Saturday
            if wd != 1 && wd != 7 {
                weekdays += 1
                let k = Self.key(d)
                if !have.contains(k) && !none.contains(k) { out.append(k) }
            }
            d = Self.istCalendar.date(byAdding: .day, value: -1, to: d) ?? d.addingTimeInterval(-86_400)
        }
        return out
    }

    /// Downloads every missing trading day back to `target` days (first run ≈ 600 files; later runs only new days).
    func download(target: Int = 600) {
        guard !isFetching else { return }
        let todo = wantedDays(target: target)
        guard !todo.isEmpty else { status = "Up to date — \(storedDays.count) days stored."; return }
        isFetching = true
        progress = (0, todo.count)
        status = "Downloading \(todo.count) day\(todo.count == 1 ? "" : "s") from NSE…"
        let today = Self.key(Date())
        task = Task {
            var missing = DeliveryFiles.missing()
            var got = 0, blockedRun = 0
            var blockedMsg: String?
            let width = 4
            var i = 0
            while i < todo.count && !Task.isCancelled {
                let batch = Array(todo[i..<min(i + width, todo.count)])
                i += batch.count
                let results = await withTaskGroup(of: (String, NSEDeliveryClient.Result).self) { g in
                    for d in batch { g.addTask { (d, await NSEDeliveryClient.fetch(d)) } }
                    var r: [(String, NSEDeliveryClient.Result)] = []
                    for await x in g { r.append(x) }
                    return r
                }
                for (d, r) in results {
                    switch r {
                    case .rows(let rows):
                        try? DeliveryFiles.save(rows, day: d)
                        got += 1; blockedRun = 0
                    case .noFile:
                        if d < today { missing.insert(d) }          // today's file may simply not be out yet
                        blockedRun = 0
                    case .blocked(let m):
                        blockedRun += 1; blockedMsg = m
                    }
                }
                self.progress = (i, todo.count)
                self.status = "Downloading from NSE… \(i)/\(todo.count) (\(got) trading days saved)"
                if blockedRun >= 8 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)     // be gentle with NSE
            }
            DeliveryFiles.saveMissing(missing)
            self.isFetching = false
            if blockedRun >= 8 {
                self.status = "NSE stopped answering (\(blockedMsg ?? "blocked")) after \(got) days — try again later; what was saved is kept."
            } else {
                self.status = Task.isCancelled ? "Stopped — \(got) new days saved." : "Done — \(got) new trading day\(got == 1 ? "" : "s") saved."
            }
            self.reload()
        }
    }

    func cancel() { task?.cancel() }

    /// Called from the app's refresh loop: picks up new days once an hour (only after history exists).
    func autoUpdateIfDue() {
        guard !isFetching, Date().timeIntervalSince(lastAutoCheck) > 3600, !DeliveryFiles.days().isEmpty else { return }
        lastAutoCheck = Date()
        download(target: max(600, DeliveryFiles.days().count))
    }
}
