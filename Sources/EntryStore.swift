import Foundation

/// Persists entries as JSON in ~/Library/Application Support/ActivityLogger
/// (inside the app's sandbox container), with voice notes in an Audio folder.
@MainActor
final class EntryStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []

    let directory: URL
    let audioDirectory: URL
    let fileURL: URL

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("ActivityLogger", isDirectory: true)
        audioDirectory = directory.appendingPathComponent("Audio", isDirectory: true)
        fileURL = directory.appendingPathComponent("entries.json")
        try? fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var list = try decoder.decode([Entry].self, from: data)
            for i in list.indices where list[i].transcriptPending {
                list[i].transcriptPending = false   // app quit mid-transcription
            }
            entries = list.sorted { $0.periodEnd > $1.periodEnd }
        } catch {
            // Never overwrite a file we couldn't read — keep a backup.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = directory.appendingPathComponent("entries-unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ActivityLogger: failed to save entries: \(error)")
        }
    }

    // MARK: - CRUD

    func add(_ entry: Entry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { $0.periodEnd > $1.periodEnd }
        save()
    }

    func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        save()
    }

    func delete(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let url = audioURL(for: entries[i]) { try? FileManager.default.removeItem(at: url) }
        entries.remove(at: i)
        save()
    }

    func audioURL(fileName: String) -> URL {
        audioDirectory.appendingPathComponent(fileName)
    }

    func audioURL(for entry: Entry) -> URL? {
        guard let name = entry.audioFileName else { return nil }
        let url = audioURL(fileName: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Speech to text (after the fact)

    func transcribeInBackground(_ id: UUID, localeID: String) {
        guard let entry = entries.first(where: { $0.id == id }),
              let url = audioURL(for: entry) else { return }
        update(id) { $0.transcriptPending = true }
        Task {
            let transcriber = Transcriber()
            let text = try? await transcriber.transcribe(url: url, localeID: localeID)
            self.update(id) {
                $0.transcriptPending = false
                if let text, !text.isEmpty { $0.transcript = text }
            }
        }
    }

    // MARK: - Stats & export

    var loggedTodayCount: Int {
        entries.filter {
            Calendar.current.isDateInToday($0.periodEnd) && $0.status != .missed && $0.status != .skipped
        }.count
    }

    func csvString() -> String {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

        var lines = ["date,start,end,status,text,transcript,audio_file"]
        for e in entries.sorted(by: { $0.periodStart < $1.periodStart }) {
            lines.append([
                day.string(from: e.periodStart),
                time.string(from: e.periodStart),
                time.string(from: e.periodEnd),
                e.status.rawValue,
                esc(e.text),
                esc(e.transcript ?? ""),
                e.audioFileName ?? "",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
