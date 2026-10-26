import Foundation

/// Job lists kept in Google Sheets (shared "anyone with the link can view"), read as CSV from your Mac.
/// Each entry is one tab: a sheet name ("Sheet3") or a tab id (gid from the tab's URL).
struct SheetSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var label = ""
    var spreadsheetID = ""
    var tab = ""                     // tab name, or a numeric gid
    var enabled = true

    var sourceKey: String { "gsheet-" + (label.isEmpty ? tab : label).lowercased().replacingOccurrences(of: " ", with: "-") }

    var csvURL: URL? {
        let t = tab.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t.allSatisfy(\.isNumber) {
            return URL(string: "https://docs.google.com/spreadsheets/d/\(spreadsheetID)/export?format=csv&gid=\(t)")
        }
        let name = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
        return URL(string: "https://docs.google.com/spreadsheets/d/\(spreadsheetID)/gviz/tq?tqx=out:csv&sheet=\(name)")
    }

    /// Accepts a full Google Sheets link (…/d/<id>/edit?gid=123) and fills id + tab.
    static func from(link: String, label: String, tabName: String = "") -> SheetSource? {
        guard let r = link.range(of: #"/spreadsheets/d/([A-Za-z0-9_-]+)"#, options: .regularExpression) else { return nil }
        let id = link[r].replacingOccurrences(of: "/spreadsheets/d/", with: "")
        var s = SheetSource()
        s.spreadsheetID = id
        s.label = label
        if !tabName.isEmpty {
            s.tab = tabName
        } else if let g = link.range(of: #"gid=(\d+)"#, options: .regularExpression) {
            s.tab = String(link[g].dropFirst(4))
        }
        return s
    }
}

enum SheetSettings {
    static let defaultSpreadsheet = "https://docs.google.com/spreadsheets/d/1NYqFa7KEyHCLivd86RJNT9cZN0SIZeARgEH6BgW25yk/edit?gid=1568716950"

    static var sources: [SheetSource] {
        get {
            if let d = UserDefaults.standard.data(forKey: "sheetSources"),
               let list = try? JSONDecoder().decode([SheetSource].self, from: d) { return list }
            return [SheetSource.from(link: defaultSpreadsheet, label: "Sheet 3", tabName: "Sheet3"),
                    SheetSource.from(link: defaultSpreadsheet, label: "Sheet 4", tabName: "Sheet4")].compactMap { $0 }
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: "sheetSources") }
        }
    }
}

/// Works out which column is which, from header names when present, otherwise from the data itself
/// (the column of links, the column of dates, the longest text = description, the short text before it = title…).
enum SheetMapper {
    struct Columns {
        var title: Int?, company: Int?, description: Int?, link: Int?, location: Int?, category: Int?, date: Int?, experience: Int?, about: Int?
    }

    static func columns(_ rows: [[String]]) -> (Columns, Bool) {
        guard let first = rows.first else { return (Columns(), false) }
        let h = first.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func find(_ names: [String]) -> Int? { h.firstIndex { cell in names.contains { cell == $0 || cell.hasPrefix($0) } } }
        var c = Columns()
        c.title = find(["title", "designation", "role", "job title", "position name"])
        c.company = find(["company", "employer", "organisation", "organization"])
        c.description = find(["jd", "description", "job description", "details"])
        c.link = find(["link", "url", "apply", "job link"])
        c.location = find(["location", "city", "loc"])
        c.category = find(["category", "pos", "function", "type"])
        c.date = find(["date", "posted", "created"])
        c.experience = find(["experience", "exp"])
        c.about = find(["about"])
        if c.title != nil && (c.description != nil || c.link != nil) { return (c, true) }
        return (infer(rows), false)
    }

