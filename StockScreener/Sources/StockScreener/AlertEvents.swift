import Foundation

/// One alert that fired: a rule was met by a stock (and maybe emailed).
struct AlertEvent: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case alert, email }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var ruleID: UUID
    var ruleName: String
    var stock: String
    var dataDay: String          // trading day of the data (yyyy-MM-dd)
    var values: [String]         // "COLUMN: value" for the columns the rule uses
    var conditions: String       // the rule in words
}

/// Alert history, kept as JSON in Application Support (newest first, up to 5,000 events).
enum AlertEventStore {
    static let maxEvents = 50_000          // keep the history: old alerts are tracked (% since the alert)

    private static var fileURL: URL {
        HistoryStore.folder.deletingLastPathComponent().appendingPathComponent("alerts.json")
    }

    static func load() -> [AlertEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([AlertEvent].self, from: data) else { return [] }
        return events
    }

    /// Loads and drops repeats of the same rule + stock + type on the same data day (keeps the earliest).
    static func loadDeduplicated() -> [AlertEvent] {
        let all = load()
        var seen = Set<String>(), out: [AlertEvent] = []
        for e in all.sorted(by: { $0.date < $1.date }) where seen.insert("\(e.ruleName)|\(e.stock)|\(e.kind.rawValue)|\(e.dataDay)").inserted {
            out.append(e)
        }
        out.sort { $0.date > $1.date }
        if out.count != all.count { save(out) }
        return out
    }

    static func save(_ events: [AlertEvent]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(events.prefix(maxEvents))) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
