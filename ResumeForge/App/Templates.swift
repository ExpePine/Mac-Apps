import AppKit
import Foundation

/// A resume design. "Classic" reproduces the original reference layout; others are read from
/// screenshots you drop in (an AI with image support describes the design, the app renders it).
struct TemplateSpec: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "Classic"
    var builtIn = false

    // Type
    var font = "serif"               // serif | sans
    var fontName = ""                // optional exact font, used if installed
    var baseSize: Double = 10.5
    var lineSpacing: Double = 1

    // Header
    var nameSize: Double = 20
    var nameAlign = "center"         // center | left | right
    var nameCaps = true
    var nameColor = "#000000"
    var contactSize: Double = 12
    var headerBand = false           // name/contact on a coloured band across the top
    var headerBandColor = "#1F3A5F"

    // Section headings
    var headingSize: Double = 12.5
    var headingCaps = true
    var headingColor = "#000000"
    var headingStyle = "rule"        // rule (line under) | none | band (filled bar) | bar (accent bar on the left)
    var accentColor = "#000000"

    // Body
    var bullet = "●"
    var companyCaps = true
    var datesAlign = "right"         // right | inline
    var margin: Double = 46

    // Layout
    var layout = "single"            // single | sidebar
    var sidebarSide = "left"
    var sidebarWidth: Double = 0.32
    var sidebarBackground = "#F2F2F2"
    var sidebarSections: [String] = ["education", "additional"]
    var sectionOrder: [String] = ["summary", "experience", "achievements", "education", "additional"]
    var sectionTitles: [String: String] = [:]

    var notes = ""                   // what the AI saw but the app can't reproduce (photos, icons…)
    var thumbnail: Data?             // the screenshot, downsized

    static let classicID = UUID(uuidString: "00000000-0000-0000-0000-00000000C1A5")!

    static let classic: TemplateSpec = {
        var t = TemplateSpec()
        t.id = classicID
        t.name = "Classic (reference)"
        t.builtIn = true
        return t
    }()

    static let defaultTitles = ["summary": "Summary", "experience": "Work Experience", "achievements": "Key Achievements",
                                "education": "Education", "additional": "Additional Details"]

    func title(for section: String) -> String {
        let t = sectionTitles[section] ?? ""
        return t.isEmpty ? (Self.defaultTitles[section] ?? section.capitalized) : t
    }
}

