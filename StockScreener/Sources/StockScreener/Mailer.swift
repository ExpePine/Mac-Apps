import Foundation
import Security

// MARK: - Keychain (SMTP password)

enum Keychain {
    static let smtpPassword = "smtpPassword"
    private static let service = "com.rajmishra.stockscreener"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = baseQuery(account)
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Email via SMTP (uses macOS's built-in /usr/bin/curl, same approach as Activity Logger)

enum Mailer {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Sends using the saved email settings and Keychain password.
    static func send(_ settings: EmailSettings, overrideRecipients: String = "",
                     subject: String, body: String, html: String? = nil) async throws {
        let password = Keychain.get(Keychain.smtpPassword)
        guard !settings.username.isEmpty, !password.isEmpty else {
            throw Failure(message: "Email isn't set up yet. Open Alerts & Email and add your Gmail address and App Password.")
        }
        var list = recipients(from: overrideRecipients)
        if list.isEmpty { list = recipients(from: settings.recipients) }
        if list.isEmpty { list = [settings.username] }
        try await send(host: settings.host, port: settings.port, username: settings.username,
                       password: password, to: list, subject: subject, body: body, html: html)
    }

    static func recipients(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
    }

    static func send(host: String, port: Int, username: String, password: String,
                     to recipients: [String], subject: String, body: String, html: String? = nil) async throws {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        // base64 keeps every line under SMTP's 998-character limit.
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString(options: [.lineLength76Characters,
                                                       .endLineWithCarriageReturn, .endLineWithLineFeed])
        }
        // RFC 2047 so subjects with ₹ or emoji survive.
        let encodedSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="

        var headers = [
            "From: Stock Screener <\(username)>",
            "To: \(recipients.joined(separator: ", "))",
            "Subject: \(encodedSubject)",
            "Date: \(dateFormatter.string(from: Date()))",
            "MIME-Version: 1.0",
        ]
        let content: String
        if let html {
            let boundary = "SS-\(UUID().uuidString)"
            headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            content = [
                "--\(boundary)",
                "Content-Type: text/plain; charset=UTF-8",
                "Content-Transfer-Encoding: base64",
                "",
                b64(body),
                "--\(boundary)",
                "Content-Type: text/html; charset=UTF-8",
                "Content-Transfer-Encoding: base64",
                "",
                b64(html),
                "--\(boundary)--",
            ].joined(separator: "\r\n")
        } else {
            headers.append("Content-Type: text/plain; charset=UTF-8")
            headers.append("Content-Transfer-Encoding: base64")
            content = b64(body)
        }
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + content + "\r\n"

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-\(UUID().uuidString).eml")
        try Data(message.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // 465 = implicit TLS (smtps://); 587/25 = STARTTLS (smtp:// + --ssl-reqd)
        let scheme = port == 465 ? "smtps" : "smtp"
        var args = ["--silent", "--show-error", "--ssl-reqd", "--max-time", "60",
                    "--url", "\(scheme)://\(host):\(port)",
                    "--mail-from", username]
        for r in recipients { args += ["--mail-rcpt", r] }
        args += ["--upload-file", file.path, "-K", "-"]   // credentials via stdin, not the process list

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let config = "user = \"\(esc(username)):\(esc(password))\"\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        let stdin = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(config.utf8))
                try? stdin.fileHandleForWriting.close()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(message: err.isEmpty ? "curl exited with code \(status)"
                                               : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - "Does D_month / D_day say today?"

enum DayMatcher {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Reads a month cell: 10, "10", "Oct", "October", or a full date.
    private static func month(from raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = NumberParser.parse(s), n == n.rounded(), (1...12).contains(Int(n)) { return Int(n) }
        let lower = s.lowercased()
        let f = DateFormatter(); f.locale = posix
        for (i, name) in f.monthSymbols.enumerated() where lower.count >= 3 && name.lowercased().hasPrefix(String(lower.prefix(3))) {
            return i + 1
        }
        if let d = DateParser.parse(s) { return Calendar.current.component(.month, from: d) }
        return nil
    }

    private enum DayValue { case dayOfMonth(Int), weekday(Int) }

    /// Reads a day cell: 17, "17", "Sat", "Saturday", or a full date.
    private static func day(from raw: String) -> DayValue? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = NumberParser.parse(s), n == n.rounded(), (1...31).contains(Int(n)) { return .dayOfMonth(Int(n)) }
        let lower = s.lowercased()
        let f = DateFormatter(); f.locale = posix
        for (i, name) in f.weekdaySymbols.enumerated() where lower.count >= 3 && name.lowercased().hasPrefix(String(lower.prefix(3))) {
            return .weekday(i + 1)   // Calendar weekday: 1 = Sunday
        }
        if let d = DateParser.parse(s) { return .dayOfMonth(Calendar.current.component(.day, from: d)) }
        return nil
    }

    /// true = the row says today, false = it says another day, nil = couldn't read it.
    static func matchesToday(monthCell: String, dayCell: String, today: Date = Date()) -> Bool? {
        let cal = Calendar.current
        let m = month(from: monthCell)
        let d = day(from: dayCell)
        if m == nil && d == nil { return nil }
        if let m, m != cal.component(.month, from: today) { return false }
        switch d {
        case .dayOfMonth(let n)?: if n != cal.component(.day, from: today) { return false }
        case .weekday(let w)?:    if w != cal.component(.weekday, from: today) { return false }
        case nil: break
        }
        return true
    }

    /// Human-readable form of what a row says, e.g. "Oct / 16".
    static func describe(monthCell: String, dayCell: String) -> String {
        [monthCell, dayCell].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " / ")
    }
}
