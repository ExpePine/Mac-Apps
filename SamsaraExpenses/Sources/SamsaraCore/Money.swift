import Foundation

public enum Money {
    private static let whole: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_IN")   // lakh grouping: ₹1,23,456
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let exact: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    /// "₹12,345" (rounded).
    public static func format(_ value: Double) -> String {
        "₹" + (whole.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded())))
    }

    /// "₹59" / "₹20.5" — keeps paise for single items.
    public static func exactFormat(_ value: Double) -> String {
        "₹" + (exact.string(from: NSNumber(value: value)) ?? String(value))
    }

    /// "₹1.2L", "₹45.3K", "₹980" — for chart axes.
    public static func compact(_ value: Double) -> String {
        let v = abs(value)
        let sign = value < 0 ? "-" : ""
        if v >= 100_000 { return sign + "₹" + trim(v / 100_000) + "L" }
        if v >= 1_000 { return sign + "₹" + trim(v / 1_000) + "K" }
        return sign + "₹" + String(Int(v.rounded()))
    }

    private static func trim(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}
