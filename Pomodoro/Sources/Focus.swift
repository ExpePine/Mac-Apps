// Focus & goal tracker (part of Pomodoro). Needs macOS 13 or later; on older macOS it stays off.
//
// - Start of day: asks for today's goal(s) and this month's goal(s).
// - Top of every hour: "Where was my focus?" with a 5-word entry and a % split across
//   goals, daily responsibilities, time waste and break/other.
// - Websites: reads the front tab of Safari / Chrome-family browsers via AppleScript
//   (Automation permission). The first visit to a site asks why and whether it's work;
//   after that it's only counted. A not-work site visited 2+ times in a day triggers a
//   notification "You've visited <site> N times today".
// - Dashboard: goals vs actual time, said vs seen, hour by hour, websites.
//
// Everything is stored only on this Mac in ~/Library/Application Support/Pomodoro/.

import Cocoa
import SwiftUI
import UserNotifications

// MARK: - Models

@available(macOS 13.0, *)
struct Responsibility: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var text: String
}

/// One slice of an hour: "Goal A — 90%".
@available(macOS 13.0, *)
struct FocusShare: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case monthGoal, dayGoal, responsibility, waste, other
    }
    var label: String
    var kind: Kind
    var percent: Int

    var key: String { FocusShare.key(kind, label) }
    static func key(_ kind: Kind, _ label: String) -> String { kind.rawValue + "|" + label }
}

/// The answer to "Where was my focus?" for one hour.
@available(macOS 13.0, *)
struct FocusHour: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date
    var words: String
    var shares: [FocusShare]
    var skipped: Bool
    var savedAt: Date

    var minutes: Double { max(0, end.timeIntervalSince(start) / 60) }

    var rangeText: String {
        let s = start.formatted(date: .omitted, time: .shortened)
        let e = end.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(e)"
    }
}

/// What you said about a website the first time you visited it.
@available(macOS 13.0, *)
struct SiteInfo: Codable, Equatable {
    var reason: String
    var isWork: Bool
    var firstSeen: Date
}

/// Time in a period, split by how each website was classified.
@available(macOS 13.0, *)
struct SiteSplit: Equatable {
    var work: Double = 0
    var notWork: Double = 0
    var unsorted: Double = 0
    var otherApps: Double = 0

    var browserTotal: Double { work + notWork + unsorted }
    var total: Double { browserTotal + otherApps }
}

func isRealSite(_ s: String) -> Bool { !s.isEmpty && !s.hasPrefix("(") }

func focusDuration(_ seconds: Double) -> String {
    let mins = Int((seconds / 60).rounded())
    return mins >= 60 ? "\(mins / 60)h \(String(format: "%02d", mins % 60))m" : "\(mins)m"
}

enum FocusKeys {
    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    static func month(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: d)
    }
    static func hour(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH"; return f.string(from: d)
    }
}

let focusDirectory: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Pomodoro", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

// MARK: - App & website usage (sampled every 5 s), one file per day: Usage/YYYY-MM-DD.json

@available(macOS 13.0, *)
struct DayUsage: Codable {
    var apps: [String: Double] = [:]      // app name -> active seconds
    var sites: [String: Double] = [:]     // domain -> active seconds
    var hourly: [String: Double] = [:]    // "09" -> active seconds
    var activeSeconds: Double = 0
    var segments: [UsageSegment] = []
}

/// A continuous stretch on one app (and site), in seconds since midnight.
@available(macOS 13.0, *)
struct UsageSegment: Codable, Equatable {
    var start: Int
    var end: Int
    var app: String
    var site: String?
}

@available(macOS 13.0, *)
@MainActor
final class UsageStore {
    let directory: URL
    private var cache: [String: DayUsage] = [:]
    private var dirty = Set<String>()

