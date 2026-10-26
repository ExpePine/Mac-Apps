import Foundation

// MARK: - Jobs

struct JobPosting: Codable, Identifiable, Hashable {
    var id = UUID()
    var source = "other"            // naukri | wellfound | linkedin | other | manual
    var url = ""
    var title = ""
    var company = ""
    var location = ""
    var experience = ""
    var salary = ""
    var skills: [String] = []
    var description = ""
    var rawText = ""
    var capturedAt = Date()
    var parsed = false

    var keywords: [String] = []     // ATS keywords pulled out with the benchmark
    var benchmark: ResumeDoc?       // the "best resume" for this JD (ideal candidate)
    var tailored: ResumeDoc?        // YOUR resume for this JD, built from your stories
    var tailoredMissing: [String] = []
    var gaps: [StoryGap] = []       // missing stories vs the benchmark
    var strengths: [String] = []

    // Background processing (optional so older saved data still loads)
    var autoStage: String?
    var autoError: String?
    var match: MatchResult?         // fit score + conflicts against your profile and stories
    var appliedAt: Date?
    var liked: Bool?
    var tags: [String]?
    var feedKey: String?            // set when the job came from the GitHub job feed
}

// MARK: - Stories (your raw material)

struct Story: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = ""
    var company = ""
    var role = ""
    var period = ""
    var text = ""
    var metrics: [String] = []
    var skills: [String] = []
    var origin = "manual"           // manual | interview | import
    var createdAt = Date()
    var updatedAt = Date()
}

// MARK: - Profile (facts that frame the resume)

struct RoleEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var company = ""
    var title = ""
    var location = ""
    var start = ""
    var end = "Present"
}

struct EducationEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var qualification = ""
    var institution = ""
    var location = ""
    var year = ""
}

struct Profile: Codable, Hashable {
    var name = ""
    var headline = ""               // e.g. "Product Development Leader – Embedded & IoT"
    var location = ""
    var phone = ""
    var email = ""
    var linkedin = ""
    var roles: [RoleEntry] = []
    var education: [EducationEntry] = []
    var languages = ""
    var certifications = ""
    var technicalSkills = ""

    var contactLine: String {
        [location, phone.isEmpty ? "" : "P: \(phone)", email, linkedin]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }
}

// MARK: - Resume document (mirrors the reference layout)

struct ResumeBullet: Codable, Identifiable, Hashable {
    var id = UUID()
    var text = ""
    var sources: [String] = []      // story IDs this bullet is based on
}

struct ResumeRole: Codable, Identifiable, Hashable {
    var id = UUID()
    var company = ""
    var location = ""
    var title = ""
    var dates = ""
    var bullets: [ResumeBullet] = []
}

struct ResumeAchievement: Codable, Identifiable, Hashable {
    var id = UUID()
    var label = ""
    var text = ""
    var subItems: [String] = []
    var sources: [String] = []
}

struct ResumeEducation: Codable, Identifiable, Hashable {
    var id = UUID()
    var qualification = ""
    var institution = ""
    var location = ""
    var year = ""
}

struct LabeledLine: Codable, Identifiable, Hashable {
    var id = UUID()
    var label = ""
    var value = ""
}

struct ResumeDoc: Codable, Hashable {
    var name = ""
    var contactLine = ""
    var summary = ""
    var experience: [ResumeRole] = []
    var achievements: [ResumeAchievement] = []
    var education: [ResumeEducation] = []
    var additional: [LabeledLine] = []
    var mode = "strict"             // strict | placeholders | benchmark
    var generatedAt = Date()
    var templateID: UUID?           // nil = default template

    var allTexts: [String] {
        [summary]
        + experience.flatMap { $0.bullets.map(\.text) }
        + achievements.flatMap { [$0.text] + $0.subItems }
    }
    var verifyCount: Int { allTexts.filter { $0.contains("[VERIFY") }.count }
    var unsourcedCount: Int {
        mode == "benchmark" ? 0 : experience.flatMap(\.bullets).filter { $0.sources.isEmpty && !$0.text.contains("[VERIFY") }.count
    }
}

// MARK: - Gaps & interview

enum GapStatus: String, Codable, Hashable { case open, answered, skipped }

struct StoryGap: Codable, Identifiable, Hashable {
    var id = UUID()
    var theme = ""
    var priority = "medium"         // high | medium | low
    var whyItMatters = ""
    var benchmarkExample = ""
    var questions: [String] = []
    var coveredBy: [String] = []    // story IDs that partially cover it
    var status: GapStatus = .open
}

struct ChatTurn: Codable, Identifiable, Hashable {
    var id = UUID()
    var role = "assistant"          // assistant | user
    var text = ""
}

struct InterviewSession: Codable, Hashable {
    var focusJobID: UUID?
    var focusGapID: UUID?
    var turns: [ChatTurn] = []
    var draft: Story?
    var readyToSave = false
}

// MARK: - Everything the app persists

struct AppData: Codable {
    var profile = Profile()
    var jobs: [JobPosting] = []
    var stories: [Story] = []
    var interview = InterviewSession()
    var masterResume: ResumeDoc?
    var masterMissing: [String] = []
    var templates: [TemplateSpec]?  // optional so older saved data still loads
    var feed: [FeedJob]?
    var actions: [ActionItem]?
    var commentary: Commentary?
    var contacts: [Contact]?
    var lines: [LineItem]?
}
