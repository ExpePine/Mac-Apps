import SwiftUI

// MARK: - NSE data repair ("Check now" in Delivery Analysis)
//
// Max effort to complete the stored NSE delivery history:
//   1. Trading calendar — re-read NIFTY 50 trading days from Yahoo now (not the 6-hour cache).
//   2. Missing whole days — every calendar trading day without a file (also days wrongly marked "holiday").
//      Each day is tried from several places, in order:
//        a. nsearchives.nseindia.com/products/content/sec_bhavdata_full_DDMMYYYY.csv   (plain)
//        b. the same file with NSE's browser cookies (after opening nseindia.com)
//        c. archives.nseindia.com/products/content/sec_bhavdata_full_DDMMYYYY.csv      (older host)
//        d. MTO_DDMMYYYY.DAT (NSE's security-wise delivery position file) + that day's close from Yahoo
//      Days NSE refuses (HTTP 403 / 429 / 5xx, timeouts) are retried in up to 5 rounds with growing pauses.
//   3. Holes in single stocks (Filter's stocks): days where the file exists but the stock has no row. The day is
//      fetched again; rows where NSE printed "-" for DELIV_QTY are filled from that day's MTO file when it has the
//      number. A stock with no row at all that day = not traded / suspended (nothing to fill).
// Unofficial NSE URLs — they can change or be blocked; the MTO layout is read defensively.

@MainActor final class NSERepair: ObservableObject {
    static let shared = NSERepair()

    struct Step: Identifiable { let id = UUID(); var title: String; var detail = ""; var state: State = .waiting
        enum State { case waiting, running, done, warn, failed } }

    @Published private(set) var running = false
    @Published private(set) var steps: [Step] = []
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var log: [String] = []
    @Published private(set) var finishedAt: Date?
    private var task: Task<Void, Never>?

    func stop() { task?.cancel() }

    /// `close`: a stock's close on a day (Yahoo) — for MTO-only days. `symbols`: the Filter's stocks (for per-stock holes).
    func start(symbols: [String], close: @escaping (String, String) -> Double?) {
        let dc = DeliveryCenter.shared
        guard !running, !dc.isFetching else { return }
        running = true; finishedAt = nil; log = []
        steps = [Step(title: "Trading calendar"), Step(title: "Missing days"), Step(title: "Holes in single stocks"), Step(title: "Rebuild")]
        task = Task {
            await run(symbols: symbols, close: close)
            running = false
            finishedAt = Date()
            dc.reload()
        }
    }

    private func set(_ i: Int, _ state: Step.State, _ detail: String) { steps[i].state = state; steps[i].detail = detail }
    private func note(_ s: String) { log.append(s); if log.count > 400 { log.removeFirst(log.count - 400) } }

    // MARK: The run

