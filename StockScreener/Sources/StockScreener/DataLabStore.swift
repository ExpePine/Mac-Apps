import Foundation

// MARK: - Intraday candles with open / high / low / close / volume (Data Lab)
//
// Stored per symbol and interval as a small binary file compressed with Apple's LZFSE:
//   Application Support/StockScreener/datalab/5m/SYMBOL.ohlcv.lzfse   (Yahoo keeps ~60 days of 5-minute bars)
//   Application Support/StockScreener/datalab/1m/SYMBOL.ohlcv.lzfse   (Yahoo keeps only a few weeks of 1-minute bars)
// Each update merges what Yahoo returns into what's stored, so history grows past Yahoo's window over time.

struct OHLCV {
    var t: [Int32] = []
    var o: [Float] = [], h: [Float] = [], l: [Float] = [], c: [Float] = [], v: [Float] = []

    var count: Int { t.count }

    mutating func append(_ ts: Int32, _ op: Float, _ hi: Float, _ lo: Float, _ cl: Float, _ vo: Float) {
        t.append(ts); o.append(op); h.append(hi); l.append(lo); c.append(cl); v.append(vo)
    }

    mutating func merge(_ x: OHLCV) {
        var map: [Int32: (Float, Float, Float, Float, Float)] = [:]
        for i in 0..<count { map[t[i]] = (o[i], h[i], l[i], c[i], v[i]) }
        for i in 0..<x.count { map[x.t[i]] = (x.o[i], x.h[i], x.l[i], x.c[i], x.v[i]) }
        var out = OHLCV()
        for k in map.keys.sorted() { let b = map[k]!; out.append(k, b.0, b.1, b.2, b.3, b.4) }
        self = out
    }

    mutating func keepLast(calendarDays: Int) {
        guard let last = t.last else { return }
        let cut = last - Int32(calendarDays) * 86_400
        guard let i = t.firstIndex(where: { $0 >= cut }), i > 0 else { return }
        t.removeFirst(i); o.removeFirst(i); h.removeFirst(i); l.removeFirst(i); c.removeFirst(i); v.removeFirst(i)
    }

    private static let magic: UInt32 = 0x3156_484F      // "OHV1"

    var data: Data {
        var d = Data()
        var m = Self.magic, n = UInt32(count)
        d.append(Data(bytes: &m, count: 4)); d.append(Data(bytes: &n, count: 4))
        t.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        for a in [o, h, l, c, v] { a.withUnsafeBufferPointer { d.append(Data(buffer: $0)) } }
        return d
    }

    init() {}
    init?(_ d: Data) {
        guard d.count >= 8 else { return nil }
        let m = d.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let n = Int(d.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
        guard m == Self.magic, d.count == 8 + n * 24 else { return nil }
        func floats(_ k: Int) -> [Float] {
            d.subdata(in: (8 + n * 4 * k)..<(8 + n * 4 * (k + 1))).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        t = d.subdata(in: 8..<(8 + n * 4)).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        o = floats(1); h = floats(2); l = floats(3); c = floats(4); v = floats(5)
    }

    /// One candle per IST trading day.
    struct Day { let day: String; let range: Range<Int>; let o, h, l, c, v: Float }

    func days() -> [Day] {
        var out: [Day] = []
        let off = 19_800
        var i = 0
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"
        while i < count {
            let dn = (Int(t[i]) + off) / 86_400
            var j = i
            var hi = h[i], lo = l[i], vol: Float = 0
            while j < count && (Int(t[j]) + off) / 86_400 == dn { hi = max(hi, h[j]); lo = min(lo, l[j]); vol += v[j]; j += 1 }
            let key = f.string(from: Date(timeIntervalSince1970: TimeInterval(dn * 86_400 - off + 43_200)))
            out.append(Day(day: key, range: i..<j, o: o[i], h: hi, l: lo, c: c[j - 1], v: vol))
            i = j
        }
        return out
    }
}

enum LabFiles {
    static func folder(_ interval: String) -> URL {
        let u = AppFolders.folder("datalab").appendingPathComponent(interval, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func url(_ s: String, _ interval: String) -> URL {
        folder(interval).appendingPathComponent(s.replacingOccurrences(of: "/", with: "_") + ".ohlcv.lzfse")
    }
    static func load(_ s: String, _ interval: String) -> OHLCV? {
        guard let d = try? Data(contentsOf: url(s, interval)), let raw = try? (d as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return OHLCV(raw)
    }
    static func save(_ s: String, _ interval: String, _ b: OHLCV) {
        if let c = try? (b.data as NSData).compressed(using: .lzfse) as Data { try? c.write(to: url(s, interval), options: .atomic) }
    }
    static func symbols(_ interval: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder(interval).path)) ?? [])
            .filter { $0.hasSuffix(".ohlcv.lzfse") }.map { String($0.dropLast(".ohlcv.lzfse".count)) }
    }
}

extension YahooClient {
    /// Intraday candles with OHLCV. interval "1m" (range up to "7d") or "5m" (range up to "60d").
    /// Yahoo's limits are its own and undocumented; they've been ~7 days per 1-minute request and ~60 days for 5-minute.
    static func ohlcv(_ symbol: String, interval: String, range: String) async throws -> OHLCV {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(yahooSymbol(symbol))?range=\(range)&interval=\(interval)") else { throw Failure(message: "Bad symbol") }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw Failure(message: "rate-limited") }
        guard (200..<300).contains(status), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let stamps = result["timestamp"] as? [Double],
              let q = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first else {
            throw Failure(message: "no data")
        }
        func col(_ k: String) -> [Any] { q[k] as? [Any] ?? [] }
        let o = col("open"), h = col("high"), l = col("low"), c = col("close"), v = col("volume")
        var b = OHLCV()
        for (i, s) in stamps.enumerated() {
            guard i < c.count, let cl = c[i] as? Double, cl > 0 else { continue }
            let op = (i < o.count ? o[i] as? Double : nil) ?? cl
            let hi = (i < h.count ? h[i] as? Double : nil) ?? max(op, cl)
            let lo = (i < l.count ? l[i] as? Double : nil) ?? min(op, cl)
            let vo = (i < v.count ? v[i] as? Double : nil) ?? 0
            b.append(Int32(s), Float(op), Float(hi), Float(lo), Float(cl), Float(vo))
        }
        return b
    }
}