extension TemplateSpec {
    /// Reads the AI's description of a screenshot. Unknown or missing values keep the Classic defaults.
    init(json d: [String: Any], name: String) {
        self.init()
        self.name = name
        func s(_ k: String) -> String { J.str(d, k) }
        func num(_ k: String, _ range: ClosedRange<Double>) -> Double? {
            guard let v = Double(s(k)) else { return nil }
            return min(max(v, range.lowerBound), range.upperBound)
        }
        func oneOf(_ k: String, _ allowed: [String]) -> String? {
            let v = s(k).lowercased()
            return allowed.contains(v) ? v : nil
        }
        func color(_ k: String) -> String? {
            let v = s(k)
            return v.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil ? v.uppercased() : nil
        }
        func flag(_ k: String) -> Bool? {
            guard d[k] != nil else { return nil }
            return J.bool(d, k)
        }

        font = oneOf("font", ["serif", "sans"]) ?? font
        fontName = s("fontName")
        baseSize = num("baseSize", 8.5...12.5) ?? baseSize
        nameSize = num("nameSize", 14...34) ?? nameSize
        nameAlign = oneOf("nameAlign", ["center", "left", "right"]) ?? nameAlign
        nameCaps = flag("nameCaps") ?? nameCaps
        nameColor = color("nameColor") ?? nameColor
        contactSize = num("contactSize", 8...13) ?? contactSize
        headerBand = flag("headerBand") ?? headerBand
        headerBandColor = color("headerBandColor") ?? headerBandColor
        headingSize = num("headingSize", 9...18) ?? headingSize
        headingCaps = flag("headingCaps") ?? headingCaps
        headingColor = color("headingColor") ?? headingColor
        headingStyle = oneOf("headingStyle", ["rule", "none", "band", "bar"]) ?? headingStyle
        accentColor = color("accentColor") ?? accentColor
        let b = s("bullet")
        if ["●", "•", "–", "-", "▪", "■", "›", "»", "◦", "○", "✓"].contains(b) { bullet = b == "-" ? "–" : b }
        companyCaps = flag("companyCaps") ?? companyCaps
        datesAlign = oneOf("datesAlign", ["right", "inline"]) ?? datesAlign
        margin = num("margin", 24...72) ?? margin
        layout = oneOf("layout", ["single", "sidebar"]) ?? layout
        sidebarSide = oneOf("sidebarSide", ["left", "right"]) ?? sidebarSide
        sidebarWidth = num("sidebarWidth", 0.22...0.42) ?? sidebarWidth
        sidebarBackground = color("sidebarBackground") ?? sidebarBackground
        let known = ["summary", "experience", "achievements", "education", "additional"]
        let side = J.strings(d, "sidebarSections").map { $0.lowercased() }.filter { known.contains($0) }
        if !side.isEmpty { sidebarSections = side }
        var order = J.strings(d, "sectionOrder").map { $0.lowercased() }.filter { known.contains($0) }
        for k in known where !order.contains(k) { order.append(k) }
        sectionOrder = order
        if let titles = d["sectionTitles"] as? [String: Any] {
            for (k, v) in titles where known.contains(k.lowercased()) {
                if let v = v as? String, !v.isEmpty { sectionTitles[k.lowercased()] = v }
            }
        }
        notes = s("notes")
    }
}

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if h.count != 6 { h = "000000" }
        let v = UInt32(h, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension Prompts {
    static func readTemplate() -> String {
        """
        TASK: The image is a screenshot of a resume/CV design the candidate wants to copy. Describe its DESIGN (not its text) \
        as settings for a resume renderer. Estimate sizes in points for an A4 page (body text is usually 9.5–11).

        Return:
        {"name": "2–4 word name for this style",
         "font": "serif|sans", "fontName": "closest common font name e.g. Garamond, Georgia, Helvetica Neue, Calibri, Lato",
         "baseSize": 10.5, "nameSize": 22, "nameAlign": "center|left|right", "nameCaps": true, "nameColor": "#RRGGBB",
         "contactSize": 10.5, "headerBand": false, "headerBandColor": "#RRGGBB",
         "headingSize": 12, "headingCaps": true, "headingColor": "#RRGGBB",
         "headingStyle": "rule|none|band|bar", "accentColor": "#RRGGBB",
         "bullet": "●|•|–|▪|›|✓", "companyCaps": true, "datesAlign": "right|inline", "margin": 46,
         "layout": "single|sidebar", "sidebarSide": "left|right", "sidebarWidth": 0.3, "sidebarBackground": "#RRGGBB",
         "sidebarSections": ["education", "additional"],
         "sectionOrder": ["summary", "experience", "achievements", "education", "additional"],
         "sectionTitles": {"summary": "the heading text used, e.g. PROFILE", "experience": "...", "achievements": "...", "education": "...", "additional": "..."},
         "notes": "anything the renderer can't reproduce (photo, icons, charts, timelines), in one sentence"}

        RULES:
        - headingStyle: "rule" = line under/over the heading, "band" = heading on a filled colour bar, "bar" = short accent bar beside it, "none" = plain.
        - layout "sidebar" only when there's a clearly separate side column; list which sections live in it.
        - Map the design's sections to: summary (profile/objective/about), experience, achievements (key achievements/highlights/projects), education, additional (skills/languages/certifications/interests).
        - Colours as 6-digit hex. Use black/dark grey when the design is monochrome.
        """
    }
}

extension AppStore {
    var allTemplates: [TemplateSpec] { [TemplateSpec.classic] + (data.templates ?? []) }

    func template(for doc: ResumeDoc) -> TemplateSpec {
        if let id = doc.templateID, let t = allTemplates.first(where: { $0.id == id }) { return t }
        let d = UserDefaults.standard.string(forKey: "defaultTemplate") ?? ""
        return allTemplates.first { $0.id.uuidString == d } ?? .classic
    }

    /// Screenshot → template, via a provider that can read images.
    func addTemplate(from imageData: Data, name suggested: String) async throws -> TemplateSpec {
        guard let img = AIClient.preparedImage(imageData) else {
            throw GroqError(message: "Couldn't read that image. Use a PNG or JPEG screenshot.")
        }
        let o = try await ask(output: 1500, temperature: 0.1, images: [img]) { _ in Prompts.readTemplate() }
        let n = J.str(o, "name")
        var t = TemplateSpec(json: o, name: suggested.isEmpty ? (n.isEmpty ? "My template" : n) : suggested)
        t.thumbnail = AIClient.preparedImage(imageData, maxSide: 700)
        var list = data.templates ?? []
        list.append(t)
        data.templates = list
        return t
    }
}