    private func run(symbols: [String], close: @escaping (String, String) -> Double?) async {
        let dc = DeliveryCenter.shared

        // 1. calendar
        set(0, .running, "Reading NIFTY 50 trading days from Yahoo…")
        await dc.refreshCalendar(force: true)
        let cal = dc.calendar
        if cal.isEmpty { set(0, .warn, "Yahoo didn't answer — using weekdays only"); note("Calendar: Yahoo unavailable") }
        else { set(0, .done, "\(cal.count) trading days known (latest \(cal.last ?? "—"))") }

        // 2. whole days
        let today = DeliveryCenter.key(Date())
        let have = Set(DeliveryFiles.days())
        var holidays = DeliveryFiles.missing()
        let first = DeliveryFiles.days().first ?? cal.first ?? today
        var wanted = cal.filter { $0 >= first && $0 < today && !have.contains($0) }
        let wronglyMarked = holidays.intersection(cal)
        if !wronglyMarked.isEmpty { holidays.subtract(wronglyMarked); DeliveryFiles.saveMissing(holidays); note("\(wronglyMarked.count) day(s) were marked holiday but are trading days — retrying them") }
        if cal.isEmpty {                       // no calendar: weekdays since the first stored day that aren't known holidays
            var d = DeliveryCenter.istCalendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            while DeliveryCenter.key(d) >= first {
                let k = DeliveryCenter.key(d), wd = DeliveryCenter.istCalendar.component(.weekday, from: d)
                if wd != 1 && wd != 7 && !have.contains(k) && !holidays.contains(k) { wanted.append(k) }
                d = DeliveryCenter.istCalendar.date(byAdding: .day, value: -1, to: d) ?? d.addingTimeInterval(-86_400)
            }
        }
        wanted = Array(Set(wanted)).sorted(by: >)
        if wanted.isEmpty { set(1, .done, "No missing days since \(first)") }
        else {
            set(1, .running, "\(wanted.count) missing day\(wanted.count == 1 ? "" : "s") — trying every source…")
            let r = await fetchDays(wanted, close: close, step: 1)
            if Task.isCancelled { set(1, .warn, "Stopped — \(r.saved) saved"); set(2, .warn, "Skipped"); set(3, .done, ""); return }
            var parts = ["\(r.saved) of \(wanted.count) filled"]
            if !r.viaMTO.isEmpty { parts.append("\(r.viaMTO.count) from the MTO file") }
            if !r.noFile.isEmpty { parts.append("\(r.noFile.count) NSE has no file anywhere (\(r.noFile.sorted().prefix(3).joined(separator: ", "))\(r.noFile.count > 3 ? "…" : ""))") }
            if !r.blocked.isEmpty { parts.append("\(r.blocked.count) still refused by NSE — press Check now again later") }
            set(1, r.blocked.isEmpty ? .done : .warn, parts.joined(separator: " · "))
        }

        // 3. per-stock holes
        set(2, .running, "Finding days your Filter's stocks are missing…")
        dc.reload()
        while dc.isLoading { try? await Task.sleep(nanoseconds: 200_000_000) }
        let files = Set(DeliveryFiles.days())
        var holes: [String: Set<String>] = [:]       // day → symbols
        for s in Set(symbols.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }) {
            for d in dc.stockGaps(s) where files.contains(d) { holes[d, default: []].insert(s) }
        }
        let holeDays = holes.keys.sorted(by: >).prefix(250)
        if holeDays.isEmpty { set(2, .done, "None — every Filter stock has a row on every stored day since it listed") }
        else {
            var filled = 0, notTraded = 0, noNumber = 0, failed = 0
            progress = (0, holeDays.count)
            for (k, d) in holeDays.enumerated() {
                if Task.isCancelled { break }
                let want = holes[d] ?? []
                let r = await fillHoles(day: d, symbols: want)
                filled += r.filled; notTraded += r.notTraded; noNumber += r.noNumber; failed += r.failed ? 1 : 0
                progress = (k + 1, holeDays.count)
                set(2, .running, "Day \(k + 1)/\(holeDays.count) · \(filled) filled")
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            var parts = ["\(filled) stock-day\(filled == 1 ? "" : "s") filled"]
            if notTraded > 0 { parts.append("\(notTraded) not traded / suspended (NSE has no row)") }
            if noNumber > 0 { parts.append("\(noNumber) NSE published no delivery number") }
            if failed > 0 { parts.append("\(failed) day\(failed == 1 ? "" : "s") NSE refused — try again later") }
            if holes.count > holeDays.count { parts.append("checked the latest \(holeDays.count) of \(holes.count) days") }
            set(2, failed == 0 ? .done : .warn, parts.joined(separator: " · "))
        }
        set(3, .done, "Indicators recalculated")
    }

    // MARK: Whole days

    private struct DaysResult { var saved = 0; var viaMTO: [String] = []; var noFile: [String] = []; var blocked: [String] = [] }

