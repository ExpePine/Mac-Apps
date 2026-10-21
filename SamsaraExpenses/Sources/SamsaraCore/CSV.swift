import Foundation

/// Minimal RFC 4180 CSV reader/writer: quoted fields, "" escapes,
/// commas and line breaks inside quotes, LF / CRLF / CR line endings, UTF-8 BOM.
public enum CSV {

    public static func parse(_ input: String) -> [[String]] {
        var text = input
        if text.unicodeScalars.first == "\u{FEFF}" {
            text = String(text.unicodeScalars.dropFirst())
        }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r", "\r\n":
                    row.append(field)
                    field = ""
                    rows.append(row)
                    row = []
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // Drop blank lines.
        return rows.filter { r in
            !(r.count == 1 && r[0].trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    public static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    public static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }
}
