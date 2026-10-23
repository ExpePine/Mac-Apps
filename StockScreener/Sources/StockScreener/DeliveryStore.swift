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
                guard status == 200 else { return .blocked("NSE answered HTTP \(status)") }
                let rows = parse(data)
                return rows.isEmpty ? .blocked("NSE sent an empty or unreadable file") : .rows(rows)
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

    func metric(_ k: DeliveryMetric) -> [Double] {
        switch k {
        case .value: return metric(value: true)
        case .qty: return qty
        case .sma22: return DeliverySignal.sma(metric(value: true), 22)
        case .sma66: return DeliverySignal.sma(metric(value: true), 66)
        }
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

/// What ta.highest(…, 300) and the charts are computed on.
enum DeliveryMetric: String, CaseIterable, Identifiable {
    case value, qty, sma22, sma66
    var id: String { rawValue }
    var pine: String {
        switch self {
        case .value: return "DELIV_QTY*CLOSE_PRICE"
        case .qty: return "DELIV_QTY"
        case .sma22: return "ta.sma(DELIV_QTY*CLOSE_PRICE, 22)"
        case .sma66: return "ta.sma(DELIV_QTY*CLOSE_PRICE, 66)"
        }
    }
    var short: String {
        switch self {
        case .value: return "Deliv value ₹"
        case .qty: return "DELIV_QTY"
        case .sma22: return "SMA22 value ₹"
        case .sma66: return "SMA66 value ₹"
        }
    }
    static var current: DeliveryMetric { DeliveryMetric(rawValue: UserDefaults.standard.string(forKey: "deliv.metric") ?? "") ?? .value }
}

enum DeliverySignal {
    /// Pine's ta.sma(x, n); the first n − 1 bars (na in Pine) are 0 so they can never be a high.
    static func sma(_ x: [Double], _ n: Int) -> [Double] {
        guard n > 1 else { return x }
        var out = [Double](repeating: 0, count: x.count)
        var sum = 0.0
        for i in x.indices {
            sum += x[i]
            if i >= n { sum -= x[i - n] }
            if i >= n - 1 { out[i] = sum / Double(n) }
        }
        return out
    }

    /// JUMP on bar i of `m` (DELIV_QTY × CLOSE):
    ///  mode 0 — ta.percentrank(m, 300) now ÷ the percent rank's previous peak (its last local high before today)
    ///  mode 1 — m now ÷ the previous different value of ta.highest(m, 300) (how big the new high is vs the old one)
    static func jump(_ m: [Double], at i: Int, mode: Int, length: Int = 300) -> Double? {
        guard i > 0, i < m.count else { return nil }
        if mode == 1 {
            let h = highest(m, length: length, full: true)
            guard let cur = h[i] else { return nil }
            var k = i - 1
            while k >= 0, let v = h[k], v == cur { k -= 1 }
            guard k >= 0, let prev = h[k], prev > 0 else { return nil }
            return m[i] / prev
        }
        var cache: [Int: Double?] = [:]
        func pr(_ j: Int) -> Double? {
            if let c = cache[j] { return c }
            let v = DeliveryColumns.percentRank(m, length: length, at: j)
            cache[j] = v
            return v
        }
        guard let now = pr(i) else { return nil }
        var j = i - 1
        while j >= max(1, i - 2 * length) {           // the previous peak, up to two windows back
            if let v = pr(j), let a = pr(j - 1), let b = pr(j + 1), v >= a, v > b, v > 0 { return now / v }
            j -= 1
        }
        return nil
    }

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

// MARK: - T3 (Tilson) on delivery

/// Pine:  gd(src, length) => ta.ema(src, length) * (1 + factor) - ta.ema(ta.ema(src, length), length) * factor
///        t3 = gd(gd(gd(src, length), length), length);  t3Color = t3 > t3[1] ? green : red
struct T3Def: Equatable {
    var length = 22
    var factor = 1.0
    var useQty = false           // source: DELIV_QTY*CLOSE_PRICE (default) or DELIV_QTY

    var sourceName: String { useQty ? "DELIV_QTY" : "DELIV_QTY*CLOSE_PRICE" }
    var pine: String { "t3(\(sourceName), \(length), factor \(CombiEngine.fmt(factor)))" }

    static var current: T3Def {
        let d = UserDefaults.standard
        var t = T3Def()
        let l = d.integer(forKey: "t3.length"); if l >= 1 { t.length = l }
        if d.object(forKey: "t3.factor") != nil { t.factor = d.double(forKey: "t3.factor") }
        t.useQty = d.bool(forKey: "t3.useQty")
        return t
    }

    func source(_ s: DeliverySeries, upTo i: Int? = nil) -> [Double] {
        let x = useQty ? s.qty : s.metric(value: true)
        guard let i, i < x.count else { return x }
        return Array(x[...i])
    }

    /// Pine's ta.ema: na until `n` values are available, seeded with their SMA, then alpha = 2 / (n + 1).
    /// na inputs (nil) before the first full window are skipped, like nested Pine EMAs.
    static func ema(_ x: [Double?], _ n: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        guard n >= 1 else { return x }
        let a = 2.0 / Double(n + 1)
        var prev: Double?
        var run: [Double] = []
        for i in x.indices {
            guard let v = x[i] else { if prev == nil { run.removeAll() }; out[i] = prev == nil ? nil : prev; continue }
            if let p = prev {
                prev = a * v + (1 - a) * p
            } else {
                run.append(v)
                if run.count > n { run.removeFirst() }
                if run.count == n { prev = run.reduce(0, +) / Double(n) }
            }
            out[i] = prev
        }
        return out
    }

    func gd(_ x: [Double?]) -> [Double?] {
        let e1 = Self.ema(x, length), e2 = Self.ema(e1, length)
        return zip(e1, e2).map { a, b in (a != nil && b != nil) ? a! * (1 + factor) - b! * factor : nil }
    }

    func t3(_ x: [Double]) -> [Double?] { gd(gd(gd(x.map { Optional($0) }))) }

    /// 1 = t3 > t3[1] (green), 0 = otherwise (red), nil = t3 or t3[1] is na. On the last bar of `x`.
    func color(_ x: [Double]) -> Int? {
        let t = t3(x)
        guard t.count >= 2, let a = t[t.count - 1], let b = t[t.count - 2] else { return nil }
        return a > b ? 1 : 0
    }
}

// MARK: - STREAK: consecutive days a condition on ta.percentrank(ta.sma(DELIV_QTY*close, n), length) holds

struct StreakDef: Equatable {
    var sma: Int = 22            // 22 or 66 (0 = follow the Delivery Analysis signal: its SMA, else 22)
    var length: Int = 300
    var op: String = ">"         // > ≥ < ≤
    var value: Double = 99

    /// The SMA actually used (resolves "follow the signal").
    var smaUsed: Int {
        if sma > 1 { return sma }
        switch DeliveryMetric(rawValue: UserDefaults.standard.string(forKey: "deliv.metric") ?? "") {
        case .sma66?: return 66
        default: return 22
        }
    }

    var pine: String { "ta.percentrank(ta.sma(DELIV_QTY*CLOSE_PRICE, \(smaUsed)), \(length)) \(op) \(CombiEngine.fmt(value))" }

    static var current: StreakDef {
        let d = UserDefaults.standard
        var s = StreakDef()
        if d.object(forKey: "streak.sma") != nil { s.sma = d.integer(forKey: "streak.sma") } else { s.sma = 0 }
        let l = d.integer(forKey: "streak.length"); if l >= 2 { s.length = l }
        if let o = d.string(forKey: "streak.op"), [">", "≥", "<", "≤"].contains(o) { s.op = o }
        if d.object(forKey: "streak.value") != nil { s.value = d.double(forKey: "streak.value") }
        return s
    }

    func passes(_ v: Double) -> Bool {
        switch op {
        case "≥": return v >= value
        case "<": return v < value
        case "≤": return v <= value
        default: return v > value
        }
    }

    /// Consecutive bars ending at bar i (the data day) where the condition holds; 0 if it fails at i,
    /// nil when there isn't enough history to compute the percent rank at i (Pine: na).
    func streak(_ x: [Double], at i: Int) -> Int? {
        let n = smaUsed
        guard i < x.count, i >= n - 1 + length else { return nil }
        let sm = DeliverySignal.sma(Array(x[...i]), n)
        let valid = Array(sm[(n - 1)...])
        var k = valid.count - 1, count = 0
        while k >= length, let pr = DeliveryColumns.percentRank(valid, length: length, at: k), passes(pr) {
            count += 1; k -= 1
        }
        return count
    }
}

// MARK: - DLVR and Safety (Filter-table columns)

struct DeliveryColumns {
    let dlvr: Double?        // ₹ Cr of DELIV_QTY×CLOSE on the latest NSE day, only when the 300-day highest updated that day
    let safety: Double?      // ta.sma(DELIV_QTY, 100) × 0.05 (shares)
    var pctRank: Double? = nil   // ta.percentrank(DELIV_QTY, 300) on the latest day (0–100)
    var jump: Double? = nil      // JUMP (see DeliverySignal.jump)
    var delSma: Double? = nil    // DELSMA = ta.percentrank(ta.sma(DELIV_QTY*close, 22 | 66 — as the Delivery signal), 300) (0–100)
    var streak: Int? = nil       // STREAK = consecutive days passing StreakDef (0 = not passing today)
    var t3Color: Int? = nil      // 1 = T3 rising (green), 0 = not rising (red), nil = not enough data
    var hiT3: Double? = nil      // HI/T3 = ta.highest(ta.sma(DELIV_QTY*close, 22|66), 300) / T3
    let day: String          // the stock's latest NSE day

    static var length: Int { let v = UserDefaults.standard.integer(forKey: "deliv.length"); return v < 2 ? 300 : v }
    static var onlyRises: Bool { UserDefaults.standard.object(forKey: "deliv.onlyRises") as? Bool ?? true }
    static var full: Bool { UserDefaults.standard.object(forKey: "deliv.full") as? Bool ?? true }

    /// Values on the NSE day `latestDay` (normally the Filter's data day) — Pine rules: ta.highest(DELIV_QTY*close, 300)
    /// (na until 300 bars), ta.sma(DELIV_QTY, 100) (na until 100 bars), ta.percentrank(DELIV_QTY, 300).
    /// If the stock has no NSE row on that day, everything is unknown (nil).
    static func of(_ s: DeliverySeries, latestDay: String) -> DeliveryColumns {
        guard let i = index(of: latestDay, in: s.days) else {
            return DeliveryColumns(dlvr: nil, safety: nil, pctRank: nil, day: latestDay)
        }
        let m = Array(s.metric(value: true)[...i])
        let sig = DeliverySignal.signals(m, length: length, full: full, onlyRises: onlyRises)
        let dlvr: Double? = sig.last == i ? m[i] / 1e7 : nil
        let safety: Double? = i >= 99 ? s.qty[(i - 99)...i].reduce(0, +) / 100 * 0.05 : nil
        let mode = UserDefaults.standard.integer(forKey: "deliv.jumpMode")
        return DeliveryColumns(dlvr: dlvr, safety: safety, pctRank: percentRank(s.qty, length: 300, at: i),
                               jump: DeliverySignal.jump(m, at: i, mode: mode), delSma: delSma(m, at: i, smaLength: hiSma),
                               streak: StreakDef.current.streak(m, at: i),
                               t3Color: T3Def.current.color(T3Def.current.source(s, upTo: i)),
                               hiT3: hiOverT3(m, t3Source: T3Def.current.source(s, upTo: i)), day: latestDay)
    }

    /// SMA length for HI/T3: follows Delivery Analysis' Signal (66 when ta.sma(…, 66) is picked, else 22).
    static var hiSma: Int { DeliveryMetric(rawValue: UserDefaults.standard.string(forKey: "deliv.metric") ?? "") == .sma66 ? 66 : 22 }

    /// ta.highest(ta.sma(x, n), 300) / t3 on the last bar of x (nil until both exist: n − 1 + 300 bars for the
    /// highest, ~6 × T3 length for T3, like Pine's na; nil when T3 ≤ 0).
    static func hiOverT3(_ x: [Double], t3Source: [Double], sma n: Int = hiSma, length: Int = 300) -> Double? {
        guard x.count >= n - 1 + length else { return nil }
        let sm = DeliverySignal.sma(x, n)
        guard let hi = sm.suffix(length).max(), let t = T3Def.current.t3(t3Source).last ?? nil, t > 0 else { return nil }
        return hi / t
    }

    /// ta.percentrank(ta.sma(x, 22), 300) at bar i — Pine rules: the SMA is na for the first 21 bars, and the
    /// percent rank needs 300 earlier SMA values, so it's nil until bar 21 + 300.
    static func delSma(_ x: [Double], at i: Int, smaLength: Int = 22, length: Int = 300) -> Double? {
        guard i < x.count, i >= smaLength - 1 + length else { return nil }
        let sm = DeliverySignal.sma(Array(x[...i]), smaLength)
        let valid = Array(sm[(smaLength - 1)...])
        return percentRank(valid, length: length, at: valid.count - 1)
    }

    /// Binary search in sorted day keys.
    static func index(of day: String, in days: [String]) -> Int? {
        var lo = 0, hi = days.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if days[mid] == day { return mid }
            if days[mid] < day { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// Pine's ta.percentrank(src, length) on the last bar: % of the previous `length` values that are ≤ the current one
    /// (na until length + 1 bars exist).
    static func percentRank(_ x: [Double], length: Int, at i: Int? = nil) -> Double? {
        let i = i ?? x.count - 1
        guard length > 0, i >= length, i < x.count else { return nil }
        var c = 0
        for k in (i - length)..<i where x[k] <= x[i] { c += 1 }
        return Double(c) / Double(length) * 100
    }

    /// Every stock's values on the stored NSE day closest to (not after) `asOf`.
    static func all(_ b: DeliveryBook, asOf: String? = nil) -> [String: DeliveryColumns] {
        let day = asOf.flatMap { a in b.days.last(where: { $0 <= a }) } ?? b.days.last ?? ""
        var out: [String: DeliveryColumns] = [:]
        for (sym, s) in b.series { out[sym] = of(s, latestDay: day) }
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
    /// Per symbol, for the Filter / Data tables: DLVR (₹ Cr when ta.highest(DELIV_QTY×CLOSE, 300) updated on the
    /// latest NSE day, else nil) and Safety (= ta.sma(DELIV_QTY, 100) × 0.05).
    @Published private(set) var columns: [String: DeliveryColumns] = [:]
    var onReload: (() -> Void)?
    /// NSE trading days (from Yahoo's NIFTY 50 history) — the reference to find gaps in the stored files.
    @Published private(set) var calendar: [String] = []
    private var colCache: (rev: Int, day: String, cols: [String: DeliveryColumns])?
    private var calendarCheckedAt = Date.distantPast

    private static var calendarURL: URL { DeliveryFiles.folder.appendingPathComponent("nse_trading_days.json") }

    /// Trading days with no stored file, between the first stored day and the last trading day.
    var gaps: [String] {
        guard let first = storedDays.first else { return [] }
        let have = Set(storedDays)
        return calendar.filter { $0 >= first && !have.contains($0) }
    }

    /// Recompute the Filter columns (e.g. after changing how JUMP is calculated).
    func refreshColumns() { colCache = nil; onReload?() }

    /// The stored NSE day the Filter columns use for a data day (the same day, or the last one before it).
    func nseDay(asOf: String) -> String? { book.days.last(where: { $0 <= asOf }) }

    /// DLVR / Safety / DQ_PRANK for every stock on the NSE day matching `asOf` (cached per data revision and day).
    func columns(asOf: String) -> [String: DeliveryColumns] {
        let day = nseDay(asOf: asOf) ?? ""
        if let c = colCache, c.rev == revision, c.day == day { return c.cols }
        let cols = DeliveryColumns.all(book, asOf: asOf)
        colCache = (revision, day, cols)
        return cols
    }

    /// Fetches NSE's trading calendar (Yahoo ^NSEI daily bars, 5 years) and keeps it on disk.
    func refreshCalendar() async {
        if calendar.isEmpty, let d = try? Data(contentsOf: Self.calendarURL), let c = try? JSONDecoder().decode([String].self, from: d) { calendar = c }
        guard Date().timeIntervalSince(calendarCheckedAt) > 6 * 3600 else { return }
        calendarCheckedAt = Date()
        guard let s = try? await YahooClient.daily("^NSEI", range: "5y") else { return }
        let merged = Array(Set(calendar).union(s.days)).sorted()
        calendar = merged
        if let d = try? JSONEncoder().encode(merged) { try? d.write(to: Self.calendarURL, options: .atomic) }
    }

    /// Checks the stored days against the trading calendar and downloads any that are missing.
    func repairGaps() {
        Task {
            await refreshCalendar()
            let g = gaps
            guard !g.isEmpty else { status = "Checked against NSE's trading calendar: no missing days (\(storedDays.count) stored)."; return }
            status = "\(g.count) trading day\(g.count == 1 ? "" : "s") missing (e.g. \(g.prefix(3).joined(separator: ", "))) — downloading…"
            download(target: max(600, storedDays.count), extra: g)
        }
    }

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
            let cols = await Task.detached(priority: .userInitiated) { DeliveryColumns.all(b) }.value
            self.book = b
            self.storedDays = days
            self.columns = cols
            self.colCache = nil
            self.isLoading = false
            self.revision += 1
            self.onReload?()
            // once per session: find days missing against the trading calendar and fetch them
            if !self.repairedThisSession, !days.isEmpty {
                self.repairedThisSession = true
                await self.refreshCalendar()
                if !self.gaps.isEmpty && !self.isFetching { self.repairGaps() }
            }
        }
    }
    private var repairedThisSession = false

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
    func download(target: Int = 600, extra: [String] = []) {
        guard !isFetching else { return }
        // Trading days (per the calendar) are never "holidays": forget any that were wrongly marked
        let cal = Set(calendar)
        var none = DeliveryFiles.missing()
        if !cal.isEmpty { let before = none.count; none.subtract(cal); if none.count != before { DeliveryFiles.saveMissing(none) } }
        var todo = wantedDays(target: target)
        let have = Set(DeliveryFiles.days())
        for d in extra + gaps where !have.contains(d) && !todo.contains(d) { todo.append(d) }
        todo.sort(by: >)
        guard !todo.isEmpty else { status = "Up to date — \(storedDays.count) days stored."; return }
        isFetching = true
        progress = (0, todo.count)
        status = "Downloading \(todo.count) day\(todo.count == 1 ? "" : "s") from NSE…"
        let today = Self.key(Date())
        task = Task {
            var missing = DeliveryFiles.missing()
            var got = 0, blockedRun = 0
            var notYet: [String] = []
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
                        // a holiday — unless NSE's calendar says it was a trading day (then try again next time)
                        if d < today && !cal.contains(d) { missing.insert(d) } else { notYet.append(d) }
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
                    + (notYet.filter { $0 < today }.isEmpty ? "" : " NSE has no file yet for \(notYet.filter { $0 < today }.sorted().prefix(4).joined(separator: ", ")) — will retry.")
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