    init() {
        directory = focusDirectory.appendingPathComponent("Usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    private func load(_ key: String) -> DayUsage {
        if let cached = cache[key] { return cached }
        let day = (try? Data(contentsOf: fileURL(key))).flatMap { try? JSONDecoder().decode(DayUsage.self, from: $0) } ?? DayUsage()
        cache[key] = day
        return day
    }

    func usage(for date: Date) -> DayUsage { load(FocusKeys.day(date)) }

    func add(seconds: Double, app: String, site: String?, at date: Date) {
        let key = FocusKeys.day(date)
        var day = load(key)
        day.apps[app, default: 0] += seconds
        if let site { day.sites[site, default: 0] += seconds }
        let hour = String(format: "%02d", Calendar.current.component(.hour, from: date))
        day.hourly[hour, default: 0] += seconds
        day.activeSeconds += seconds

        let midnight = Calendar.current.startOfDay(for: date)
        let end = Int(date.timeIntervalSince(midnight))
        let start = max(0, end - Int(seconds.rounded()))
        if var last = day.segments.last, last.app == app, last.site == site, start - last.end <= 20 {
            last.end = end
            day.segments[day.segments.count - 1] = last
        } else {
            day.segments.append(UsageSegment(start: start, end: end, app: app, site: site))
        }
        cache[key] = day
        dirty.insert(key)
    }

    func flush() {
        for key in dirty {
            if let day = cache[key], let data = try? JSONEncoder().encode(day) {
                try? data.write(to: fileURL(key), options: .atomic)
            }
        }
        dirty.removeAll()
        let keep: Set<String> = [FocusKeys.day(Date()), FocusKeys.day(Date().addingTimeInterval(-86_400))]
        cache = cache.filter { keep.contains($0.key) }
    }
}

/// Reads the front tab's URL with AppleScript. Runs on a background queue.
@available(macOS 13.0, *)
final class BrowserScripter {
    enum Result {
        case page(url: String, isPrivate: Bool)
        case noWindow
        case denied
        case failed
    }

    static let safariIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let chromiumIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", "org.chromium.Chromium", "com.operasoftware.Opera",
    ]

    static func isScriptable(_ bundleID: String) -> Bool {
        safariIDs.contains(bundleID) || chromiumIDs.contains(bundleID)
    }

    private var cache: [String: NSAppleScript] = [:]

    private static func source(for id: String) -> String {
        if safariIDs.contains(id) {
            return """
            tell application id "\(id)"
                if (count of windows) is 0 then return ""
                return (URL of current tab of front window) & linefeed & "normal"
            end tell
            """
        }
        return """
        tell application id "\(id)"
            if (count of windows) is 0 then return ""
            set w to front window
            set m to "normal"
            try
                set m to (mode of w) as text
            end try
            return (URL of active tab of w) & linefeed & m
        end tell
        """
    }

    func fetch(bundleID: String) -> Result {
        let script: NSAppleScript
        if let cached = cache[bundleID] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: Self.source(for: bundleID)) else { return .failed }
            var compileError: NSDictionary?
            guard s.compileAndReturnError(&compileError) else { return .failed }
            cache[bundleID] = s
            script = s
        }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: not permitted, -1744: would need user consent
            return (code == -1743 || code == -1744) ? .denied : .failed
        }
        let text = output.stringValue ?? ""
        if text.isEmpty { return .noWindow }
        let parts = text.components(separatedBy: "\n")
        return .page(url: parts[0], isPrivate: parts.count > 1 && parts[1].lowercased() == "incognito")
    }
}

/// Samples the frontmost app every 5 s; for browsers, asks for the front tab's domain.
@available(macOS 13.0, *)
@MainActor
final class FocusTracker: ObservableObject {
    @Published private(set) var today = DayUsage()
    /// Browsers that refused Automation permission.
    @Published private(set) var deniedBrowsers: [String] = []

    let usage = UsageStore()
    /// A website came to the front after being away from it for `visitGap` (or first time since launch).
    var onSiteVisit: ((String) -> Void)?
    var paused = false

    private let scripter = BrowserScripter()
    private let scriptQueue = DispatchQueue(label: "Pomodoro.browser-scripts")
    private var inFlight = Set<String>()
    private var lastKnownSite: [String: String] = [:]
    private var lastSample = Date()
    private var lastFlush = Date()
    private var loop: Task<Void, Never>?
    private let sampleSeconds: Double = 5
    private let idleLimit: Double = 120
    private let visitGap: TimeInterval = 180
    private var frontSite: String?
    private var lastSeenSite: [String: Date] = [:]

