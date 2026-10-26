import Foundation

// MARK: - 5-minute data (Yahoo) + MOR / DAY
//
// Pine equivalent (daily chart, request.security_lower_tf "5"):
//   changer = ta.change(close, 1) on the 5-minute bars (rupees; the first bar of a day vs the previous day's last bar)
//   bR    = average changer per 30-minute bucket from 09:15 IST;  src = bR[0] (09:15–09:45)
//   MOR   = rank of src among the last `len` (300) valid src values incl. today: 100 × count(≤ src) / size
//   bRpr  = average changer per 10-minute bucket (38 buckets in 375 minutes)
//   prs[k]= rank of today's bucket k vs the PREVIOUS days' bucket k (last prLen = 300 days, na skipped), na until
//           minHist (20) days; the bucket still forming on a live day is skipped
//   prSum = Σ prs[k];  DAY = ta.percentrank(prSum, 300)
// Yahoo serves only ~60 days of 5-minute history, so the store keeps every day it has fetched and grows daily.
// Until 300 earlier days exist, DAY ranks prSum against the days available (needs ≥ 20) — Pine would show na.

struct Bars5m {
    var t: [Int32] = []          // bar start, unix seconds
    var c: [Float] = []          // close

    mutating func merge(_ o: Bars5m) {
        var map: [Int32: Float] = [:]
        for (a, b) in zip(t, c) { map[a] = b }
        for (a, b) in zip(o.t, o.c) { map[a] = b }
        let keys = map.keys.sorted()
        t = keys; c = keys.map { map[$0]! }
    }

    mutating func keepLast(days: Int) {
        guard let last = t.last else { return }
        let cut = last - Int32(days) * 86_400 * 7 / 5          // ≈ trading days → calendar days
        if let i = t.firstIndex(where: { $0 >= cut }), i > 0 { t.removeFirst(i); c.removeFirst(i) }
    }