    private static func infer(_ rows: [[String]]) -> Columns {
        let sample = Array(rows.prefix(60))
        let width = sample.map(\.count).max() ?? 0
        func col(_ i: Int) -> [String] { sample.map { i < $0.count ? $0[i].trimmingCharacters(in: .whitespacesAndNewlines) : "" }.filter { !$0.isEmpty } }
        func ratio(_ i: Int, _ test: (String) -> Bool) -> Double {
            let v = col(i); return v.isEmpty ? 0 : Double(v.filter(test).count) / Double(v.count)
        }
        func avgLen(_ i: Int) -> Double { let v = col(i); return v.isEmpty ? 0 : Double(v.map(\.count).reduce(0, +)) / Double(v.count) }
        let isURL: (String) -> Bool = { $0.hasPrefix("http") }
        let isDate: (String) -> Bool = { $0.range(of: #"^\d{1,4}[/\-.]\d{1,2}[/\-.]\d{1,4}"#, options: .regularExpression) != nil }
        let isNum: (String) -> Bool = { Int($0) != nil }
        var c = Columns()
        let idx = Array(0..<width)
        c.link = idx.max { ratio($0, isURL) < ratio($1, isURL) }.flatMap { ratio($0, isURL) > 0.5 ? $0 : nil }
        c.date = idx.max { ratio($0, isDate) < ratio($1, isDate) }.flatMap { ratio($0, isDate) > 0.5 ? $0 : nil }
        let textCols = idx.filter { $0 != c.link && $0 != c.date && ratio($0, isNum) < 0.8 }
        c.description = textCols.max { avgLen($0) < avgLen($1) }
        let short = textCols.filter { $0 != c.description && avgLen($0) < 90 }
        // Title = the first short text column (usually just before the description).
        c.title = short.first
        let rest = short.filter { $0 != c.title }
        // Category values look like "product-manager"; locations are plain words.
        let looksLikeSlug: (String) -> Bool = { v in v.contains("-") && !v.contains(" ") }
        c.category = rest.first { i in ratio(i, looksLikeSlug) > 0.5 }
        c.location = rest.first { $0 != c.category }
        return c
    }

    static func feedJobs(_ rows: [[String]], source: SheetSource) -> [FeedJob] {
        let (c, hasHeader) = columns(rows)
        guard let t = c.title else { return [] }
        func cell(_ r: [String], _ i: Int?) -> String {
            guard let i, i < r.count else { return "" }
            return r[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rows.dropFirst(hasHeader ? 1 : 0).compactMap { r in
            let title = cell(r, t)
            guard !title.isEmpty, title.count < 160 else { return nil }
            let link = cell(r, c.link)
            let company = cell(r, c.company)
            guard var f = FeedJob(json: ["id": NaukriSheet.id(link, company, title), "title": title]) else { return nil }
            f.source = source.sourceKey
            let host = URL(string: link)?.host?.lowercased() ?? ""
            f.publisher = host.contains("wellfound") ? "Wellfound" : host.contains("naukri") ? "Naukri"
                : host.contains("linkedin") ? "LinkedIn" : (source.label.isEmpty ? "Sheet" : source.label)
            f.company = company
            f.url = link
            f.location = cell(r, c.location).capitalized
            f.experience = cell(r, c.experience)
            f.description = [cell(r, c.description), cell(r, c.about)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            f.snippet = f.description.count < 400
            f.posted = cell(r, c.date)
            f.firstSeen = ISO8601DateFormatter().string(from: Date())
            let cat = cell(r, c.category).replacingOccurrences(of: "-", with: " ")
            f.category = cat.isEmpty ? nil : cat.capitalized
            return f
        }
    }
}

extension AppStore {
    /// Reads every enabled Google Sheet tab and merges its jobs into the Job Feed (at most every 2 hours unless asked).
    func refreshGoogleSheets(manual: Bool = false) async {
        if !manual, let last = sheetsLast, Date().timeIntervalSince(last) < 2 * 3600 { return }
        var notes: [String] = []
        for src in SheetSettings.sources where src.enabled {
            guard let url = src.csvURL else { continue }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 60
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (d, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let text = String(decoding: d, as: UTF8.self)
                guard code == 200, !text.lowercased().contains("<html") else {
                    notes.append("\(src.label): couldn't read (HTTP \(code)) — is the sheet shared as \"anyone with the link\", and is the tab name right?")
                    continue
                }
                let jobs = SheetMapper.feedJobs(StoryImport.parseCSV(text), source: src)
                var seen = Set<String>()
                let unique = jobs.filter { seen.insert($0.id).inserted }
                let added = mergeFeed(unique, owns: { $0.source == src.sourceKey })
                notes.append("\(src.label): \(unique.count) jobs\(added > 0 ? ", \(added) new" : "")")
            } catch {
                notes.append("\(src.label): \(error.localizedDescription)")
            }
        }
        sheetsLast = Date()
        sheetsStatus = notes.isEmpty ? nil : notes.joined(separator: " · ")
        scheduleFeedMatching()
    }
}
