import Foundation

/// Which stocks Daily Gainers looks at: all sheet stocks or only members of a Nifty index.
enum GainerUniverse: String, CaseIterable, Identifiable {
    case all, nifty50, nifty100, nifty200, nifty500
    var id: String { rawValue }
    static let key = "gainers.universe", mcapKey = "gainers.mcapMin"
    static var current: GainerUniverse { GainerUniverse(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .all }
    /// Minimum market cap in ₹ crore (0 = any).
    static var mcapMin: Double { UserDefaults.standard.double(forKey: mcapKey) }
    static let mcapPresets: [Double] = [0, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000]

    var title: String {
        switch self {
        case .all: return "All sheet stocks"
        case .nifty50: return "Nifty 50"
        case .nifty100: return "Nifty 100"
        case .nifty200: return "Nifty 200"
        case .nifty500: return "Nifty 500"
        }
    }
    /// NSE's index name (API) and constituent file.
    var indexName: String { title.uppercased() }
    var file: String { "ind_" + rawValue + "list.csv" }

    static func crore(_ v: Double) -> String {
        v >= 100_000 ? String(format: "%g lakh Cr", v / 100_000) : "\(Int(v).formatted()) Cr"
    }
}

/// Nifty index members and each stock's issued shares (for market cap = shares × Yahoo close), from NSE, cached on disk.
///  • Index members: NSE's constituent CSV (nsearchives, then niftyindices.com), else NSE's equity-stockIndices API.
///  • Shares: the MCAP file inside NSE's daily PR zip (all listed stocks); stocks it misses are asked one by one
///    from NSE's quote API (securityInfo.issuedSize). These NSE addresses are unofficial and can change.
@MainActor final class UniverseStore: ObservableObject {
    static let shared = UniverseStore()

    @Published private(set) var members: [String: Set<String>] = [:]      // index name → symbols
    @Published private(set) var shares: [String: Double] = [:]            // symbol → issued shares
    @Published private(set) var status: String?
    @Published private(set) var busy = false

    private struct Saved: Codable {
        var members: [String: [String]] = [:]
        var membersAt: [String: Date] = [:]
        var shares: [String: Double] = [:]
        var sharesAt: Date?
        var askedAt: [String: Date] = [:]
    }
    private var saved = Saved()
    private static var url: URL { AppFolders.folder("universe").appendingPathComponent("universe.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.url), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            saved = s
            members = s.members.mapValues(Set.init)
            shares = s.shares
        }
    }
    private func save() { if let d = try? JSONEncoder().encode(saved) { try? d.write(to: Self.url, options: .atomic) } }

    /// Market cap in ₹ crore on `close`.
    func mcap(_ symbol: String, close: Double?) -> Double? {
        guard let sh = shares[symbol], let c = close, sh > 0 else { return nil }
        return sh * c / 1e7
    }

    func isMember(_ symbol: String, of u: GainerUniverse) -> Bool? {
        guard u != .all else { return true }
        guard let set = members[u.indexName] else { return nil }
        return set.contains(symbol)
    }

    // MARK: Loading

    /// Makes sure the index list (weekly) and the shares table (daily) are there.
    func ensure(_ u: GainerUniverse, needMcap: Bool) async {
        if u != .all, (saved.membersAt[u.indexName].map { Date().timeIntervalSince($0) > 7 * 86_400 } ?? true) || members[u.indexName] == nil {
            await loadIndex(u)
        }
        if needMcap, saved.sharesAt.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true {
            await loadShares()
        }
    }

    func refresh(_ u: GainerUniverse, needMcap: Bool) async {
        if u != .all { saved.membersAt[u.indexName] = nil }
        if needMcap { saved.sharesAt = nil }
        await ensure(u, needMcap: needMcap)
    }

    private func loadIndex(_ u: GainerUniverse) async {
        busy = true; defer { busy = false }
        status = "Reading \(u.title) list from NSE…"
        var syms: Set<String> = []
        for (src, ref) in [("https://nsearchives.nseindia.com/content/indices/\(u.file)", "https://www.nseindia.com/"),
                           ("https://www.niftyindices.com/IndexConstituent/\(u.file)", "https://www.niftyindices.com/")] {
            guard let url = URL(string: src), let d = try? await NSEDealsClient.raw(url, referer: ref),
                  let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) else { continue }
            syms = Self.symbols(fromCSV: text)
            if syms.count >= 40 { break }
        }
        if syms.count < 40,
           let q = u.indexName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://www.nseindia.com/api/equity-stockIndices?index=\(q)"),
           let obj = try? await NSEDealsClient.json(url, referer: "https://www.nseindia.com/market-data/live-equity-market"),
           let rows = (obj as? [String: Any])?["data"] as? [[String: Any]] {
            syms = Set(rows.compactMap { ($0["symbol"] as? String)?.uppercased() }.filter { $0 != u.indexName })
        }
        if syms.count >= 40 {
            members[u.indexName] = syms
            saved.members[u.indexName] = syms.sorted()
            saved.membersAt[u.indexName] = Date()
            save()
            status = nil
        } else {
            status = members[u.indexName] == nil ? "Couldn't read the \(u.title) list from NSE — try ⟳ later." : "NSE didn't answer; using the saved \(u.title) list."
        }
    }