    init() {
        today = usage.usage(for: Date())
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.tick()
            }
        }
    }

    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func tick() {
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastSample), sampleSeconds * 3)   // don't count sleep gaps
        lastSample = now
        if now.timeIntervalSince(lastFlush) > 60 { flush(); lastFlush = now }
        guard !paused, elapsed > 0, Self.idleSeconds < idleLimit else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? ""

        guard BrowserScripter.isScriptable(bundleID) else {
            record(elapsed, app: name, site: nil, at: now)
            return
        }
        // Lookup still running (browser busy or permission prompt open): credit the last known site.
        if inFlight.contains(bundleID) {
            record(elapsed, app: name, site: lastKnownSite[bundleID], at: now)
            return
        }
        inFlight.insert(bundleID)
        let scripter = self.scripter
        let queue = scriptQueue
        Task { [weak self] in
            let result: BrowserScripter.Result = await withCheckedContinuation { cont in
                queue.async { cont.resume(returning: scripter.fetch(bundleID: bundleID)) }
            }
            self?.finish(bundleID: bundleID, app: name, elapsed: elapsed, at: now, result: result)
        }
    }

    private func finish(bundleID: String, app: String, elapsed: Double, at date: Date, result: BrowserScripter.Result) {
        inFlight.remove(bundleID)
        var site: String?
        switch result {
        case .page(let url, let isPrivate):
            site = Self.siteLabel(url: url, isPrivate: isPrivate)
            lastKnownSite[bundleID] = site
            deniedBrowsers.removeAll { $0 == app }
        case .denied:
            if !deniedBrowsers.contains(app) { deniedBrowsers.append(app) }
        case .noWindow, .failed:
            break
        }
        record(elapsed, app: app, site: site, at: date)
    }

    static func siteLabel(url: String, isPrivate: Bool) -> String {
        if isPrivate { return "(private window)" }
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", var host = u.host?.lowercased() else {
            return "(browser page)"
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func record(_ seconds: Double, app: String, site: String?, at date: Date) {
        usage.add(seconds: seconds, app: app, site: site, at: date)
        today = usage.usage(for: Date())
        let current = site.flatMap { isRealSite($0) ? $0 : nil }
        if let current, current != frontSite {
            let away = lastSeenSite[current].map { date.timeIntervalSince($0) } ?? .infinity
            if away > visitGap { onSiteVisit?(current) }
        }
        frontSite = current
        if let current { lastSeenSite[current] = date }
    }

    func flush() { usage.flush() }
}

// MARK: - Goals, hours, responsibilities, sites: focus.json

@available(macOS 13.0, *)
@MainActor
final class FocusStore: ObservableObject {
    /// "yyyy-MM-dd" -> today's goals
    @Published private(set) var dayGoals: [String: [String]] = [:]
    /// "yyyy-MM" -> this month's goals
    @Published private(set) var monthGoals: [String: [String]] = [:]
    @Published private(set) var responsibilities: [Responsibility] = []
    @Published private(set) var hours: [FocusHour] = []
    @Published private(set) var sites: [String: SiteInfo] = [:]
    /// "yyyy-MM-dd" -> domain -> visits that day
    @Published private(set) var visits: [String: [String: Int]] = [:]

    @Published var hourlyEnabled: Bool { didSet { UserDefaults.standard.set(hourlyEnabled, forKey: Keys.hourly) } }
    @Published var askNewSites: Bool { didSet { UserDefaults.standard.set(askNewSites, forKey: Keys.askSites) } }
    @Published var nagNonWork: Bool { didSet { UserDefaults.standard.set(nagNonWork, forKey: Keys.nag) } }

    let fileURL = focusDirectory.appendingPathComponent("focus.json")

    private enum Keys {
        static let hourly = "focusHourly"
        static let askSites = "focusAskNewSites"
        static let nag = "focusNagNonWork"
    }

