import AppKit
import CoreGraphics
import Foundation

// MARK: - One day's usage totals

struct DayUsage: Codable {
    var apps: [String: Double] = [:]      // app name -> active seconds
    var sites: [String: Double] = [:]     // domain -> active seconds
    var hourly: [String: Double] = [:]    // "09" -> active seconds
    var activeSeconds: Double = 0
    var firstActive: Date?
    var lastActive: Date?
    /// When each app/site was in front, as seconds since midnight (recorded from this version on).
    var segments: [UsageSegment]? = nil

    func top(_ dict: [String: Double], _ n: Int) -> [(name: String, seconds: Double)] {
        dict.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }
}

/// A continuous stretch on one app (and site), in seconds since midnight.
struct UsageSegment: Codable, Equatable {
    var start: Int
    var end: Int
    var app: String
    var site: String?

    var seconds: Int { max(0, end - start) }
}

func durationText(_ seconds: Double) -> String {
    let mins = Int((seconds / 60).rounded())
    return mins >= 60 ? "\(mins / 60)h \(String(format: "%02d", mins % 60))m" : "\(mins)m"
}

// MARK: - Storage: Usage/YYYY-MM-DD.json

@MainActor
final class UsageStore {
    let directory: URL
    private var cache: [String: DayUsage] = [:]
    private var dirty = Set<String>()

    init(baseDirectory: URL) {
        directory = baseDirectory.appendingPathComponent("Usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    private func load(_ key: String) -> DayUsage {
        if let cached = cache[key] { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let day = (try? Data(contentsOf: fileURL(key))).flatMap { try? decoder.decode(DayUsage.self, from: $0) } ?? DayUsage()
        cache[key] = day
        return day
    }

    func usage(for date: Date) -> DayUsage { load(Self.key(date)) }

    func add(seconds: Double, app: String, site: String?, at date: Date) {
        let key = Self.key(date)
        var day = load(key)
        day.apps[app, default: 0] += seconds
        if let site { day.sites[site, default: 0] += seconds }
        let hour = String(format: "%02d", Calendar.current.component(.hour, from: date))
        day.hourly[hour, default: 0] += seconds
        day.activeSeconds += seconds
        if day.firstActive == nil { day.firstActive = date }
        day.lastActive = date

        // Extend the last segment if it's the same app/site and continuous; else start a new one.
        let midnight = Calendar.current.startOfDay(for: date)
        let end = Int(date.timeIntervalSince(midnight))
        let start = max(0, end - Int(seconds.rounded()))
        var segs = day.segments ?? []
        if var last = segs.last, last.app == app, last.site == site, start - last.end <= 20 {
            last.end = end
            segs[segs.count - 1] = last
        } else {
            segs.append(UsageSegment(start: start, end: end, app: app, site: site))
        }
        day.segments = segs
        cache[key] = day
        dirty.insert(key)
    }

    func flush() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for key in dirty {
            if let day = cache[key], let data = try? encoder.encode(day) {
                try? data.write(to: fileURL(key), options: .atomic)
            }
        }
        dirty.removeAll()
        // keep only today and yesterday in memory
        let keep: Set<String> = [Self.key(Date()), Self.key(Date().addingTimeInterval(-86_400))]
        cache = cache.filter { keep.contains($0.key) }
    }
}

// MARK: - Browser tab lookup via AppleScript (runs on a background queue)

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
            // -1743: not permitted, -1744: would require user consent
            return (code == -1743 || code == -1744) ? .denied : .failed
        }
        let text = output.stringValue ?? ""
        if text.isEmpty { return .noWindow }
        let parts = text.components(separatedBy: "\n")
        return .page(url: parts[0], isPrivate: parts.count > 1 && parts[1].lowercased() == "incognito")
    }
}

// MARK: - Tracker: samples the frontmost app every few seconds

@MainActor
final class UsageTracker: ObservableObject {
    @Published private(set) var today = DayUsage()
    /// Browsers that refused Automation permission.
    @Published private(set) var deniedBrowsers: [String] = []