    var data: Data {
        var d = Data()
        var n = UInt32(t.count)
        d.append(Data(bytes: &n, count: 4))
        t.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        c.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    init() {}
    init?(_ d: Data) {
        guard d.count >= 4 else { return nil }
        let n = Int(d.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard d.count == 4 + n * 8 else { return nil }
        t = d.subdata(in: 4..<(4 + n * 4)).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        c = d.subdata(in: (4 + n * 4)..<(4 + n * 8)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

enum Bars5mFiles {
    static var folder: URL { AppFolders.folder("intraday5m") }
    static func url(_ s: String) -> URL { folder.appendingPathComponent(s.replacingOccurrences(of: "/", with: "_") + ".5m.lzfse") }
    static func load(_ s: String) -> Bars5m? {
        guard let d = try? Data(contentsOf: url(s)), let raw = try? (d as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return Bars5m(raw)
    }
    static func save(_ s: String, _ b: Bars5m) {
        if let c = try? (b.data as NSData).compressed(using: .lzfse) as Data { try? c.write(to: url(s), options: .atomic) }
    }
    static func symbols() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".5m.lzfse") }.map { String($0.dropLast(".5m.lzfse".count)) }
    }
    static func totalBytes() -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

extension YahooClient {
    /// 5-minute bars (start time, close). range: "60d" (Yahoo's limit for 5m) or e.g. "5d".
    static func bars5m(_ symbol: String, range: String) async throws -> Bars5m {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol(symbol))?range=\(range)&interval=5m") else { throw Failure(message: "Bad symbol") }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw Failure(message: "rate-limited") }
        guard (200..<300).contains(status), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let stamps = result["timestamp"] as? [Double],
              let closes = (((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first?["close"] as? [Any]) else {
            throw Failure(message: "no data")
        }
        var b = Bars5m()
        for (i, s) in stamps.enumerated() where i < closes.count {
            if let v = closes[i] as? Double, v > 0 { b.t.append(Int32(s)); b.c.append(Float(v)) }
        }
        return b
    }
}

enum MorDay {
    struct Params {
        var bucketMin = 30, bucketMinPr = 10, sessStart = 9 * 60 + 15, sessLen = 375
        var len = 300, prLen = 300, minHist = 20, dayLen = 300
        var ltfMin = 5
    }
    private static let ist = TimeZone(identifier: "Asia/Kolkata")!

    static func dayKey(_ t: Int32) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = ist; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    /// Per day: (day, session start unix, bar indices) in order. IST = UTC+5:30 (no daylight saving).
    static func days(_ b: Bars5m, p: Params) -> [(day: String, start: Int, idx: Range<Int>)] {
        var out: [(String, Int, Range<Int>)] = []
        let off = 19_800
        var i = 0
        while i < b.t.count {
            let dn = (Int(b.t[i]) + off) / 86_400
            var j = i
            while j < b.t.count && (Int(b.t[j]) + off) / 86_400 == dn { j += 1 }
            let start = dn * 86_400 - off + p.sessStart * 60
            out.append((dayKey(Int32(dn * 86_400 - off + 43_200)), start, i..<j))
            i = j
        }
        return out
    }

    /// Average changer per bucket for one day (nil = no bar in the bucket).
    static func buckets(_ b: Bars5m, _ day: (day: String, start: Int, idx: Range<Int>), bucketMin: Int, p: Params, skip: Int? = nil) -> [Double?] {
        let n = Int((Double(p.sessLen) / Double(bucketMin)).rounded(.up))
        let bSec = bucketMin * 60
        var sum = [Double](repeating: 0, count: n), cnt = [Int](repeating: 0, count: n)
        for i in day.idx where i > 0 {
            let t = Int(b.t[i])
            var k = Int(floor(Double(t - day.start) / Double(bSec)))
            if k < 0 && t + p.ltfMin * 60 > day.start { k = 0 }
            guard k >= 0, k < n else { continue }
            sum[k] += Double(b.c[i] - b.c[i - 1]); cnt[k] += 1          // changer = ta.change(close, 1)
        }
        return (0..<n).map { k in (cnt[k] > 0 && k != skip) ? sum[k] / Double(cnt[k]) : nil }
    }

    /// MOR and DAY on `asOf` (or the last day with bars on or before it). `liveBucket` = 10-min bucket still forming.
    static func compute(_ b: Bars5m, asOf: String, p: Params = Params(), liveBucket: Int? = nil) -> (mor: Double?, day: Double?) {
        let ds = days(b, p: p).filter { $0.day <= asOf }
        guard let last = ds.last, last.day == asOf else { return (nil, nil) }
        // MOR: first 30-min bucket ranked among the last `len` valid values (today included)
        var srcs: [Double] = []
        for d in ds { if let v = buckets(b, d, bucketMin: p.bucketMin, p: p).first ?? nil { srcs.append(v) } }
        var mor: Double? = nil
        if let today = buckets(b, last, bucketMin: p.bucketMin, p: p).first ?? nil {
            let arr = srcs.suffix(p.len)
            mor = 100 * Double(arr.filter { $0 <= today }.count) / Double(arr.count)
        }
        // DAY: prSum for every day (bucket ranks vs previous days, sorted columns for speed), then its percent rank
        let nPr = Int((Double(p.sessLen) / Double(p.bucketMinPr)).rounded(.up))
        var cols = [[Double]](repeating: [], count: nPr)           // sorted values of the last prLen days
        var window: [[Double?]] = []                               // rows in order (to drop the oldest)
        var prSums: [(day: String, sum: Double)] = []
        for (di, d) in ds.enumerated() {
            let isLast = di == ds.count - 1
            let row = buckets(b, d, bucketMin: p.bucketMinPr, p: p)
            var sum = 0.0, cnt = 0
            for k in 0..<nPr {
                if isLast, let lk = liveBucket, k == lk { continue }
                guard let v = row[k], cols[k].count >= p.minHist else { continue }
                // count of previous values ≤ v (upper bound by binary search)
                var lo = 0, hi = cols[k].count
                while lo < hi { let m = (lo + hi) / 2; if cols[k][m] <= v { lo = m + 1 } else { hi = m } }
                sum += 100 * Double(lo) / Double(cols[k].count); cnt += 1
            }
            if cnt > 0 { prSums.append((d.day, sum)) }
            // store today after ranking, keep the last prLen days
            window.append(row)
            for k in 0..<nPr { if let v = row[k] { let i = cols[k].firstIndex { $0 > v } ?? cols[k].count; cols[k].insert(v, at: i) } }
            if window.count > p.prLen {
                let old = window.removeFirst()
                for k in 0..<nPr { if let v = old[k], let i = cols[k].firstIndex(of: v) { cols[k].remove(at: i) } }
            }
        }
        var dayRank: Double? = nil
        if let lastSum = prSums.last, lastSum.day == asOf {
            let prev = prSums.dropLast().suffix(p.dayLen).map(\.sum)
            if prev.count >= p.minHist { dayRank = 100 * Double(prev.filter { $0 <= lastSum.sum }.count) / Double(prev.count) }
        }
        return (mor, dayRank)
    }
}

@MainActor final class Intraday5mCenter: ObservableObject {
    static let shared = Intraday5mCenter()
    @Published private(set) var busy = false
    @Published private(set) var progress: (Int, Int) = (0, 0)
    @Published var status: String?
    @Published private(set) var cols: [String: (mor: Double?, day: Double?)] = [:]
    @Published private(set) var colsDay = ""
    private var computing = false
    var onReload: (() -> Void)?

    /// Set by the app (the sheet's symbols) so menu commands can start an update.
    static var allSheetSymbols: [String] = []

    static var lastUpdateDay: String { UserDefaults.standard.string(forKey: "i5m.lastDay") ?? "" }

    /// Downloads / tops up 5-minute bars for these symbols (60 days the first time, then 5 days), once a day after the close.
    func update(_ symbols: [String], force: Bool = false) {
        guard !busy, !symbols.isEmpty else { return }
        let today = AlertSchedule.today()
        guard force || Self.lastUpdateDay != today else { return }
        busy = true
        let list = Array(Set(symbols.map { $0.uppercased() })).sorted()
        progress = (0, list.count)
        status = "5-minute data: \(list.count) stocks…"
        Task {
            var done = 0, failed = 0
            var idx = 0
            while idx < list.count {
                let batch = Array(list[idx..<min(idx + 8, list.count)]); idx += batch.count
                let ok = await withTaskGroup(of: Bool.self) { g -> Int in
                    for s in batch {
                        g.addTask {
                            let old = Bars5mFiles.load(s)
                            let fresh = old.map { o in (o.t.last.map { Date().timeIntervalSince1970 - Double($0) < 4 * 86_400 } ?? false) } ?? false
                            guard let got = try? await YahooClient.bars5m(s, range: fresh ? "5d" : "60d") else { return false }
                            var b = old ?? Bars5m()
                            b.merge(got)
                            b.keepLast(days: 640)
                            Bars5mFiles.save(s, b)
                            return true
                        }
                    }
                    var n = 0
                    for await r in g where r { n += 1 }
                    return n
                }
                done += batch.count; failed += batch.count - ok
                progress = (done, list.count)
                status = "5-minute data: \(done)/\(list.count)"
            }
            UserDefaults.standard.set(today, forKey: "i5m.lastDay")
            busy = false
            status = failed > list.count / 3 ? "5-minute data: \(failed) of \(list.count) failed on Yahoo (rate limit?) — retried tomorrow or with Update now" : nil
            colsDay = ""
            onReload?()
        }
    }

    /// MOR / DAY for every stored symbol on `asOf` (background; calls onReload when ready).
    func columns(asOf: String) -> [String: (mor: Double?, day: Double?)] {
        if colsDay == asOf { return cols }
        if !computing { recompute(asOf) }
        return [:]
    }

    private func recompute(_ asOf: String) {
        computing = true
        // the 10-minute bucket still forming, if asOf is today and the market is open
        var live: Int? = nil
        if asOf == AlertSchedule.today(), LiveQuotes.marketOpen() {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
            let c = cal.dateComponents([.hour, .minute], from: Date())
            live = ((c.hour ?? 0) * 60 + (c.minute ?? 0) - (9 * 60 + 15)) / 10
        }
        let liveK = live
        Task {
            let out = await Task.detached(priority: .utility) { () -> [String: (mor: Double?, day: Double?)] in
                var r: [String: (mor: Double?, day: Double?)] = [:]
                for s in Bars5mFiles.symbols() { if let b = Bars5mFiles.load(s) { r[s] = MorDay.compute(b, asOf: asOf, liveBucket: liveK) } }
                return r
            }.value
            cols = out; colsDay = asOf; computing = false
            onReload?()
        }
    }

    var summary: String {
        let n = Bars5mFiles.symbols().count
        return n == 0 ? "No 5-minute data yet" : "5-minute data: \(n) stocks · \(String(format: "%.0f", Double(Bars5mFiles.totalBytes()) / 1_048_576)) MB · updated \(Self.lastUpdateDay.isEmpty ? "never" : Self.lastUpdateDay)"
    }
}