    nonisolated static func symbols(fromCSV text: String) -> Set<String> {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let head = lines.first else { return [] }
        let cols = head.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let si = cols.firstIndex(of: "symbol") else { return [] }
        return Set(lines.dropFirst().compactMap { l -> String? in
            let c = l.split(separator: ",", omittingEmptySubsequences: false)
            guard si < c.count else { return nil }
            let s = c[si].trimmingCharacters(in: .whitespaces).uppercased()
            return s.isEmpty ? nil : s
        })
    }

    private static let mon = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// Shares of every listed stock from the MCAP file in the latest PR zip (looks back up to 8 days).
    private func loadShares() async {
        busy = true; defer { busy = false }
        status = "Reading market caps from NSE…"
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        for back in 0..<8 {
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            guard let y = c.year, let m = c.month, let dd = c.day, ![1, 7].contains(cal.component(.weekday, from: d)) else { continue }
            let tag = String(format: "%02d%02d%02d", dd, m, y % 100)
            for src in ["https://nsearchives.nseindia.com/archives/equities/bhavcopy/pr/PR\(tag).zip",
                        "https://nsearchives.nseindia.com/content/historical/EQUITIES/\(y)/\(Self.mon[m - 1])/PR\(tag).zip"] {
                guard let url = URL(string: src), let zip = try? await NSEDealsClient.raw(url, referer: "https://www.nseindia.com/all-reports"),
                      zip.count > 1000, let table = await Task.detached(operation: { Self.mcapTable(zip: zip) }).value, table.count > 500 else { continue }
                shares.merge(table) { _, new in new }
                saved.shares = shares
                saved.sharesAt = Date()
                save()
                status = nil
                return
            }
        }
        saved.sharesAt = Date().addingTimeInterval(-86_400 + 3 * 3600)        // try again in ~3 h
        status = shares.isEmpty ? "NSE's market-cap file wasn't available; asking NSE per stock instead." : nil
    }

    /// Unzips the PR zip and reads its MCAP*.csv: symbol → issued shares (Issue Size, else market cap ÷ close).
    nonisolated static func mcapTable(zip: Data) -> [String: Double]? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pr-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let z = dir.appendingPathComponent("pr.zip")
        guard (try? zip.write(to: z)) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", z.path, "-d", dir.path]
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let files = (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        guard let f = files.first(where: { $0.lastPathComponent.lowercased().hasPrefix("mcap") && $0.pathExtension.lowercased() == "csv" }),
              let d = try? Data(contentsOf: f), let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) else { return nil }
        return parseMcap(text)
    }

    nonisolated static func parseMcap(_ text: String) -> [String: Double] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let head = lines.first else { return [:] }
        let cols = head.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func idx(_ f: (String) -> Bool) -> Int? { cols.firstIndex(where: f) }
        guard let si = idx({ $0 == "symbol" }) else { return [:] }
        let ser = idx { $0 == "series" }
        let issue = idx { $0.contains("issue size") }
        let cap = idx { $0.contains("market cap") }
        let close = idx { $0.contains("close") }
        var out: [String: Double] = [:]
        for l in lines.dropFirst() {
            let c = l.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard si < c.count else { continue }
            if let ser, ser < c.count, !DeliveryBook.equitySeries.contains(c[ser].uppercased()) { continue }
            func num(_ i: Int?) -> Double? { i.flatMap { $0 < c.count ? Double(c[$0].replacingOccurrences(of: "\"", with: "")) : nil } }
            var sh = num(issue)
            if sh == nil, let m = num(cap), let cl = num(close), cl > 0 { sh = m / cl }
            if let sh, sh > 0 { out[c[si].uppercased()] = sh }
        }
        return out
    }

    /// Asks NSE's quote API for stocks without shares (at most once a week each, a few at a time).
    func fillShares(_ symbols: [String]) async {
        let todo = symbols.filter { sym in
            guard shares[sym] == nil else { return false }
            if let t = saved.askedAt[sym] { return Date().timeIntervalSince(t) > 7 * 86_400 }
            return true
        }
        guard !todo.isEmpty, !busy else { return }
        busy = true; defer { busy = false }
        for (k, s) in todo.prefix(150).enumerated() {
            status = "Market cap from NSE \(k + 1)/\(min(150, todo.count))…"
            saved.askedAt[s] = Date()
            guard let q = s.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let url = URL(string: "https://www.nseindia.com/api/quote-equity?symbol=\(q)"),
                  let obj = try? await NSEDealsClient.json(url, referer: "https://www.nseindia.com/get-quotes/equity?symbol=\(q)"),
                  let info = (obj as? [String: Any])?["securityInfo"] as? [String: Any] else { continue }
            let v = (info["issuedSize"] as? Double) ?? (info["issuedSize"] as? Int).map(Double.init) ?? (info["issuedSize"] as? String).flatMap(Double.init)
            if let v, v > 0 { shares[s] = v; saved.shares[s] = v }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        save()
        status = nil
    }
}