    private let settings: SettingsStore
    let usage: UsageStore
    private let scripter = BrowserScripter()
    private let scriptQueue = DispatchQueue(label: "ActivityLogger.browser-scripts")
    private var inFlight = Set<String>()
    private var lastKnownSite: [String: String] = [:]
    private var lastSample = Date()
    private var lastFlush = Date()
    private var loop: Task<Void, Never>?

    private let sampleSeconds: UInt64 = 5

    init(settings: SettingsStore, usage: UsageStore) {
        self.settings = settings
        self.usage = usage
        today = usage.usage(for: Date())
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.sampleSeconds ?? 5) * 1_000_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        // Cap the credited time so sleep/wake gaps aren't counted.
        let elapsed = min(now.timeIntervalSince(lastSample), Double(sampleSeconds) * 3)
        lastSample = now

        if now.timeIntervalSince(lastFlush) > 60 {
            usage.flush()
            lastFlush = now
        }

        guard settings.trackUsage, elapsed > 0 else { return }

        // Idle check: seconds since any keyboard/mouse input.
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard idle < Double(settings.idleMinutes * 60) else { return }

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? ""

        guard BrowserScripter.isScriptable(bundleID) else {
            record(elapsed, app: name, site: nil, at: now)
            return
        }

        // A previous lookup is still running (browser busy or permission prompt open):
        // credit the last known site instead of piling up requests.
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
            self?.finishBrowserSample(bundleID: bundleID, app: name, elapsed: elapsed, at: now, result: result)
        }
    }

    private func finishBrowserSample(bundleID: String, app: String, elapsed: Double, at date: Date,
                                     result: BrowserScripter.Result) {
        inFlight.remove(bundleID)
        var site: String?
        switch result {
        case .page(let url, let isPrivate):
            site = siteLabel(url: url, isPrivate: isPrivate)
            lastKnownSite[bundleID] = site
            deniedBrowsers.removeAll { $0 == app }
        case .denied:
            if !deniedBrowsers.contains(app) { deniedBrowsers.append(app) }
        case .noWindow, .failed:
            break
        }
        record(elapsed, app: app, site: site, at: date)
    }

    private func siteLabel(url: String, isPrivate: Bool) -> String {
        if isPrivate { return "(private window)" }
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", var host = u.host?.lowercased() else {
            return "(browser page)"
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let excluded = settings.excludedDomains
            .lowercased()
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { String($0).replacingOccurrences(of: "www.", with: "") }
            .filter { !$0.isEmpty }
        if excluded.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return "(excluded site)"
        }
        return host
    }

    private func record(_ seconds: Double, app: String, site: String?, at date: Date) {
        usage.add(seconds: seconds, app: app, site: site, at: date)
        today = usage.usage(for: Date())
    }

    func flush() { usage.flush() }
}

// MARK: - One-time move of data out of the old sandbox container

enum SandboxMigration {
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        let doneKey = "migratedFromSandbox"
        guard !defaults.bool(forKey: doneKey) else { return }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let container = home.appendingPathComponent("Library/Containers/com.raj.ActivityLogger/Data/Library")
        let oldSupport = container.appendingPathComponent("Application Support/ActivityLogger")
        let newSupport = home.appendingPathComponent("Library/Application Support/ActivityLogger")

        // Entries + voice notes
        if fm.fileExists(atPath: oldSupport.path),
           !fm.fileExists(atPath: newSupport.appendingPathComponent("entries.json").path) {
            try? fm.createDirectory(at: newSupport.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: newSupport.path) {
                // Directory exists but has no entries — copy item by item.
                let items = (try? fm.contentsOfDirectory(at: oldSupport, includingPropertiesForKeys: nil)) ?? []
                for item in items {
                    let dest = newSupport.appendingPathComponent(item.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: item, to: dest) }
                }
            } else {
                try? fm.copyItem(at: oldSupport, to: newSupport)
            }
        }

        // Settings
        let oldPrefs = container.appendingPathComponent("Preferences/com.raj.ActivityLogger.plist")
        if let dict = NSDictionary(contentsOf: oldPrefs) as? [String: Any] {
            for (key, value) in dict where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
