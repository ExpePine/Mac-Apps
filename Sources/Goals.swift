import Foundation

struct Goal: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var text: String
    var done = false
}

/// Daily goals keyed "yyyy-MM-dd", monthly goals keyed "yyyy-MM". Stored in goals.json.
@MainActor
final class GoalsStore: ObservableObject {
    @Published private(set) var daily: [String: [Goal]] = [:]
    @Published private(set) var monthly: [String: [Goal]] = [:]

    private let fileURL: URL

    private struct FileFormat: Codable {
        var daily: [String: [Goal]]
        var monthly: [String: [Goal]]
    }

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("goals.json")
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(FileFormat.self, from: data) {
            daily = file.daily
            monthly = file.monthly
        }
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    static func monthKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: d)
    }

    // Raw lists (may include blank rows while editing)
    func today() -> [Goal] { daily[Self.dayKey(Date())] ?? [] }
    func thisMonth() -> [Goal] { monthly[Self.monthKey(Date())] ?? [] }

    // Non-blank goals, for AI prompts and summaries
    func goals(on day: Date) -> [Goal] {
        (daily[Self.dayKey(day)] ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    func monthGoals(for day: Date) -> [Goal] {
        (monthly[Self.monthKey(day)] ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    var activeToday: [Goal] { goals(on: Date()) }
    var activeMonth: [Goal] { monthGoals(for: Date()) }

    func setToday(_ goals: [Goal]) {
        daily[Self.dayKey(Date())] = goals
        save()
    }

    func setMonth(_ goals: [Goal]) {
        monthly[Self.monthKey(Date())] = goals
        save()
    }

    func toggleToday(_ id: UUID) {
        var list = today()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].done.toggle()
        setToday(list)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(FileFormat(daily: daily, monthly: monthly)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
