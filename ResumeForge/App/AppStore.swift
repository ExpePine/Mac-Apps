import AppKit
import Foundation
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case jobs = "Jobs"
    case stories = "Stories"
    case interview = "Interview"
    case master = "Master Resume"
    case profile = "Profile"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .jobs: return "briefcase"
        case .stories: return "book"
        case .interview: return "bubble.left.and.bubble.right"
        case .master: return "doc.richtext"
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

    private var saveTask: Task<Void, Never>?
    private var isLoading = true

    static let defaultModel = "openai/gpt-oss-120b"

    var model: String {
        let m = UserDefaults.standard.string(forKey: "groqModel") ?? ""
        return m.isEmpty ? Self.defaultModel : m
    }
    var allowPlaceholdersDefault: Bool { UserDefaults.standard.bool(forKey: "allowPlaceholders") }
    var client: GroqClient { GroqClient(apiKey: Keychain.load(), model: model) }

    init() {
        load()
        isLoading = false
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

    func ingest(_ c: CapturedJob) {
        let id: UUID
        let key = Self.normalizedURL(c.url)
        if !key.isEmpty, let i = data.jobs.firstIndex(where: { Self.normalizedURL($0.url) == key }) {
            // Same job captured again: refresh the description if the new one is better.
            if c.description.count > data.jobs[i].description.count { data.jobs[i].description = c.description }
            if !c.rawText.isEmpty { data.jobs[i].rawText = c.rawText }
            id = data.jobs[i].id
        } else {
            var j = JobPosting()
            j.source = c.source; j.url = c.url; j.title = c.title; j.company = c.company
            j.location = c.location; j.experience = c.experience; j.salary = c.salary
            j.skills = c.skills; j.description = c.description; j.rawText = c.rawText
            j.capturedAt = c.capturedAt
            data.jobs.insert(j, at: 0)
            id = j.id
        }
        section = .jobs
        selectedJobID = id
        NSApp.activate(ignoringOtherApps: true)
        if !Keychain.load().isEmpty {
            run("Cleaning up job description…") { try await self.parseJob(id) }
        }
    }

    static func normalizedURL(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return s }
        c.query = nil
        c.fragment = nil
        return c.string?.lowercased() ?? s
    }

    // MARK: Helpers

    func jobIndex(_ id: UUID) -> Int? { data.jobs.firstIndex { $0.id == id } }
    func storyIndex(_ id: UUID) -> Int? { data.stories.firstIndex { $0.id == id } }

    func deleteJob(_ id: UUID) {
        data.jobs.removeAll { $0.id == id }
        if selectedJobID == id { selectedJobID = data.jobs.first?.id }
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