    private struct FileFormat: Codable {
        var dayGoals: [String: [String]]
        var monthGoals: [String: [String]]
        var responsibilities: [Responsibility]
        var hours: [FocusHour]
        var sites: [String: SiteInfo]
        var visits: [String: [String: Int]]
    }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [Keys.hourly: true, Keys.askSites: true, Keys.nag: true])
        hourlyEnabled = d.bool(forKey: Keys.hourly)
        askNewSites = d.bool(forKey: Keys.askSites)
        nagNonWork = d.bool(forKey: Keys.nag)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let file = try? decoder.decode(FileFormat.self, from: data) {
            dayGoals = file.dayGoals
            monthGoals = file.monthGoals
            responsibilities = file.responsibilities
            hours = file.hours
            sites = file.sites
            visits = file.visits
        }
    }

    // MARK: Goals

    var todayGoals: [String] { dayGoals[FocusKeys.day(Date())] ?? [] }
    var thisMonthGoals: [String] { monthGoals[FocusKeys.month(Date())] ?? [] }
    /// Last month's goals, offered when a new month starts.
    var previousMonthGoals: [String] {
        let prev = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return monthGoals[FocusKeys.month(prev)] ?? []
    }
    var yesterdayGoals: [String] {
        let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return dayGoals[FocusKeys.day(y)] ?? []
    }

    func setGoals(today: [String], month: [String]) {
        func clean(_ a: [String]) -> [String] {
            var seen = Set<String>()
            return a.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        dayGoals[FocusKeys.day(Date())] = clean(today)
        monthGoals[FocusKeys.month(Date())] = clean(month)
        save()
    }

    // MARK: Responsibilities

    func addResponsibility(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !responsibilities.contains(where: { $0.text == t }) else { return }
        responsibilities.append(Responsibility(text: t))
        save()
    }

    func removeResponsibility(_ id: UUID) {
        responsibilities.removeAll { $0.id == id }
        save()
    }

    // MARK: Hours

    func saveHour(_ hour: FocusHour) {
        hours.removeAll { abs($0.start.timeIntervalSince(hour.start)) < 1 }
        hours.append(hour)
        hours.sort { $0.start < $1.start }
        save()
    }

    func hasHour(start: Date) -> Bool { hours.contains { abs($0.start.timeIntervalSince(start)) < 1 } }

    func hours(on day: Date) -> [FocusHour] { hours.filter { Calendar.current.isDate($0.start, inSameDayAs: day) } }

    /// Most recent answered hour, used to pre-fill the next split.
    var lastAnswered: FocusHour? { hours.last(where: { !$0.skipped }) }

    // MARK: Sites

    func classify(_ domain: String, reason: String, isWork: Bool) {
        let first = sites[domain]?.firstSeen ?? Date()
        sites[domain] = SiteInfo(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                                 isWork: isWork, firstSeen: first)
        save()
    }

    func forget(_ domain: String) {
        sites[domain] = nil
        save()
    }

    /// Counts one visit today and returns today's total for that site.
    @discardableResult
    func recordVisit(_ domain: String, at date: Date = Date()) -> Int {
        let key = FocusKeys.day(date)
        var day = visits[key] ?? [:]
        day[domain, default: 0] += 1
        visits[key] = day
        if visits.count > 60 {   // keep 60 days of counts
            for old in visits.keys.sorted().dropLast(60) { visits[old] = nil }
        }
        save()
        return day[domain] ?? 1
    }

    func visits(on day: Date) -> [String: Int] { visits[FocusKeys.day(day)] ?? [:] }

    /// Time between start and end (same day), split by site classification.
    func split(_ usage: DayUsage, from start: Date, to end: Date) -> SiteSplit {
        let midnight = Calendar.current.startOfDay(for: start)
        let s0 = Int(start.timeIntervalSince(midnight))
        let s1 = Int(end.timeIntervalSince(midnight))
        var out = SiteSplit()
        for seg in usage.segments {
            let overlap = Double(max(0, min(seg.end, s1) - max(seg.start, s0)))
            if overlap > 0 { add(overlap, site: seg.site, to: &out) }
        }
        return out
    }

    /// Whole-day split.
    func daySplit(_ usage: DayUsage) -> SiteSplit {
        var out = SiteSplit()
        var siteSeconds = 0.0
        for (site, secs) in usage.sites {
            add(secs, site: site, to: &out)
            siteSeconds += secs
        }
        out.otherApps += max(0, usage.activeSeconds - siteSeconds)
        return out
    }

    private func add(_ secs: Double, site: String?, to out: inout SiteSplit) {
        guard let site, isRealSite(site) else { out.otherApps += secs; return }
        switch sites[site]?.isWork {
        case .some(true): out.work += secs
        case .some(false): out.notWork += secs
        case .none: out.unsorted += secs
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = FileFormat(dayGoals: dayGoals, monthGoals: monthGoals, responsibilities: responsibilities,
                              hours: hours, sites: sites, visits: visits)
        if let data = try? encoder.encode(file) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Totals for the dashboard

@available(macOS 13.0, *)
struct FocusTotals {
    /// FocusShare.key -> minutes
    var minutes: [String: Double] = [:]
    /// FocusShare.key -> label and kind (percent unused)
    var labels: [String: FocusShare] = [:]
    var loggedMinutes: Double = 0
    var answered = 0
    var skipped = 0

    init(_ hours: [FocusHour]) {
        for h in hours {
            if h.skipped { skipped += 1; continue }
            answered += 1
            loggedMinutes += h.minutes
            for s in h.shares {
                minutes[s.key, default: 0] += h.minutes * Double(s.percent) / 100
                labels[s.key] = FocusShare(label: s.label, kind: s.kind, percent: 0)
            }
        }
    }

    func minutes(_ kind: FocusShare.Kind, _ label: String) -> Double { minutes[FocusShare.key(kind, label)] ?? 0 }

    func fraction(_ kind: FocusShare.Kind, _ label: String) -> Double {
        loggedMinutes > 0 ? minutes(kind, label) / loggedMinutes : 0
    }
}

// MARK: - Coordinator: morning goals, hourly question, site questions, nudges, windows

@available(macOS 13.0, *)
@MainActor
final class FocusCenter: NSObject, NSWindowDelegate, UNUserNotificationCenterDelegate {
    enum SiteAnswer { case work(String), notWork(String), later }

    static let wasteLabel = "Time waste"
    static let otherLabel = "Break / other"
    private static let lastAskedKey = "focusLastAskedHour"
    private static let dayOffKey = "focusDayOff"
    static let siteKey = "focusSite"

    // Created in start() (not as default values) so the NSObject init stays nonisolated.
    private(set) var store: FocusStore!
    private(set) var tracker: FocusTracker!

    private var loop: Task<Void, Never>?
    private var goalsWindow: NSWindow?
    private var hourWindow: NSWindow?
    private var siteWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private var goalsSnoozedUntil: Date?
    private var siteQueue: [String] = []
    private var askingSite: String?
    private var siteSnoozed: [String: Date] = [:]

    func start() {
        store = FocusStore()
        tracker = FocusTracker()
        tracker.onSiteVisit = { [weak self] d in self?.siteVisited(d) }
        tracker.paused = isDayOff
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func stop() { tracker.flush() }

    var isDayOff: Bool { UserDefaults.standard.string(forKey: Self.dayOffKey) == FocusKeys.day(Date()) }

    /// After 5 am, today's and this month's goals must be set before hourly check-ins start.
    var needsGoals: Bool {
        guard !isDayOff, Calendar.current.component(.hour, from: Date()) >= 5 else { return false }
        return store.todayGoals.isEmpty || store.thisMonthGoals.isEmpty
    }

    private var anyPromptOpen: Bool { goalsWindow != nil || hourWindow != nil || siteWindow != nil }

    private func tick() {
        tracker.paused = isDayOff
        guard !isDayOff else { return }
        let idle = FocusTracker.idleSeconds
        if needsGoals {
            if idle < 300, !anyPromptOpen, (goalsSnoozedUntil ?? .distantPast) < Date() { showGoals() }
            return
        }
        hourlyTick(idle: idle)
    }

    // MARK: Morning goals

    func showGoals() {
        if let goalsWindow { bringToFront(goalsWindow); return }
        let view = FocusGoalsView(store: store,
                                  onSave: { [weak self] today, month in
                                      guard let self else { return }
                                      self.store.setGoals(today: today, month: month)
                                      self.goalsSnoozedUntil = nil
                                      UserDefaults.standard.removeObject(forKey: Self.dayOffKey)
                                      self.closeGoals()
                                      // The first hourly question comes at the next full hour.
                                      if let h = Calendar.current.dateInterval(of: .hour, for: Date())?.start {
                                          UserDefaults.standard.set(FocusKeys.hour(h.addingTimeInterval(-3600)),
                                                                    forKey: Self.lastAskedKey)
                                      }
                                  },
                                  onLater: { [weak self] in
                                      self?.goalsSnoozedUntil = Date().addingTimeInterval(600)
                                      self?.closeGoals()
                                  },
                                  onDayOff: { [weak self] in
                                      UserDefaults.standard.set(FocusKeys.day(Date()), forKey: Self.dayOffKey)
                                      self?.tracker.paused = true
                                      self?.closeGoals()
                                  })
        goalsWindow = makeWindow("Plan your day", view, closable: false, floating: true)
        goalsWindow?.center()
        bringToFront(goalsWindow!)
    }

    private func closeGoals() {
        goalsWindow?.close()
        goalsWindow = nil
        showNextSite()
    }

    // MARK: Hourly "Where was my focus?"

    /// At the top of each hour, ask about the hour that just ended: once you're at the Mac,
    /// within 50 minutes, and only if you were active for 10+ minutes of it.
    private func hourlyTick(idle: Double) {
        guard store.hourlyEnabled, hourWindow == nil else { return }
        let now = Date()
        guard let thisHour = Calendar.current.dateInterval(of: .hour, for: now)?.start else { return }
        let prevStart = thisHour.addingTimeInterval(-3600)
        let key = FocusKeys.hour(prevStart)
        let d = UserDefaults.standard
        guard d.string(forKey: Self.lastAskedKey) != key else { return }
        guard now.timeIntervalSince(thisHour) < 50 * 60 else { return }
        if store.hasHour(start: prevStart) { d.set(key, forKey: Self.lastAskedKey); return }
        let hh = String(format: "%02d", Calendar.current.component(.hour, from: prevStart))
        if (tracker.usage.usage(for: prevStart).hourly[hh] ?? 0) < 10 * 60 {
            d.set(key, forKey: Self.lastAskedKey)   // away most of that hour: don't ask
            return
        }
        guard idle < 300, !anyPromptOpen else { return }
        d.set(key, forKey: Self.lastAskedKey)
        openHour(start: prevStart, end: thisHour)
    }

    /// Menu: the last full hour if it hasn't been answered, otherwise this hour so far.
    func checkInNow() {
        if let hourWindow { bringToFront(hourWindow); return }
        if needsGoals { showGoals(); return }
        let now = Date()
        guard let thisHour = Calendar.current.dateInterval(of: .hour, for: now)?.start else { return }
        let prevStart = thisHour.addingTimeInterval(-3600)
        if !store.hasHour(start: prevStart) {
            UserDefaults.standard.set(FocusKeys.hour(prevStart), forKey: Self.lastAskedKey)
            openHour(start: prevStart, end: thisHour)
        } else {
            openHour(start: thisHour, end: max(now, thisHour.addingTimeInterval(60)))
        }
    }

    /// Rows of the split: month goals, today's goals, responsibilities, time waste, break/other.
    func rows() -> [FocusHourModel.Row] {
        let month = store.thisMonthGoals
        var rows: [FocusHourModel.Row] = month.map { .init(label: $0, kind: .monthGoal) }
        rows += store.todayGoals.filter { !month.contains($0) }.map { .init(label: $0, kind: .dayGoal) }
        rows += store.responsibilities.map { .init(label: $0.text, kind: .responsibility) }
        rows.append(.init(label: Self.wasteLabel, kind: .waste))
        rows.append(.init(label: Self.otherLabel, kind: .other))
        return rows
    }

    private func openHour(start: Date, end: Date) {
        let model = FocusHourModel(start: start, end: end, rows: rows(), previous: store.lastAnswered,
                                   split: store.split(tracker.usage.usage(for: start), from: start, to: end))
        model.onDone = { [weak self] hour in
            guard let self else { return }
            self.store.saveHour(hour)
            self.hourWindow?.close()
            self.hourWindow = nil
            self.showNextSite()
        }
        model.onOpenDashboard = { [weak self] in self?.showDashboard() }
        hourWindow = makeWindow("Where was my focus?", FocusHourView(model: model), closable: false, floating: true)
        hourWindow?.center()
        bringToFront(hourWindow!)
    }

    // MARK: Websites

    private func siteVisited(_ domain: String) {
        guard isRealSite(domain), !isDayOff else { return }
        let count = store.recordVisit(domain)
        if let info = store.sites[domain] {
            if !info.isWork, store.nagNonWork, count >= 2 { notifyRepeat(domain, count: count, info: info) }
        } else if store.askNewSites {
            if let until = siteSnoozed[domain], Date() < until { return }
            guard askingSite != domain, !siteQueue.contains(domain) else { return }
            siteQueue.append(domain)
            showNextSite()
        }
    }

    private func showNextSite() {
        guard askingSite == nil, goalsWindow == nil, hourWindow == nil else { return }
        while let next = siteQueue.first {
            siteQueue.removeFirst()
            guard store.sites[next] == nil else { continue }
            askingSite = next
            let goals = store.todayGoals + store.thisMonthGoals
            let view = SiteQuestionView(domain: next, goals: goals) { [weak self] answer in
                self?.siteAnswered(next, answer)
            }
            let w = makeWindow("New website", view, closable: false, floating: true)
            placeTopRight(w)
            siteWindow = w
            bringToFront(w)
            return
        }
    }

    private func siteAnswered(_ domain: String, _ answer: SiteAnswer) {
        switch answer {
        case .work(let reason): store.classify(domain, reason: reason, isWork: true)
        case .notWork(let reason): store.classify(domain, reason: reason, isWork: false)
        case .later: siteSnoozed[domain] = Date().addingTimeInterval(30 * 60)
        }
        askingSite = nil
        siteWindow?.close()
        siteWindow = nil
        showNextSite()
    }

    private func notifyRepeat(_ domain: String, count: Int, info: SiteInfo) {
        let content = UNMutableNotificationContent()
        content.title = "You've visited \(domain) \(count) times today"
        var body = info.reason.isEmpty ? "You marked it as not work." : "You said: \(info.reason)"
        if let goal = store.todayGoals.first { body += "\nToday's goal: \(goal)" }
        content.body = body
        content.sound = .default
        content.userInfo = [Self.siteKey: domain]
        // One notification per site: the newest count replaces the older one.
        let request = UNNotificationRequest(identifier: "visit-\(domain)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            self?.showDashboard()
            completionHandler()
        }
    }

    // MARK: Dashboard

    func showDashboard() {
        if dashboardWindow == nil {
            let view = FocusDashboardView(center: self, store: store, tracker: tracker)
            let w = makeWindow("Focus", view, closable: true, floating: false)
            w.styleMask.insert(.resizable)
            w.styleMask.insert(.miniaturizable)
            w.setContentSize(NSSize(width: 760, height: 720))
            w.setFrameAutosaveName("FocusDashboard")
            if !w.setFrameUsingName("FocusDashboard") { w.center() }
            w.delegate = self
            dashboardWindow = w
        }
        bringToFront(dashboardWindow!)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        Task { @MainActor [weak self] in
            if let self, let window, window === self.dashboardWindow { self.dashboardWindow = nil }
        }
    }

    // MARK: Window helpers

    private func makeWindow<V: View>(_ title: String, _ view: V, closable: Bool, floating: Bool) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = closable ? [.titled, .closable] : [.titled]
        if floating {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        window.isReleasedWhenClosed = false
        return window
    }

    private func placeTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { window.center(); return }
        let vf = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 8))
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Hooks used by main.swift

/// Holds the FocusCenter (typed as AnyObject so main.swift still builds for macOS 10.15).
var focusCenterRef: AnyObject?

extension AppDelegate {
    func startFocusTracker() {
        guard #available(macOS 13.0, *) else { return }
        let center = FocusCenter()
        focusCenterRef = center
        center.start()
    }

    func stopFocusTracker() {
        if #available(macOS 13.0, *) { (focusCenterRef as? FocusCenter)?.stop() }
    }

    func addFocusMenuItems(to menu: NSMenu) {
        guard #available(macOS 13.0, *) else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Where was my focus?…", action: #selector(focusCheckIn), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Today's Goals…", action: #selector(focusGoals), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Focus Dashboard…", action: #selector(focusDashboard), keyEquivalent: "").target = self
    }

    @objc func focusCheckIn() {
        if #available(macOS 13.0, *) { (focusCenterRef as? FocusCenter)?.checkInNow() }
    }

    @objc func focusGoals() {
        if #available(macOS 13.0, *) { (focusCenterRef as? FocusCenter)?.showGoals() }
    }

    @objc func focusDashboard() {
        if #available(macOS 13.0, *) { (focusCenterRef as? FocusCenter)?.showDashboard() }
    }
}
