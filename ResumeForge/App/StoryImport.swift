import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Reading story files you already have: Word, PDF, text/Markdown, RTF, HTML, CSV and JSON.
/// Structured files (ResumeForge JSON/Markdown exports, CSV with a text column) import directly.
/// Free text is split into stories by Groq (keeping your wording) or, without a key, by headings.
enum StoryImport {

    static var allowedTypes: [UTType] {
        let list: [UTType?] = [
            .plainText, .text, .utf8PlainText, .rtf, .rtfd, .pdf, .json, .commaSeparatedText, .html,
            UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"),
            UTType(filenameExtension: "docx"), UTType(filenameExtension: "doc"), UTType(filenameExtension: "odt")
        ]
        return list.compactMap { $0 }
    }

    enum Parsed {
        case stories([Story])   // already structured — no AI needed
        case text(String)       // free text to split into stories
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Reading files

    static func read(_ url: URL) throws -> Parsed {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "json":
            let data = try Data(contentsOf: url)
            if let s = storiesFromJSON(data) { return .stories(s) }
            return .text(String(decoding: data, as: UTF8.self))
        case "csv":
            let text = try readString(url)
            if let s = storiesFromCSV(text) { return .stories(s) }
            return .text(text)
        case "pdf":
            guard let doc = PDFDocument(url: url) else {
                throw ImportError(message: "Couldn't open \(url.lastPathComponent) as a PDF.")
            }
            let text = doc.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ImportError(message: "\(url.lastPathComponent) has no selectable text (it may be a scan). Export it as text or Word and try again.")
            }
            return .text(text)
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive":
            return .text(try attributedText(url, ext: ext))
        default:
            let text = try readString(url)
            if let s = storiesFromMarkdownExport(text) { return .stories(s) }
            return .text(text)
        }
    }

    private static func readString(_ url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    private static func attributedText(_ url: URL, ext: String) throws -> String {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch ext {
        case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
        case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
        case "html", "htm": options[.documentType] = NSAttributedString.DocumentType.html
        default: break
        }
        do {
            return try NSAttributedString(url: url, options: options, documentAttributes: nil).string
        } catch {
            throw ImportError(message: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Structured formats

    /// ResumeForge's own export ([Story]), {"stories":[…]}, or any array of story-like objects.
    static func storiesFromJSON(_ data: Data) -> [Story]? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let s = try? dec.decode([Story].self, from: data), !s.isEmpty { return s }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let arr: [[String: Any]]
        if let a = obj as? [[String: Any]] { arr = a }
        else if let d = obj as? [String: Any], let a = d["stories"] as? [[String: Any]] { arr = a }
        else { return nil }
        let stories = arr.map { d -> Story in
            var s = Story(json: d, origin: "file")
            if s.text.isEmpty { s.text = J.str(d, "story").isEmpty ? J.str(d, "description") : J.str(d, "story") }
            return s
        }.filter { !$0.text.isEmpty }
        return stories.isEmpty ? nil : stories
    }

    /// CSV with a header row containing a "text" (or "story"/"description") column.
    /// Optional columns: title, company, role, period, metrics, skills (lists separated by ; or ,).
    static func storiesFromCSV(_ text: String) -> [Story]? {
        let rows = parseCSV(text)
        guard rows.count >= 2 else { return nil }
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let textCol = col(["text", "story", "description", "details"]) else { return nil }
        let titleCol = col(["title", "name", "headline"]), companyCol = col(["company", "employer", "organisation", "organization"])
        let roleCol = col(["role", "title/role", "position", "designation"]), periodCol = col(["period", "dates", "date", "year", "when"])
        let metricsCol = col(["metrics", "results", "numbers"]), skillsCol = col(["skills", "tags"])

        func cell(_ r: [String], _ i: Int?) -> String {
            guard let i, i < r.count else { return "" }
            return r[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func list(_ s: String) -> [String] {
            s.components(separatedBy: CharacterSet(charactersIn: s.contains(";") ? ";" : ","))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let stories = rows.dropFirst().compactMap { r -> Story? in
            let t = cell(r, textCol)
            guard !t.isEmpty else { return nil }
            var s = Story()
            s.text = t
            s.title = cell(r, titleCol)
            s.company = cell(r, companyCol)
            s.role = cell(r, roleCol)
            s.period = cell(r, periodCol)
            s.metrics = list(cell(r, metricsCol))
            s.skills = list(cell(r, skillsCol))
            s.origin = "file"
            if s.title.isEmpty { s.title = String(t.prefix(60)) }
            return s
        }
        return stories.isEmpty ? nil : stories
    }

    /// Minimal RFC 4180 CSV parser (quoted fields, escaped quotes, newlines inside quotes).
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field); field = ""
                    if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        row.append(field)
        if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        return rows
    }

    // MARK: Markdown (ResumeForge export format, round-trips without AI)

    /// Recognises the layout written by `markdownExport`: "## Title" then optional
    /// "Company: … | Role: … | Period: …", "Metrics: …", "Skills: …" lines, then the story text.
    static func storiesFromMarkdownExport(_ text: String) -> [Story]? {
        guard text.contains("\n## ") || text.hasPrefix("## "),
              text.range(of: "Company:") != nil else { return nil }
        let s = splitByHeadings(text)
        return s.isEmpty ? nil : s
    }

    static func markdownExport(_ stories: [Story]) -> String {
        var out = "# My stories\n\n"
        for s in stories {
            out += "## \(s.title.isEmpty ? "Untitled story" : s.title)\n"
            out += "Company: \(s.company) | Role: \(s.role) | Period: \(s.period)\n"
            if !s.metrics.isEmpty { out += "Metrics: \(s.metrics.joined(separator: "; "))\n" }
            if !s.skills.isEmpty { out += "Skills: \(s.skills.joined(separator: ", "))\n" }
            out += "\n\(s.text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        return out
    }

    // MARK: Splitting free text without AI

    /// One story per heading ("# …", "Story 3:", "1." on its own short line, "---" separators).
    /// Falls back to blocks separated by 2+ blank lines, then to a single story.
    static func splitByHeadings(_ text: String) -> [Story] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func isHeading(_ l: String) -> String? {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let h = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return h.isEmpty ? nil : h
            }
            if t.range(of: #"^(story|project|achievement)\s*\d*\s*[:.\-–]"#, options: [.regularExpression, .caseInsensitive]) != nil, t.count < 120 {
                return t
            }
            return nil
        }
        var blocks: [(title: String, lines: [String])] = []
        var current: (title: String, lines: [String])? = nil
        for l in lines {
            if let h = isHeading(l) {
                if let c = current { blocks.append(c) }
                current = (h, [])
            } else if l.trimmingCharacters(in: .whitespaces) == "---" {
                if let c = current { blocks.append(c) }
                current = nil
            } else {
                if current == nil { current = ("", []) }
                current!.lines.append(l)
            }
        }
        if let c = current { blocks.append(c) }

        // No headings at all → split on 2+ blank lines.
        if blocks.count <= 1 {
            let body = text.replacingOccurrences(of: "\r\n", with: "\n")
            let parts = body.components(separatedBy: "\n\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if parts.count > 1 {
                blocks = parts.map { p -> (title: String, lines: [String]) in
                    var ls = p.components(separatedBy: "\n")
                    let first = ls.first ?? ""
                    if first.count < 90, ls.count > 1 { ls.removeFirst(); return (first, ls) }
                    return ("", ls)
                }
            }
        }

        return blocks.compactMap { b -> Story? in
            var s = Story()
            s.origin = "file"
            s.title = String(b.title.trimmingCharacters(in: CharacterSet(charactersIn: " :.-–")).prefix(100))
            var body: [String] = []
            for l in b.lines {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Company:") && t.contains("|") {
                    for part in t.components(separatedBy: "|") {
                        let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        guard kv.count == 2 else { continue }
                        switch kv[0].lowercased() {
                        case "company": s.company = kv[1]
                        case "role": s.role = kv[1]
                        case "period": s.period = kv[1]
                        default: break
                        }
                    }
                } else if t.hasPrefix("Metrics:") {
                    s.metrics = t.dropFirst(8).components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                } else if t.hasPrefix("Skills:") {
                    s.skills = t.dropFirst(7).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                } else {
                    body.append(l)
                }
            }
            s.text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.text.count >= 20 else { return nil }   // skip empty sections / stray headings
            if s.title.isEmpty {
                s.title = String(s.text.split(separator: "\n").first.map(String.init)?.prefix(60) ?? "Imported story")
            }
            return s
        }
    }

    // MARK: Helpers

    /// Splits long text into chunks at paragraph boundaries so each AI call stays a sensible size.
    static func chunks(_ text: String, maxChars: Int = 12_000) -> [String] {
        guard text.count > maxChars else { return [text] }
        var out: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n\n") {
            if current.count + para.count + 2 > maxChars, !current.isEmpty {
                out.append(current)
                current = ""
            }
            if para.count > maxChars {
                var rest = Substring(para)
                while !rest.isEmpty {
                    out.append(String(rest.prefix(maxChars)))
                    rest = rest.dropFirst(maxChars)
                }
            } else {
                current += (current.isEmpty ? "" : "\n\n") + para
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Fingerprint used to spot a story you've already imported.
    static func fingerprint(_ s: Story) -> String {
        String(AppStore.norm(s.text).prefix(240))
    }
}