    private func fetchDays(_ days: [String], close: @escaping (String, String) -> Double?, step: Int) async -> DaysResult {
        var res = DaysResult()
        var pending = days
        var noFile: [String] = []
        let pauses: [UInt64] = [0, 20, 45, 90, 150]
        progress = (0, days.count)
        var done = 0
        for round in pauses.indices {
            if pending.isEmpty || Task.isCancelled { break }
            if pauses[round] > 0 {
                set(step, .running, "NSE refused \(pending.count) day\(pending.count == 1 ? "" : "s") — waiting \(pauses[round]) s, then round \(round + 1) of \(pauses.count)…")
                note("Round \(round + 1): pausing \(pauses[round]) s for NSE")
                try? await Task.sleep(nanoseconds: pauses[round] * 1_000_000_000)
            }
            var next: [String] = []
            var i = 0
            while i < pending.count && !Task.isCancelled {
                let batch = Array(pending[i..<min(i + 2, pending.count)]); i += batch.count
                let out = await withTaskGroup(of: (String, Fetched).self) { g in
                    for d in batch { g.addTask { (d, await Self.fetchHard(d)) } }
                    var r: [(String, Fetched)] = []
                    for await x in g { r.append(x) }
                    return r
                }
                for (d, f) in out {
                    switch f {
                    case .rows(let rows, let src):
                        try? DeliveryFiles.save(rows, day: d); res.saved += 1; done += 1
                        note("\(d): saved (\(src))")
                    case .mto(let rows):
                        // MTO has no prices: the close comes from Yahoo for that day
                        let priced = rows.compactMap { r -> DeliveryRow? in
                            guard let c = close(r.symbol, d), c > 0 else { return nil }
                            return DeliveryRow(symbol: r.symbol, series: r.series, close: c, tradedQty: r.tradedQty, delivQty: r.delivQty, delivPer: r.delivPer)
                        }
                        if priced.count >= 50 {
                            try? DeliveryFiles.save(priced, day: d); res.saved += 1; res.viaMTO.append(d); done += 1
                            note("\(d): saved from the MTO file (\(priced.count) stocks with a Yahoo close)")
                        } else { next.append(d); note("\(d): MTO file found but too few Yahoo closes — will retry the full file") }
                    case .noFile:
                        noFile.append(d); done += 1; note("\(d): no file on any NSE source")
                    case .blocked(let m):
                        next.append(d); note("\(d): refused (\(m))")
                    }
                }
                progress = (done, days.count)
                set(step, .running, "Round \(round + 1): \(done)/\(days.count) · \(res.saved) saved")
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            pending = next + (Task.isCancelled ? Array(pending[min(i, pending.count)...]) : [])
        }
        res.blocked = pending
        res.noFile = noFile
        return res
    }

    enum Fetched { case rows([DeliveryRow], String), mto([DeliveryRow]), noFile, blocked(String) }

    /// Every source for one day's file.
    nonisolated static func fetchHard(_ day: String) async -> Fetched {
        let f = NSEDeliveryClient.fileName(day)
        var refused: String?
        var all404 = true
        // a. plain
        switch await NSEDeliveryClient.fetch(day) {
        case .rows(let r): return .rows(r, "NSE archive")
        case .noFile: break
        case .blocked(let m): refused = m; all404 = false
        }
        // b. with cookies, c. old host
        for (u, name) in [("https://nsearchives.nseindia.com/products/content/sec_bhavdata_full_\(f).csv", "NSE with cookies"),
                          ("https://archives.nseindia.com/products/content/sec_bhavdata_full_\(f).csv", "older archive host")] {
            guard let url = URL(string: u) else { continue }
            do {
                let d = try await NSEDealsClient.raw(url, referer: "https://www.nseindia.com/all-reports")
                let rows = NSEDeliveryClient.parse(d)
                if !rows.isEmpty { return .rows(rows, name) }
                all404 = false; refused = "empty file"
            } catch {
                let m = error.localizedDescription
                if !m.contains("404") { all404 = false; refused = m }
            }
        }
        // d. MTO
        for u in ["https://nsearchives.nseindia.com/archives/equities/mto/MTO_\(f).DAT",
                  "https://archives.nseindia.com/archives/equities/mto/MTO_\(f).DAT"] {
            guard let url = URL(string: u) else { continue }
            do {
                let d = try await NSEDealsClient.raw(url, referer: "https://www.nseindia.com/all-reports")
                let rows = parseMTO(d)
                if rows.count > 100 { return .mto(rows) }
            } catch {
                let m = error.localizedDescription
                if !m.contains("404") { all404 = false; refused = refused ?? m }
            }
        }
        return all404 ? .noFile : .blocked(refused ?? "NSE busy")
    }

    /// MTO_DDMMYYYY.DAT: data lines "20,<sr>,<SYMBOL>,<SERIES>,<traded qty>,<deliverable qty>,<% deliverable>".
    nonisolated static func parseMTO(_ data: Data) -> [DeliveryRow] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        var out: [DeliveryRow] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 7, f[0] == "20", let tq = Double(f[4]), let dq = Double(f[5]) else { continue }
            out.append(DeliveryRow(symbol: f[2].uppercased(), series: f[3].uppercased(), close: 0, tradedQty: tq, delivQty: dq,
                                   delivPer: Double(f[6]) ?? (tq > 0 ? dq / tq * 100 : 0)))
        }
        return out
    }

    // MARK: Holes in single stocks

    private struct HoleResult { var filled = 0; var notTraded = 0; var noNumber = 0; var failed = false }

    /// Re-reads the day: stocks with a "-" delivery number get it from the MTO file (close from the full file).
    private func fillHoles(day: String, symbols: Set<String>) async -> HoleResult {
        var res = HoleResult()
        let f = NSEDeliveryClient.fileName(day)
        guard let url = URL(string: "https://nsearchives.nseindia.com/products/content/sec_bhavdata_full_\(f).csv"),
              let data = try? await NSEDealsClient.raw(url, referer: "https://www.nseindia.com/all-reports") else {
            res.failed = true; note("\(day): NSE refused the re-read"); return res
        }
        let dashes = Self.dashRows(data).filter { symbols.contains($0.symbol) && DeliveryBook.equitySeries.contains($0.series) }
        var stored = DeliveryFiles.load(day)
        // any wanted stock that the stored copy lacks but the fresh file has with a number (stored copy was partial)
        let fresh = NSEDeliveryClient.parse(data)
        let storedSyms = Set(stored.map(\.symbol))
        let gained = fresh.filter { symbols.contains($0.symbol) && !storedSyms.contains($0.symbol) }
        stored += gained; res.filled += Set(gained.map(\.symbol)).count
        var withNumber = Set(gained.map(\.symbol))
        if !dashes.isEmpty {
            var mto: [String: DeliveryRow] = [:]
            for u in ["https://nsearchives.nseindia.com/archives/equities/mto/MTO_\(f).DAT"] {
                if let url = URL(string: u), let d = try? await NSEDealsClient.raw(url, referer: "https://www.nseindia.com/all-reports") {
                    for r in Self.parseMTO(d) { mto[r.symbol + "|" + r.series] = r }
                }
            }
            for d in dashes {
                if let m = mto[d.symbol + "|" + d.series] {
                    stored.append(DeliveryRow(symbol: d.symbol, series: d.series, close: d.close, tradedQty: d.tradedQty, delivQty: m.delivQty, delivPer: m.delivPer))
                    withNumber.insert(d.symbol); res.filled += 1
                } else { res.noNumber += 1 }
            }
        }
        if !withNumber.isEmpty { try? DeliveryFiles.save(stored, day: day); note("\(day): filled \(withNumber.sorted().prefix(6).joined(separator: ", "))\(withNumber.count > 6 ? "…" : "")") }
        let dashSyms = Set(dashes.map(\.symbol))
        res.notTraded = symbols.subtracting(withNumber).subtracting(dashSyms).count
        return res
    }

    /// Rows whose DELIV_QTY is "-" (traded, delivery not published) — symbol, series, close, traded qty.
    nonisolated static func dashRows(_ data: Data) -> [DeliveryRow] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        var lines = text.split(whereSeparator: \.isNewline)[...]
        guard let header = lines.popFirst() else { return [] }
        let h = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        guard let sym = h.firstIndex(of: "SYMBOL"), let dq = h.firstIndex(of: "DELIV_QTY") else { return [] }
        let ser = h.firstIndex(of: "SERIES"), cl = h.firstIndex(of: "CLOSE_PRICE") ?? h.firstIndex(of: "CLOSE"), tq = h.firstIndex(of: "TTL_TRD_QNTY")
        var out: [DeliveryRow] = []
        for line in lines {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count > max(sym, dq), Double(f[dq]) == nil else { continue }
            func num(_ i: Int?) -> Double { i.flatMap { $0 < f.count ? Double(f[$0]) : nil } ?? 0 }
            out.append(DeliveryRow(symbol: f[sym].uppercased(), series: ser.map { $0 < f.count ? f[$0].uppercased() : "" } ?? "",
                                   close: num(cl), tradedQty: num(tq), delivQty: 0, delivPer: 0))
        }
        return out
    }
}

