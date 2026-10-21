import Foundation

/// Shared between the app and the Safari extension (both targets).
///
/// Hand-off works without an Apple Developer account (no App Groups):
/// the extension encodes the captured job into a `resumeforge://import?job=…` link and opens it;
/// macOS launches/activates ResumeForge.app, which decodes the job.
enum SharedConfig {
    static let urlScheme = "resumeforge"

    /// Keeps the link to a sane size (LaunchServices handles long URLs, but there's no reason to push it).
    static let maxDescription = 20_000
    static let maxRawText = 12_000

    static func importURL(for job: CapturedJob) throws -> URL {
        var j = job
        j.description = String(j.description.prefix(maxDescription))
        j.rawText = String(j.rawText.prefix(maxRawText))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let b64 = try encoder.encode(j).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let url = URL(string: "\(urlScheme)://import?job=\(b64)") else {
            throw NSError(domain: "ResumeForge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't build the hand-off link."])
        }
        return url
    }

    private static func b64url<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeB64url<T: Decodable>(_ s: String, type: T.Type) -> T? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    /// resumeforge://action?d=…  — an action you added on a page (usually a JD).
    static func actionURL(for payload: ActionPayload) throws -> URL {
        var p = payload
        if var j = p.job {
            j.description = String(j.description.prefix(maxDescription))
            j.rawText = String(j.rawText.prefix(maxRawText))
            p.job = j
        }
        p.pageText = String(p.pageText.prefix(maxRawText))
        guard let url = URL(string: "\(urlScheme)://action?d=\(try b64url(p))") else {
            throw NSError(domain: "ResumeForge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't build the hand-off link."])
        }
        return url
    }

    static func decodeActionURL(_ url: URL) -> ActionPayload? {
        guard url.scheme == urlScheme, url.host == "action",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let d = comps.queryItems?.first(where: { $0.name == "d" })?.value else { return nil }
        return decodeB64url(d, type: ActionPayload.self)
    }

    static func decodeImportURL(_ url: URL) -> CapturedJob? {
        guard url.scheme == urlScheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var b64 = comps.queryItems?.first(where: { $0.name == "job" })?.value else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CapturedJob.self, from: data)
    }
}

/// A job captured by the extension.
struct CapturedJob: Codable {
    var id: UUID
    var source: String
    var url: String
    var title: String
    var company: String
    var location: String
    var experience: String
    var salary: String
    var skills: [String]
    var description: String
    var rawText: String
    var capturedAt: Date

    init(dictionary d: [String: Any]) {
        func s(_ k: String) -> String {
            (d[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        id = UUID()
        let src = s("source")
        source = src.isEmpty ? "other" : src
        url = s("url")
        title = s("title")
        company = s("company")
        location = s("location")
        experience = s("experience")
        salary = s("salary")
        skills = (d["skills"] as? [Any])?.compactMap { $0 as? String } ?? []
        description = s("description")
        rawText = s("rawText")
        capturedAt = Date()
    }
}

/// An action added from Safari ("Meet on LinkedIn", "Message on WhatsApp", or your own text).
struct ActionPayload: Codable {
    var kind: String            // linkedin | whatsapp | call | email | apply | custom
    var text: String            // what you wrote, or the preset's wording
    var selection: String       // text you had selected on the page, if any
    var pageURL: String
    var pageTitle: String
    var pageText: String        // visible text (used when the page isn't a JD, e.g. a recruiter's profile)
    var job: CapturedJob?       // the JD on that page, when there is one

    init(dictionary d: [String: Any]) {
        func s(_ k: String) -> String { (d[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        kind = s("kind").isEmpty ? "custom" : s("kind")
        text = s("text")
        selection = s("selection")
        pageURL = s("pageURL")
        pageTitle = s("pageTitle")
        pageText = s("pageText")
        job = (d["job"] as? [String: Any]).map(CapturedJob.init(dictionary:))
    }
}
