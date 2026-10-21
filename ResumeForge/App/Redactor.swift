import Foundation

/// Keeps your contact details away from AI providers. The resume header is filled in locally from your Profile,
/// so the AI never needs your phone, email or LinkedIn URL. On by default (Settings ▸ Privacy).
enum Redactor {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "redactContact") as? Bool ?? true }

    private static let emailRE = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    // +91 98xxx xxxxx, 098..., (079) 1234 5678 — runs of 10+ digits with separators
    private static let phoneRE = #"(?<![\w])(?:\+?\d{1,3}[\s\-.]?)?(?:\(?\d{2,5}\)?[\s\-.]?)?\d{3,5}[\s\-.]?\d{4,5}(?![\w])"#
    private static let linkedinRE = #"(?:https?://)?(?:[a-z]{2,3}\.)?linkedin\.com/in/[A-Za-z0-9\-_%]+/?"#

    static func contacts(in text: String) -> (email: String?, phone: String?, linkedin: String?) {
        func first(_ re: String) -> String? {
            guard let r = text.range(of: re, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
        var phone = first(phoneRE)
        if let p = phone, p.filter(\.isNumber).count < 10 { phone = nil }
        return (first(emailRE), phone, first(linkedinRE))
    }

    static func mask(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: emailRE, with: "[email]", options: .regularExpression)
        t = t.replacingOccurrences(of: linkedinRE, with: "[linkedin]", options: [.regularExpression, .caseInsensitive])
        // Only mask digit runs that look like phone numbers (10+ digits), not years or metrics.
        if let re = try? NSRegularExpression(pattern: phoneRE) {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let s = ns.substring(with: m.range)
                if s.filter(\.isNumber).count >= 10 {
                    t = (t as NSString).replacingCharacters(in: m.range, with: "[phone]")
                }
            }
        }
        return t
    }
}
