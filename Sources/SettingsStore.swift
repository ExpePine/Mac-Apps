import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let interval = "intervalMinutes"
        static let window = "entryWindowMinutes"
        static let autoOpen = "autoOpenWindow"
        static let sound = "playSound"
        static let autoTranscribe = "autoTranscribe"
        static let locale = "speechLocaleID"
        static let reportEnabled = "reportEnabled"
        static let reportHour = "reportHour"
        static let reportMinute = "reportMinute"
        static let reportRecipient = "reportRecipient"
        static let reportSkipEmpty = "reportSkipEmptyDays"
        static let smtpHost = "smtpHost"
        static let smtpPort = "smtpPort"
        static let smtpUsername = "smtpUsername"
        static let groqModel = "groqModel"
        static let trackUsage = "trackUsage"
        static let idleMinutes = "idleMinutes"
        static let excludedDomains = "excludedDomains"
        static let includeUsageInEmail = "includeUsageInEmail"
        static let coachChecks = "coachChecksEnabled"
        static let askGoalsMorning = "askGoalsMorning"
    }

    static let intervalPresets = [15, 20, 30, 40, 60]
    static let speechLocales: [(id: String, name: String)] = [
        ("en-IN", "English (India)"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("hi-IN", "Hindi"),
    ]

    private let defaults = UserDefaults.standard

    /// How often the check-in fires (minutes).
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: Keys.interval) } }
    /// How long the entry window stays open before auto-saving (minutes).
    @Published var entryWindowMinutes: Int { didSet { defaults.set(entryWindowMinutes, forKey: Keys.window) } }
    /// Open the entry window automatically when the check-in fires.
    @Published var autoOpenWindow: Bool { didSet { defaults.set(autoOpenWindow, forKey: Keys.autoOpen) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.sound) } }
    /// Convert voice notes to text automatically after recording.
    @Published var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: Keys.autoTranscribe) } }
    @Published var speechLocaleID: String { didSet { defaults.set(speechLocaleID, forKey: Keys.locale) } }

    // MARK: Daily summary email
    @Published var reportEnabled: Bool { didSet { defaults.set(reportEnabled, forKey: Keys.reportEnabled) } }
    @Published var reportHour: Int { didSet { defaults.set(reportHour, forKey: Keys.reportHour) } }
    @Published var reportMinute: Int { didSet { defaults.set(reportMinute, forKey: Keys.reportMinute) } }
    /// One or more addresses, comma-separated.
    @Published var reportRecipient: String { didSet { defaults.set(reportRecipient, forKey: Keys.reportRecipient) } }
    @Published var reportSkipEmptyDays: Bool { didSet { defaults.set(reportSkipEmptyDays, forKey: Keys.reportSkipEmpty) } }
    @Published var smtpHost: String { didSet { defaults.set(smtpHost, forKey: Keys.smtpHost) } }
    @Published var smtpPort: Int { didSet { defaults.set(smtpPort, forKey: Keys.smtpPort) } }
    /// Sender address / SMTP login. The password lives in the Keychain.
    @Published var smtpUsername: String { didSet { defaults.set(smtpUsername, forKey: Keys.smtpUsername) } }
    @Published var groqModel: String { didSet { defaults.set(groqModel, forKey: Keys.groqModel) } }

    // MARK: Website & app tracking
    @Published var trackUsage: Bool { didSet { defaults.set(trackUsage, forKey: Keys.trackUsage) } }
    /// No keyboard/mouse input for this long = idle (not counted).
    @Published var idleMinutes: Int { didSet { defaults.set(idleMinutes, forKey: Keys.idleMinutes) } }
    /// Comma-separated domains to hide, e.g. "hdfcbank.com, mail.google.com".
    @Published var excludedDomains: String { didSet { defaults.set(excludedDomains, forKey: Keys.excludedDomains) } }
    @Published var includeUsageInEmail: Bool { didSet { defaults.set(includeUsageInEmail, forKey: Keys.includeUsageInEmail) } }

    // MARK: Coach
    /// Compare each check-in with today's goals and ask about deviations.
    @Published var coachChecksEnabled: Bool { didSet { defaults.set(coachChecksEnabled, forKey: Keys.coachChecks) } }
    /// Open the Goals screen the first time you're at the Mac each day.
    @Published var askGoalsMorning: Bool { didSet { defaults.set(askGoalsMorning, forKey: Keys.askGoalsMorning) } }

    init() {
        defaults.register(defaults: [
            Keys.interval: 20,
            Keys.window: 2,
            Keys.autoOpen: true,
            Keys.sound: true,
            Keys.autoTranscribe: true,
            Keys.locale: "en-IN",
            Keys.reportEnabled: false,
            Keys.reportHour: 8,
            Keys.reportMinute: 0,
            Keys.reportRecipient: "",
            Keys.reportSkipEmpty: true,
            Keys.smtpHost: "smtp.gmail.com",
            Keys.smtpPort: 465,
            Keys.smtpUsername: "",
            Keys.groqModel: "openai/gpt-oss-120b",
            Keys.trackUsage: true,
            Keys.idleMinutes: 2,
            Keys.excludedDomains: "",
            Keys.includeUsageInEmail: true,
            Keys.coachChecks: true,
            Keys.askGoalsMorning: true,
        ])
        intervalMinutes = defaults.integer(forKey: Keys.interval)
        entryWindowMinutes = defaults.integer(forKey: Keys.window)
        autoOpenWindow = defaults.bool(forKey: Keys.autoOpen)
        playSound = defaults.bool(forKey: Keys.sound)
        autoTranscribe = defaults.bool(forKey: Keys.autoTranscribe)
        speechLocaleID = defaults.string(forKey: Keys.locale) ?? "en-IN"
        reportEnabled = defaults.bool(forKey: Keys.reportEnabled)
        reportHour = defaults.integer(forKey: Keys.reportHour)
        reportMinute = defaults.integer(forKey: Keys.reportMinute)
        reportRecipient = defaults.string(forKey: Keys.reportRecipient) ?? ""
        reportSkipEmptyDays = defaults.bool(forKey: Keys.reportSkipEmpty)
        smtpHost = defaults.string(forKey: Keys.smtpHost) ?? "smtp.gmail.com"
        smtpPort = defaults.integer(forKey: Keys.smtpPort)
        smtpUsername = defaults.string(forKey: Keys.smtpUsername) ?? ""
        groqModel = defaults.string(forKey: Keys.groqModel) ?? "openai/gpt-oss-120b"
        trackUsage = defaults.bool(forKey: Keys.trackUsage)
        idleMinutes = max(1, defaults.integer(forKey: Keys.idleMinutes))
        excludedDomains = defaults.string(forKey: Keys.excludedDomains) ?? ""
        includeUsageInEmail = defaults.bool(forKey: Keys.includeUsageInEmail)
        coachChecksEnabled = defaults.bool(forKey: Keys.coachChecks)
        askGoalsMorning = defaults.bool(forKey: Keys.askGoalsMorning)
    }
}

/// Launch-at-login via SMAppService (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
