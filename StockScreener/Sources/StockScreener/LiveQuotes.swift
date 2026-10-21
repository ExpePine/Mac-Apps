import Foundation

/// Live Yahoo prices for Daily Gainers: while NSE is open, re-reads today's price for every sheet stock
/// (plus NIFTY 50 / SENSEX) about once a minute and merges it into the price book as today's bar — so the
/// gainers list, Day %, Close, breadth and every chart built from the price book move during the day.
///
/// Source: Yahoo's public chart endpoint (unofficial, undocumented). Yahoo's NSE prices can lag the exchange
/// by a little; a full sweep of ~2,000 stocks itself takes a minute or two.
@MainActor final class LiveQuotes: ObservableObject {
    static let shared = LiveQuotes()

    @Published private(set) var lastUpdate: Date?
    @Published private(set) var updating = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var lastError: String?
    @Published private(set) var stocks = 0
    @Published private(set) var tick = 0          // bumps after every sweep (redraws tables)
    private var sweeps = 0
    private var users = 0

    /// Seconds between sweeps while the market is open.
    static var interval: Double { let v = UserDefaults.standard.double(forKey: "live.interval"); return v >= 15 ? v : 60 }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "live.enabled") as? Bool ?? true }

    private static let ist = TimeZone(identifier: "Asia/Kolkata")!

    /// NSE regular session: Monday–Friday 09:15–15:30 IST (a few minutes after, to catch the closing price).
    /// Exchange holidays aren't known here — on a holiday Yahoo simply returns no new bar.
    static func marketOpen(_ now: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ist
        let c = cal.dateComponents([.weekday, .hour, .minute], from: now)
        guard let wd = c.weekday, (2...6).contains(wd), let h = c.hour, let m = c.minute else { return false }
        let mins = h * 60 + m
        return mins >= 9 * 60 + 10 && mins <= 15 * 60 + 40
    }

    /// Runs while a Daily Gainers / Gainer Charts window is open: sweeps every `interval` s while the market is
    /// open, once on opening otherwise (to pick up the final close), then checks every 5 minutes.
    func keepLive(_ vm: ScreenerViewModel) async {
        users += 1
        defer { users -= 1 }
        var first = true
        while !Task.isCancelled {
            if Self.enabled && (Self.marketOpen() || first || needsCatchUp(vm)) {
                await sweep(vm)
                first = false
            }
            let wait = Self.marketOpen() ? Self.interval : 300
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Outside market hours: the last sweep was before today's close.
    private func needsCatchUp(_ vm: ScreenerViewModel) -> Bool {
        guard let last = lastUpdate else { return true }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.ist
        guard let close = cal.date(bySettingHour: 15, minute: 35, second: 0, of: Date()) else { return false }
        return Date() > close && last < close
    }

    /// One pass over every stock: today's (live) bar from Yahoo, merged into the price book.
    func sweep(_ vm: ScreenerViewModel) async {
        guard !updating else { return }
        let symbols = vm.allSymbols + [ScreenerViewModel.benchmarkSymbol, ScreenerViewModel.sensexSymbol]
        guard symbols.count > 2 else { lastError = "Import the sheet first — its stock list is what gets tracked."; return }
        updating = true
        progress = (0, symbols.count)
        let (fresh, failed) = await YahooClient.fetchAll(symbols, range: "5d", width: 10) { [weak self] d, t in self?.progress = (d, t) }
        updating = false
        guard !fresh.series.isEmpty else {
            lastError = "Yahoo returned no prices (\(failed.count) failed) — it may be rate-limiting; retrying next minute."
            return
        }
        var book = vm.priceBook
        for (k, v) in fresh.series { book.series[k] = book.series[k].map { $0.merged(with: v) } ?? v }
        book.fetchedAt = Date()
        vm.priceBook = book
        await vm.refreshIndexCharts()
        stocks = fresh.series.count
        lastError = failed.count > symbols.count / 4 ? "\(failed.count) of \(symbols.count) symbols failed on Yahoo this pass" : nil
        lastUpdate = Date()
        tick &+= 1
        sweeps += 1
        if sweeps % 5 == 1 || !Self.marketOpen() {
            let toSave = book
            await Task.detached(priority: .utility) { PriceStore.save(toSave) }.value
        }
    }

    var statusText: String {
        if updating { return "Updating live prices… \(progress.done)/\(progress.total)" }
        guard let t = lastUpdate else { return "Live prices: waiting for the first pass" }
        let ago = Int(Date().timeIntervalSince(t))
        let when = ago < 90 ? "\(ago)s ago" : t.formatted(date: .omitted, time: .shortened)
        return (Self.marketOpen() ? "● Live" : "Market closed") + " · Yahoo · \(stocks) stocks · updated \(when)"
    }
}
