import Foundation
import Security
import UserNotifications

// MARK: - Keychain (SMTP password, Groq API key)

enum Keychain {
    static let smtpPassword = "smtpPassword"
    static let groqAPIKey = "groqAPIKey"
    private static let service = "com.raj.ActivityLogger"

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

// MARK: - Groq (OpenAI-compatible chat completions)

enum Groq {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func complete(apiKey: String, model: String, system: String, user: String) async throws -> String {
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw Failure(message: "Bad Groq URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard status == 200 else {
            let apiMessage = (json?["error"] as? [String: Any])?["message"] as? String
            throw Failure(message: "Groq error \(status): \(apiMessage ?? String(data: data, encoding: .utf8) ?? "unknown")")
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Groq returned an empty summary")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Email via SMTP (uses macOS's built-in /usr/bin/curl)

enum Mailer {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func send(host: String, port: Int, username: String, password: String,
                     to recipients: [String], subject: String, body: String) async throws {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let headers = [
            "From: Activity Logger <\(username)>",
            "To: \(recipients.joined(separator: ", "))",
            "Subject: \(subject)",
            "Date: \(dateFormatter.string(from: Date()))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
        ]
        let normalizedBody = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + normalizedBody + "\r\n"

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
            throw Failure(message: err.isEmpty ? "curl exited with code \(status)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - Daily summary service

@MainActor
final class ReportService: ObservableObject {
    @Published private(set) var isSending = false
    @Published private(set) var lastStatus: String

    private let settings: SettingsStore
    private let store: EntryStore
    private let usage: UsageStore
    private let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?
    private var nextRetry: Date?

    private enum Keys {
        static let lastSentDay = "reportLastSentDay"
        static let lastStatus = "reportLastStatus"
    }

    init(settings: SettingsStore, store: EntryStore, usage: UsageStore) {
        self.settings = settings
        self.store = store
        self.usage = usage
        lastStatus = UserDefaults.standard.string(forKey: Keys.lastStatus) ?? "No summary sent yet."
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                await self.tick()
            }
        }
    }

    /// Sends once per day at/after the chosen time. If the Mac was asleep at
    /// that time, it sends as soon as it wakes. Failures retry every 15 min.
    private func tick() async {
        guard settings.reportEnabled, !isSending else { return }
        let cal = Calendar.current
        let now = Date()
        guard let sendAt = cal.date(bySettingHour: settings.reportHour, minute: settings.reportMinute,
                                    second: 0, of: now),
              now >= sendAt else { return }
        let todayKey = Self.dayKey(now)
        guard defaults.string(forKey: Keys.lastSentDay) != todayKey else { return }
        if let retry = nextRetry, now < retry { return }

        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
        if await send(for: yesterday, isTest: false) {
            defaults.set(todayKey, forKey: Keys.lastSentDay)
            nextRetry = nil
        } else {
            nextRetry = now.addingTimeInterval(15 * 60)
            notifyFailure()
        }
    }

    /// "Send test email now" — yesterday if it has entries, otherwise today so far.
    func sendTest() async {
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) ?? Date()
        let day = store.entries(on: yesterday).isEmpty ? Date() : yesterday
        _ = await send(for: day, isTest: true)
    }

    private func send(for day: Date, isTest: Bool) async -> Bool {
        isSending = true
        defer { isSending = false }

        let recipients = settings.reportRecipient
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map(String.init).filter { $0.contains("@") }
        let password = Keychain.get(Keychain.smtpPassword)
        guard !recipients.isEmpty else { return fail("Add a 'Send to' email address.") }
        guard settings.smtpUsername.contains("@"), !settings.smtpHost.isEmpty, !password.isEmpty else {
            return fail("Fill in the email account (SMTP) username and app password.")
        }

        let dayText = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let entries = store.entries(on: day).sorted { $0.periodStart < $1.periodStart }
        let dayUsage = settings.includeUsageInEmail ? usage.usage(for: day) : nil
        let hasUsage = (dayUsage?.activeSeconds ?? 0) >= 60
        let usageText = hasUsage ? Self.usageText(dayUsage!) : ""

        if entries.isEmpty && !hasUsage && settings.reportSkipEmptyDays && !isTest {
            setStatus("No entries for \(dayText) - nothing to send.")
            return true
        }

        let log = Self.logText(entries)
        var summary: String
        let apiKey = Keychain.get(Keychain.groqAPIKey)
        if entries.isEmpty && !hasUsage {
            summary = "No check-ins or computer activity were logged on this day."
        } else if apiKey.isEmpty {
            summary = "(Add a Groq API key in Daily email settings to get an AI summary.)"
        } else {
            do {
                summary = try await Groq.complete(apiKey: apiKey, model: settings.groqModel,
                                                  system: Self.systemPrompt,
                                                  user: Self.userPrompt(dayText: dayText, entries: entries,
                                                                        log: log, usageText: usageText))
            } catch {
                summary = "(AI summary unavailable: \(error.localizedDescription))"
            }
        }

        var body = """
        Good morning!

        Here's what you did on \(dayText).

        \(summary)

        ------------------------------
        CHECK-IN LOG
        ------------------------------
        \(log.isEmpty ? "(no entries)" : log)
        """
        if hasUsage {
            body += """


            ------------------------------
            WEB & APP TIME (active, idle excluded)
            ------------------------------
            \(usageText)
            """
        }
        body += "\n\n-- Sent by Activity Logger"
        let subject = (isTest ? "[Test] " : "") + "Your activity summary - \(dayText)"

        do {
            try await Mailer.send(host: settings.smtpHost, port: settings.smtpPort,
                                  username: settings.smtpUsername, password: password,
                                  to: recipients, subject: subject, body: body)
            let time = Date().formatted(date: .abbreviated, time: .shortened)
            setStatus("\(isTest ? "Test sent" : "Sent") summary for \(dayText) to \(recipients.joined(separator: ", ")) - \(time)")
            return true
        } catch {
            return fail("Email failed: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private func fail(_ message: String) -> Bool {
        setStatus(message)
        return false
    }

    private func setStatus(_ s: String) {
        lastStatus = s
        defaults.set(s, forKey: Keys.lastStatus)
    }

    private func notifyFailure() {
        let content = UNMutableNotificationContent()
        content.title = "Daily summary email failed"
        content.body = lastStatus
        let request = UNNotificationRequest(identifier: "report-failure", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func logText(_ entries: [Entry]) -> String {
        entries.map { e in
            var line = "\(e.timeRangeText)  [\(e.status.label)]"
            let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { line += "  \(text.replacingOccurrences(of: "\n", with: " / "))" }
            if let t = e.transcript, !t.isEmpty, !text.contains(t) {
                line += "  (voice: \(t.replacingOccurrences(of: "\n", with: " ")))"
            }
            return line
        }.joined(separator: "\n")
    }

    private static let systemPrompt = """
    You summarize a person's self-reported work log for their morning email. \
    Use only what is in the log; never invent tasks, names or numbers. \
    Write plain text only: no markdown, no asterisks, no # headings. Be concise and specific.
    """

    static func usageText(_ u: DayUsage) -> String {
        let timeFmt: (Date?) -> String = { $0?.formatted(date: .omitted, time: .shortened) ?? "-" }
        var lines = ["Active computer time: \(durationText(u.activeSeconds)) (first \(timeFmt(u.firstActive)), last \(timeFmt(u.lastActive)))"]
        let sites = u.top(u.sites, 12).filter { $0.seconds >= 60 }
        if !sites.isEmpty {
            lines.append("")
            lines.append("Top websites:")
            lines += sites.map { "  \(durationText($0.seconds).padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.name)" }
        }
        let apps = u.top(u.apps, 10).filter { $0.seconds >= 60 }
        if !apps.isEmpty {
            lines.append("")
            lines.append("Top apps:")
            lines += apps.map { "  \(durationText($0.seconds).padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.name)" }
        }
        let hours = u.hourly.keys.sorted().filter { (u.hourly[$0] ?? 0) >= 60 }
        if !hours.isEmpty {
            lines.append("")
            lines.append("Active by hour: " + hours.map { "\($0):00 \(durationText(u.hourly[$0] ?? 0))" }.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    private static func userPrompt(dayText: String, entries: [Entry], log: String, usageText: String) -> String {
        let answered = entries.filter { $0.status != .missed && $0.status != .skipped }.count
        let missed = entries.filter { $0.status == .missed }.count
        let skipped = entries.filter { $0.status == .skipped }.count
        return """
        Date: \(dayText)
        Check-ins: \(entries.count) total, \(answered) answered, \(missed) missed, \(skipped) skipped.

        Check-in log (time range, status, what I did):
        \(log.isEmpty ? "(no check-ins)" : log)

        Computer activity measured automatically (active time only):
        \(usageText.isEmpty ? "(not available)" : usageText)

        Write the summary in exactly this structure:

        SUMMARY
        2-3 sentences on the overall day.

        KEY WORK
        - 3 to 7 bullets, grouping related entries; mention approximate time spent where the log supports it.

        TIME BY THEME
        - theme: approximate duration (based on check-in time ranges)

        WEB & APP TIME
        2-3 lines interpreting the measured website/app time: where most time went, and whether it matches the check-ins. Skip this section if computer activity is not available.

        GAPS
        One line about missed/skipped check-ins or unclear stretches (or "None").

        FOR TODAY
        - 1 to 3 suggested next steps, only if the log mentions unfinished or ongoing work.
        """
    }
}
