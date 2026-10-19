import Foundation
import UserNotifications

/// One logged regime change (what the notification said, and when).
struct RegimeLogEntry: Codable, Identifiable {
    var id: String { change.id }
    let change: RegimeChange
    let loggedAt: Date
}

enum RegimeLogStore {
    private static var url: URL { AppFolders.base.appendingPathComponent("regime_log.json") }
    static func load() -> [RegimeLogEntry] {
        guard let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([RegimeLogEntry].self, from: d) else { return [] }
        return v
    }
    static func save(_ v: [RegimeLogEntry]) {
        try? FileManager.default.createDirectory(at: AppFolders.base, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Array(v.prefix(500))) { try? d.write(to: url, options: .atomic) }
    }
}

extension ScreenerViewModel {

    // MARK: Sector column

    var sectorColumnIndex: Int? {
        if !settings.sectorColumn.isEmpty, let i = table.index(of: settings.sectorColumn) { return i }
        for name in ["sector", "industry", "sector name", "industry name"] {
            if let i = headers.firstIndex(where: { $0.lowercased() == name }) { return i }
        }
        return headers.firstIndex { $0.lowercased().contains("sector") }
    }

    /// Sector → symbols, from the imported sheet.
    var sectorMembers: [String: [String]] {
        guard let label = labelIndex, let sc = sectorColumnIndex else { return [:] }
        var out: [String: [String]] = [:]
        for r in table.rows {
            let sym = r.text(label).trimmingCharacters(in: .whitespaces).uppercased()
            let sec = r.text(sc).trimmingCharacters(in: .whitespaces)
            guard !sym.isEmpty, !sec.isEmpty else { continue }
            out[sec, default: []].append(sym)
        }
        return out.mapValues { Array(Set($0)).sorted() }
    }

    var unseenRegimeCount: Int { regimeLog.filter { $0.loggedAt > regimeLastSeen }.count }

    func markRegimeSeen() {
        regimeLastSeen = Date()
        UserDefaults.standard.set(regimeLastSeen, forKey: "StockScreener.regimeLastSeen")
        regimeBanner = []
    }

    // MARK: Prices

    private static let lastSectorFetchKey = "StockScreener.lastSectorFetch"
    var lastSectorFetch: Date { (UserDefaults.standard.object(forKey: Self.lastSectorFetchKey) as? Date) ?? .distantPast }

    /// Missing stocks get a year of prices; known ones a light 1-month top-up merged into what's cached.
    func updateSectorPrices() async {
        guard sectorFetch == nil else { return }
        let all = Array(Set(sectorMembers.values.flatMap { $0 })) + [Self.benchmarkSymbol]
        let book = priceBook
        let missing = all.filter { s in
            guard let ser = book.series(for: s) else { return true }
            return ser.days.count < 120
        }
        let known = all.filter { !missing.contains($0) }
        let total = all.count
        sectorFetch = (0, total)
        var merged = priceBook
        if !missing.isEmpty {
            let (b, _) = await YahooClient.fetchAll(missing, range: "1y") { [weak self] d, _ in self?.sectorFetch = (d, total) }
            for (k, v) in b.series { merged.series[k] = v }
        }
        if !known.isEmpty {
            let offset = missing.count
            let (b, _) = await YahooClient.fetchAll(known, range: "1mo") { [weak self] d, _ in self?.sectorFetch = (offset + d, total) }
            for (k, v) in b.series { merged.series[k] = merged.series[k].map { $0.merged(with: v) } ?? v }
        }
        merged.fetchedAt = Date()
        priceBook = merged
        let toSave = merged
        await Task.detached(priority: .utility) { PriceStore.save(toSave) }.value
        UserDefaults.standard.set(Date(), forKey: Self.lastSectorFetchKey)
        sectorFetch = nil
    }

    /// After new sheet data: top up prices at most twice a day, then recompute and notify.
    func sectorDailyUpdate() async {
        guard sectorColumnIndex != nil else { return }
        if settings.sectorAutoUpdate && Date().timeIntervalSince(lastSectorFetch) > 12 * 3600 {
            await updateSectorPrices()
        }
        await computeSectors(notify: true)
    }

    // MARK: Compute + notify

    func computeSectors(notify: Bool) async {
        let members = sectorMembers
        guard !members.isEmpty else { return }
        isComputingSectors = true
        let book = priceBook
        let minM = max(1, settings.sectorMinMembers), confirm = max(1, settings.regimeConfirmDays)
        let report = await Task.detached(priority: .userInitiated) {
            SectorEngine.compute(members: members, book: book, minMembers: minM, confirmDays: confirm)
        }.value
        sectorReport = report
        isComputingSectors = false
        if notify { notifyRegimeChanges(report) }
    }

    private func wanted(_ c: RegimeChange) -> Bool {
        switch c.kind {
        case .rotation: guard settings.regimeNotifyRotation else { return false }
        case .trend: guard settings.regimeNotifyTrend else { return false }
        case .market: guard settings.regimeNotifyMarket else { return false }
        }
        return !settings.regimeMajorOnly || c.isMajor
    }

    /// New confirmed changes from the last 5 trading days → log, banner, macOS notification, optional email.
    func notifyRegimeChanges(_ report: SectorReport) {
        let recent = Set(report.marketHistory.suffix(5).map(\.day))
        let known = Set(regimeLog.map(\.id))
        let fresh = report.changes.filter { recent.contains($0.day) && !known.contains($0.id) && wanted($0) }
        guard !fresh.isEmpty else { return }
        let now = Date()
        regimeLog = fresh.map { RegimeLogEntry(change: $0, loggedAt: now) } + regimeLog
        RegimeLogStore.save(regimeLog)
        regimeBanner = fresh

        let lines = fresh.prefix(8).map { "\($0.sector): \($0.from) → \($0.to)" }
        postNotification(title: fresh.count == 1 ? "Regime change: \(fresh[0].sector)" : "\(fresh.count) regime changes",
                         body: lines.joined(separator: "\n") + (fresh.count > 8 ? "\n…" : ""))
        if settings.regimeEmail {
            let body = "Regime changes (Stock Screener, data up to \(report.asOf)):\n\n"
                + fresh.map { "• \($0.day)  \($0.sector): \($0.from) → \($0.to)  (\($0.detail))" }.joined(separator: "\n")
                + "\n\nMarket: \(report.market.rawValue) — \(report.marketDetail)"
            Task { [weak self] in
                _ = await self?.sendEmail(subject: "Regime change: " + fresh.prefix(3).map { "\($0.sector) → \($0.to)" }.joined(separator: ", "),
                                          body: body, recipients: "", logTitle: "Regime alert")
            }
        }
    }

    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }      // not when run outside the .app
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
