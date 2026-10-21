import AppKit
import Foundation
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case feed = "Job Feed"
    case jobs = "Jobs"
    case stories = "Stories"
    case interview = "Interview"
    case master = "Master Resume"
    case templates = "Templates"
    case profile = "Profile"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .feed: return "antenna.radiowaves.left.and.right"
        case .jobs: return "briefcase"
        case .stories: return "book"
        case .interview: return "bubble.left.and.bubble.right"
        case .master: return "doc.richtext"
        case .templates: return "paintbrush"
        case .profile: return "person.crop.circle"
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var data = AppData() { didSet { scheduleSave() } }
    @Published var section: SidebarSection? = .jobs
    @Published var selectedJobID: UUID?
    @Published var selectedStoryID: UUID?
    @Published var busy: String?
    @Published var errorMessage: String?

    // Background processing of new jobs (see AutoPipeline.swift)
    @Published var autoQueue: [UUID] = []
    @Published var autoPaused: String?
    @Published var autoStatus: String?
    var autoWorker: Task<Void, Never>?

    // Job feed from the GitHub collector (see Feed.swift)
    @Published var feedStatus: String?
    @Published var feedError: String?
    @Published var feedErrors: [String] = []
    @Published var feedLastRefresh: Date?
    @Published var feedMatchQueue: [String] = []
    var feedWorker: Task<Void, Never>?
    var feedTimer: Timer?

    private var saveTask: Task<Void, Never>?
    private var midnightTimer: Timer?
    private var waitObserver: NSObjectProtocol?
    private var isLoading = true

    var allowPlaceholdersDefault: Bool { UserDefaults.standard.bool(forKey: "allowPlaceholders") }

    init() {
        Self.registerAutoDefaults()
        FeedSettings.register()
        load()
        isLoading = false
        DispatchQueue.main.async { self.resumePendingAuto() }
        DispatchQueue.main.async { self.startFeedTimer() }
        DispatchQueue.main.async { self.updateDockBadge() }
        // Refresh the Dock count after midnight.
        midnightTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDockBadge() }
        }        // Show "waiting for Groq's per-minute limit" in the status pill.
        waitObserver = NotificationCenter.default.addObserver(forName: GroqClient.waitingNotification, object: nil, queue: .main) { [weak self] n in
            let msg = n.userInfo?["message"] as? String ?? "Waiting for the AI provider…"
            Task { @MainActor in
                guard let self else { return }
                if self.busy != nil { self.busy = msg } else { self.autoStatus = msg }
            }
        }
    }

    // MARK: Persistence

    static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResumeForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ResumeForge.json")
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: Self.storeURL) else { return }
        do {
            data = try dec.decode(AppData.self, from: d)
        } catch {
            // Keep a copy of the unreadable file instead of overwriting it.
            let backup = Self.storeURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: Self.storeURL, to: backup)
            errorMessage = "Couldn't read saved data (a backup was kept at \(backup.lastPathComponent)): \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(data).write(to: Self.storeURL, options: .atomic)
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Jobs handed over by the Safari extension (resumeforge://import?job=…)

    func handleOpenURL(_ url: URL) {
        guard let c = SharedConfig.decodeImportURL(url) else {
            errorMessage = "Couldn't read the job sent from Safari. Try 'Copy as JSON' in the extension and Jobs → Add job manually."
            return
        }
        ingest(c)
    }

    /// Adds a captured job. Duplicates (same page, or same title + company) are ignored.
    /// The app is NOT brought to the front, so you can keep browsing in Safari.
    func ingest(_ c: CapturedJob) {
        let newKeys = Set(Self.jobKeys(url: c.url, title: c.title, company: c.company))
        if !newKeys.isEmpty, data.jobs.contains(where: { !newKeys.isDisjoint(with: Self.jobKeys(url: $0.url, title: $0.title, company: $0.company)) }) {
            return
        }
        var j = JobPosting()
        j.source = c.source; j.url = c.url; j.title = c.title; j.company = c.company
        j.location = c.location; j.experience = c.experience; j.salary = c.salary
        j.skills = c.skills; j.description = c.description; j.rawText = c.rawText
        j.capturedAt = Date()
        data.jobs.insert(j, at: 0)
        if !NSApp.isActive || selectedJobID == nil {
            section = .jobs
            selectedJobID = j.id
        }
        updateDockBadge()
        let id = j.id
        if autoProcessEnabled {
            enqueueAuto(id)
        } else if !Keychain.load().isEmpty {
            run("Cleaning up job description…") { try await self.parseJob(id) }
        }
    }

    var jobsCapturedToday: Int {
        data.jobs.filter { Calendar.current.isDateInToday($0.capturedAt) }.count
    }

    /// Dock icon shows today's count too (matches the Safari toolbar badge).
    func updateDockBadge() {
        let n = jobsCapturedToday
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    // Same rules as background.js: same page (ignoring tracking parameters) or same title + company.
    nonisolated static func jobKeys(url: String, title: String, company: String) -> [String] {
        var keys: [String] = []
        let u = urlKey(url)
        if !u.isEmpty { keys.append("u:" + u) }
        let t = norm(title), c = norm(company)
        if !t.isEmpty && !c.isEmpty { keys.append("t:\(t)|\(c)") }
        return keys
    }

    nonisolated static func urlKey(_ s: String) -> String {
        guard let comps = URLComponents(string: s), let host = comps.host else { return "" }
        let keep: Set<String> = ["job_listing_slug", "jobid", "currentjobid", "jk", "jid"]
        let params = (comps.queryItems ?? []).compactMap { q -> String? in
            let k = q.name.lowercased()
            guard keep.contains(k), let v = q.value, !v.isEmpty else { return nil }
            return "\(k)=\(v)"
        }.sorted()
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return (h + path + (params.isEmpty ? "" : "?" + params.joined(separator: "&"))).lowercased()
    }

    nonisolated static func norm(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Helpers

    func jobIndex(_ id: UUID) -> Int? { data.jobs.firstIndex { $0.id == id } }
    func storyIndex(_ id: UUID) -> Int? { data.stories.firstIndex { $0.id == id } }

    func deleteJob(_ id: UUID) {
        data.jobs.removeAll { $0.id == id }
        if selectedJobID == id { selectedJobID = data.jobs.first?.id }
        updateDockBadge()
    }

    func deleteStory(_ id: UUID) {
        // Clear the selection first so the editor isn't bound to a row that's being removed.
        if selectedStoryID == id { selectedStoryID = nil }
        DispatchQueue.main.async { self.data.stories.removeAll { $0.id == id } }
    }

    @discardableResult
    func newStory(title: String = "", company: String = "") -> UUID {
        var s = Story()
        s.title = title
        s.company = company
        data.stories.insert(s, at: 0)
        selectedStoryID = s.id
        return s.id
    }

    /// Runs async work with a status pill and error alert.
    func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            self.busy = label
            defer { self.busy = nil }
            do { try await work() }
            catch { self.errorMessage = error.localizedDescription }
        }
    }
}
