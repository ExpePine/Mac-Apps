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

    /// Single-turn helper.
    static func complete(apiKey: String, model: String, system: String, user: String,
                         jsonMode: Bool = false) async throws -> String {
        try await chat(apiKey: apiKey, model: model,
                       messages: [["role": "system", "content": system], ["role": "user", "content": user]],
                       jsonMode: jsonMode)
    }

    /// Multi-turn chat. `messages` use roles system / user / assistant.
    static func chat(apiKey: String, model: String, messages: [[String: String]],
                     jsonMode: Bool = false) async throws -> String {
        do {
            return try await send(apiKey: apiKey, model: model, messages: messages, jsonMode: jsonMode)
        } catch let f as Failure where jsonMode && f.message.contains("400") {
            // Model may not support JSON mode; the prompt still asks for JSON.
            return try await send(apiKey: apiKey, model: model, messages: messages, jsonMode: false)
        }
    }

    private static func send(apiKey: String, model: String, messages: [[String: String]],
                             jsonMode: Bool) async throws -> String {
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw Failure(message: "Bad Groq URL")
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 90)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "temperature": 0.2, "messages": messages]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
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
            throw Failure(message: "Groq returned an empty answer")
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
                     to recipients: [String], subject: String, body: String, html: String? = nil) async throws {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        // base64 keeps every line under SMTP's 998-character limit.
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString(options: [.lineLength76Characters,
                                                       .endLineWithCarriageReturn, .endLineWithLineFeed])
        }

        var headers = [
            "From: Activity Logger <\(username)>",
            "To: \(recipients.joined(separator: ", "))",
            "Subject: \(subject)",
            "Date: \(dateFormatter.string(from: Date()))",
            "MIME-Version: 1.0",
        ]
        let content: String
        if let html {
            let boundary = "AL-\(UUID().uuidString)"
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
    private let goals: GoalsStore
    let archive: ReportArchive
    private let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?
    private var nextRetry: Date?

    private enum Keys {
        static let lastSentDay = "reportLastSentDay"
        static let lastStatus = "reportLastStatus"
    }

    init(settings: SettingsStore, store: EntryStore, usage: UsageStore, goals: GoalsStore, archive: ReportArchive) {
        self.settings = settings
        self.store = store
        self.usage = usage
        self.goals = goals
        self.archive = archive
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
        await archiveYesterdayIfNeeded()
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

    /// Builds the recap for one day (the same data the email and the Reports view use).
    func buildRecap(for day: Date, includeUsage: Bool = true) async -> DailyRecap {
        let dayText = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let entries = store.entries(on: day).sorted { $0.periodStart < $1.periodStart }
        let dayUsage = includeUsage ? usage.usage(for: day) : nil
        let hasUsage = (dayUsage?.activeSeconds ?? 0) >= 60
        return await RecapBuilder.build(dayText: dayText, entries: entries,
                                        usage: hasUsage ? dayUsage : nil,
                                        goals: goals.goals(on: day),
                                        apiKey: Keychain.get(Keychain.groqAPIKey),
                                        model: settings.groqModel)
    }

    /// Builds and stores a day's report (Reports view "Generate").
    func generateReport(for day: Date) async {
        archive.save(await buildRecap(for: day), for: day)
    }

    /// Once a day, store yesterday's report even if the email is turned off.
    private func archiveYesterdayIfNeeded() async {
        let cal = Calendar.current
        let now = Date()
        guard cal.component(.hour, from: now) >= 5 else { return }
        let key = Self.dayKey(now)
        guard defaults.string(forKey: "reportArchivedDay") != key else { return }
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
        defaults.set(key, forKey: "reportArchivedDay")
        // Also replaces a report that was generated "so far" during the day.
        if archive.hasActivity(yesterday) && (!archive.hasRecord(yesterday) || archive.isStale(yesterday)) {
            await generateReport(for: yesterday)
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

        if entries.isEmpty && !hasUsage && settings.reportSkipEmptyDays && !isTest {
            setStatus("No entries for \(dayText) - nothing to send.")
            return true
        }

        let recap = await buildRecap(for: day, includeUsage: settings.includeUsageInEmail)
        archive.save(recap, for: day)
        let body = RecapRenderer.text(recap)
        let html = RecapRenderer.html(recap)
        let shortDay = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let subject = (isTest ? "[Test] " : "") + "Daily recap - \(shortDay)"

        do {
            try await Mailer.send(host: settings.smtpHost, port: settings.smtpPort,
                                  username: settings.smtpUsername, password: password,
                                  to: recipients, subject: subject, body: body, html: html)
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
