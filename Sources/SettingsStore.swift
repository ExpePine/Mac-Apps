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

    init() {
        defaults.register(defaults: [
            Keys.interval: 20,
            Keys.window: 2,
            Keys.autoOpen: true,
            Keys.sound: true,
            Keys.autoTranscribe: true,
            Keys.locale: "en-IN",
        ])
        intervalMinutes = defaults.integer(forKey: Keys.interval)
        entryWindowMinutes = defaults.integer(forKey: Keys.window)
        autoOpenWindow = defaults.bool(forKey: Keys.autoOpen)
        playSound = defaults.bool(forKey: Keys.sound)
        autoTranscribe = defaults.bool(forKey: Keys.autoTranscribe)
        speechLocaleID = defaults.string(forKey: Keys.locale) ?? "en-IN"
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
