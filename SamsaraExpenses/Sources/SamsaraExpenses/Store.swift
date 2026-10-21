import AppKit
import Combine
import SamsaraCore
import ServiceManagement
import UniformTypeIdentifiers

enum SettingsKey {
    static let pageURL = "pageURL"
    static let autoSync = "autoSync"
    static let intervalMinutes = "intervalMinutes"
    static let syncOnLaunch = "syncOnLaunch"
    static let lastSync = "lastSync"
    static let lastSource = "lastSource"
}

@MainActor
final class Store: ObservableObject {

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case ok(String)
        case needsSignIn(String)
        case failed(String)

        var message: String {
            switch self {
            case .idle: return "Not synced yet"
            case .syncing: return "Downloading from Samsara…"
            case .ok(let m), .needsSignIn(let m), .failed(let m): return m
            }
        }
    }

    static let defaultPageURL = "https://rajakrishna.in/samsara/"

    @Published private(set) var expenses: [Expense] = []
    @Published private(set) var warnings: [String] = []
    @Published var period: Period = .all
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var lastSync: Date?
    @Published private(set) var sourceNote = ""

    let analyzer = Analyzer()
    private let fetcher = SamsaraFetcher()
    private let persist: Bool
    private var timer: Timer?
    private var lastAttempt: Date?
    private var wakeObserver: NSObjectProtocol?

    init(persist: Bool = true) {
        self.persist = persist
        UserDefaults.standard.register(defaults: [
            SettingsKey.pageURL: Store.defaultPageURL,
            SettingsKey.autoSync: true,
            SettingsKey.intervalMinutes: 60,
            SettingsKey.syncOnLaunch: true,
        ])
        if persist { loadSaved() }
    }

    // MARK: Settings

    var pageURL: String { UserDefaults.standard.string(forKey: SettingsKey.pageURL) ?? Store.defaultPageURL }
    var autoSync: Bool { UserDefaults.standard.bool(forKey: SettingsKey.autoSync) }
    var intervalMinutes: Int { max(5, UserDefaults.standard.integer(forKey: SettingsKey.intervalMinutes)) }
    var syncOnLaunch: Bool { UserDefaults.standard.bool(forKey: SettingsKey.syncOnLaunch) }

    var nextSync: Date? {
        guard autoSync else { return nil }
        let ref = [lastAttempt, lastSync].compactMap { $0 }.max() ?? Date()
        return ref.addingTimeInterval(TimeInterval(intervalMinutes * 60))
    }

    // MARK: Derived data for views

    var availablePeriods: [Period] { [.all, .lastDays(30)] + analyzer.months(in: expenses) }
    var interval: DateInterval? { analyzer.interval(for: period) }
    var current: [Expense] { analyzer.filter(expenses, in: interval) }
    var previous: [Expense] {
        analyzer.previousInterval(for: period).map { analyzer.filter(expenses, in: $0) } ?? []
    }

    // MARK: Scheduling

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        if autoSync && syncOnLaunch {
            Task { await sync() }
        }
    }

    private func tick() {
        guard autoSync, status != .syncing else { return }
        let ref = [lastAttempt, lastSync].compactMap { $0 }.max() ?? .distantPast
        if Date().timeIntervalSince(ref) >= TimeInterval(intervalMinutes * 60) {
            Task { await sync() }
        }
    }

    // MARK: Sync / import / export

    func sync() async {
        guard status != .syncing else { return }
        let raw = pageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme, scheme.hasPrefix("http") else {
            status = .failed("The Samsara page URL in Settings isn't valid.")
            return
        }
        status = .syncing
        lastAttempt = Date()
        do {
            let text = try await fetcher.fetch(url: url)
            let n = try ingest(text, source: "Auto-downloaded from \(url.host ?? "Samsara")")
            status = .ok("Synced \(n) entries")
        } catch let err as SamsaraFetcher.FetchError {
            switch err {
            case .needsSignIn, .noData: status = .needsSignIn(err.localizedDescription)
            default: status = .failed(err.localizedDescription)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func ingest(_ text: String, source: String) throws -> Int {
        let result = try ExpenseParser.parse(text: text)
        guard !result.expenses.isEmpty else { throw ParseError.empty }
        if persist { try save(text) }
        apply(result)
        lastSync = Date()
        sourceNote = source
        if persist {
            UserDefaults.standard.set(lastSync, forKey: SettingsKey.lastSync)
            UserDefaults.standard.set(source, forKey: SettingsKey.lastSource)
        }
        return result.expenses.count
    }

    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let n = try ingest(String(decoding: data, as: UTF8.self), source: "Imported \(url.lastPathComponent)")
            status = .ok("Imported \(n) entries")
        } catch {
            status = .failed("Couldn't import \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CSV downloaded from Samsara (📥)"
        if panel.runModal() == .OK, let url = panel.url { importFile(url) }
    }

    func exportWithPanel(_ items: [Expense], name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ExpenseParser.csv(for: items).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                status = .failed("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ result: ParseResult) {
        expenses = result.expenses.sorted { $0.sortDate > $1.sortDate }
        warnings = result.warnings
        if !availablePeriods.contains(period) || period == .all && lastSync == nil {
            period = defaultPeriod()
        }
    }

    func defaultPeriod() -> Period {
        let thisMonth = analyzer.period(containing: Date())
        let months = analyzer.months(in: expenses)
        if months.contains(thisMonth) { return thisMonth }
        return months.first ?? .all
    }

    // MARK: Storage (~/Library/Application Support/SamsaraExpenses)

    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SamsaraExpenses", isDirectory: true)
    }

    private var latestFile: URL { Store.dataDirectory.appendingPathComponent("latest.csv") }

    private func save(_ text: String) throws {
        let dir = Store.dataDirectory
        let archive = dir.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try text.write(to: latestFile, atomically: true, encoding: .utf8)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // One snapshot per day, so you can go back to an older export.
        try? text.write(to: archive.appendingPathComponent("samsara-expenses-\(f.string(from: Date())).csv"),
                        atomically: true, encoding: .utf8)
    }

    private func loadSaved() {
        guard let data = try? Data(contentsOf: latestFile),
              let result = try? ExpenseParser.parse(text: String(decoding: data, as: UTF8.self)) else { return }
        expenses = result.expenses.sorted { $0.sortDate > $1.sortDate }
        warnings = result.warnings
        lastSync = UserDefaults.standard.object(forKey: SettingsKey.lastSync) as? Date
        sourceNote = UserDefaults.standard.string(forKey: SettingsKey.lastSource) ?? "Saved data"
        period = defaultPeriod()
        if let lastSync { status = .ok("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))") }
    }

    func clearData() {
        try? FileManager.default.removeItem(at: latestFile)
        expenses = []
        warnings = []
        lastSync = nil
        sourceNote = ""
        status = .idle
        period = .all
        UserDefaults.standard.removeObject(forKey: SettingsKey.lastSync)
    }

    /// Test hook for screenshots.
    func load(sample text: String, period: Period) {
        if let result = try? ExpenseParser.parse(text: text) {
            apply(result)
            self.period = period
            lastSync = Date()
            sourceNote = "Sample data"
            status = .ok("Synced \(result.expenses.count) entries")
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