// MARK: - Window (sheet)

struct NSERepairView: View {
    @EnvironmentObject var vm: ScreenerViewModel
    @ObservedObject private var r = NSERepair.shared
    @ObservedObject private var dc = DeliveryCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Repair NSE delivery data").font(.title3.bold())
                Spacer()
                if r.running { Button("Stop") { r.stop() } }
                else {
                    Button { start() } label: { Label(r.finishedAt == nil ? "Check now" : "Check again", systemImage: "wrench.and.screwdriver") }
                        .buttonStyle(.borderedProminent).disabled(dc.isFetching)
                }
                Button("Close") { dismiss() }
            }
            Text("Re-reads NSE's trading calendar, then fetches every missing day from four NSE sources with retries, then fills single-stock holes in your Filter's stocks. It can take several minutes when NSE is slow — you can keep working.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if dc.isFetching { Text("An NSE download is running — wait for it to finish.").font(.caption).foregroundStyle(.orange) }
            if r.running && r.progress.total > 0 {
                ProgressView(value: Double(r.progress.done), total: Double(r.progress.total))
            }
            ForEach(r.steps) { s in
                HStack(alignment: .top, spacing: 8) {
                    icon(s.state).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.callout.bold())
                        if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            if !r.log.isEmpty {
                Text("Details").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollViewReader { p in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(r.log.enumerated()), id: \.offset) { item in Text(item.element).font(.caption.monospaced()).id(item.offset) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    .onChange(of: r.log.count) { n in p.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            if let f = r.finishedAt { Text("Finished \(f.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(18)
        .frame(width: 620)
        .onAppear { if !r.running && r.finishedAt == nil { start() } }
    }

    private func start() {
        let book = vm.priceBook
        r.start(symbols: vm.allSymbols) { sym, day in
            guard let p = book.series(for: sym), let i = p.days.firstIndex(of: day), i < p.closes.count else { return nil }
            return p.closes[i]
        }
    }

    @ViewBuilder private func icon(_ s: NSERepair.Step.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
