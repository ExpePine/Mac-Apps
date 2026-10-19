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
