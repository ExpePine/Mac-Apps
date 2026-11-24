import SwiftUI
import UserNotifications

/// NSE's trading-holiday list (equity segment) — the app tells you when the market is closed today or tomorrow.
/// BSE's equity holidays are the same days in practice, so one list serves both.
@MainActor final class MarketHolidays: ObservableObject {
    static let shared = MarketHolidays()
    @Published private(set) var holidays: [String: String] = [:]      // "yyyy-MM-dd" → name
    @Published var dismissedDay = UserDefaults.standard.string(forKey: "holiday.dismissed") ?? ""
    @Published private(set) var lastError: String?
    private var fetchedAt = Date.distantPast
    private var fetching = false
    private static var url: URL { AppFolders.base.appendingPathComponent("market_holidays.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.url), let m = try? JSONDecoder().decode([String: String].self, from: d) { holidays = m }
        if let a = try? FileManager.default.attributesOfItem(atPath: Self.url.path), let t = a[.modificationDate] as? Date { fetchedAt = t }
    }

    static let dayF: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let nseF: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "dd-MMM-yyyy"; return f }()
    static let nice: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_IN"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "EEE d MMM"; return f }()

    static func key(_ d: Date) -> String { dayF.string(from: d) }

    var today: String { Self.key(Date()) }
    var tomorrow: String { Self.key(Date().addingTimeInterval(86_400)) }

    /// What to tell you now: (title, detail) or nil when the market is open today and tomorrow.
    var message: (String, String)? {
        if let h = holidays[today] { return ("Market closed today", "NSE & BSE holiday — \(h)") }
        if let h = holidays[tomorrow] {
            let d = Self.dayF.date(from: tomorrow).map { Self.nice.string(from: $0) } ?? tomorrow
            return ("Market closed tomorrow", "\(d): NSE & BSE holiday — \(h)")
        }
        return nil
    }

    /// The next holiday from today (for the banner's tooltip).
    var next: (String, String)? { holidays.filter { $0.key >= today }.min { $0.key < $1.key }.map { ($0.key, $0.value) } }

    /// Called from the app's refresh loop and at launch: refresh the list weekly, notify once a day.
    func checkIfDue() {
        if !fetching, Date().timeIntervalSince(fetchedAt) > 7 * 86_400 || !holidays.keys.contains(where: { $0.hasPrefix(String(today.prefix(4))) }) {
            fetching = true
            Task { await fetch(); fetching = false; notifyOnce() }
        } else { notifyOnce() }
    }

    func fetch() async {
        guard let u = URL(string: "https://www.nseindia.com/api/holiday-master?type=trading") else { return }
        do {
            let d = try await NSEDealsClient.raw(u, referer: "https://www.nseindia.com/resources/exchange-communication-holidays", json: true)
            let found = Self.parse(d)
            guard !found.isEmpty else { lastError = "NSE's holiday list came back empty"; fetchedAt = Date(); return }
            holidays = holidays.merging(found) { _, new in new }
            fetchedAt = Date(); lastError = nil
            if let data = try? JSONEncoder().encode(holidays) { try? data.write(to: Self.url, options: .atomic) }
        } catch {
            lastError = "Couldn't read NSE's holiday list: \(error.localizedDescription)"
            fetchedAt = Date().addingTimeInterval(-6 * 86_400)        // try again in a day
        }
    }

    /// NSE's reply: {"CM": [{"tradingDate": "26-Jan-2026", "description": "Republic Day", …}], "FO": […], …}.
    /// The equity segment (CM) is used; any list of such rows is read if the keys differ.
    nonisolated static func parse(_ d: Data) -> [String: String] {
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        let lists: [[Any]] = obj["CM"].flatMap { $0 as? [Any] }.map { [$0] } ?? obj.values.compactMap { $0 as? [Any] }
        let inF = DateFormatter(); inF.locale = Locale(identifier: "en_US_POSIX"); inF.timeZone = TimeZone(identifier: "Asia/Kolkata"); inF.dateFormat = "dd-MMM-yyyy"
        let outF = DateFormatter(); outF.locale = Locale(identifier: "en_US_POSIX"); outF.timeZone = TimeZone(identifier: "Asia/Kolkata"); outF.dateFormat = "yyyy-MM-dd"
        var out: [String: String] = [:]
        for l in lists {
            for case let r as [String: Any] in l {
                guard let raw = r["tradingDate"] as? String, let dt = inF.date(from: raw) else { continue }
                out[outF.string(from: dt)] = (r["description"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Holiday"
            }
        }
        return out
    }

    private func notifyOnce() {
        guard let m = message, UserDefaults.standard.string(forKey: "holiday.notified") != today, Bundle.main.bundleIdentifier != nil else { return }
        UserDefaults.standard.set(today, forKey: "holiday.notified")
        let center = UNUserNotificationCenter.current()
        let id = "holiday-" + today
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = m.0; c.body = m.1
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }

    func dismiss() { dismissedDay = today; UserDefaults.standard.set(today, forKey: "holiday.dismissed") }
}

/// A strip at the top of Daily Gainers / Filter on a holiday or the day before one.
struct HolidayBanner: View {
    @ObservedObject private var mh = MarketHolidays.shared
    var body: some View {
        if let m = mh.message, mh.dismissedDay != mh.today {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.orange)
                Text(m.0).font(.callout.bold())
                Text(m.1).font(.callout)
                Spacer()
                Button { mh.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide for today")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.orange.opacity(0.14))
        }
    }
}
