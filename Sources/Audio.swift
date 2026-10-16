import AVFoundation
import Speech

// MARK: - Recording

enum AudioError: LocalizedError {
    case micDenied, couldNotStart
    var errorDescription: String? {
        switch self {
        case .micDenied:
            return "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        case .couldNotStart:
            return "Couldn't start recording."
        }
    }
}

final class AudioRecorder {
    private var recorder: AVAudioRecorder?

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    static func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        guard r.record() else { throw AudioError.couldNotStart }
        recorder = r
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }
}

// MARK: - Playback (History window)

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(id: UUID, url: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        playingID = id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - Speech to text (Apple Speech framework)

enum TranscriberError: LocalizedError {
    case notAuthorized, unavailable
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition is off. Turn it on in System Settings → Privacy & Security → Speech Recognition."
        case .unavailable:
            return "Speech recognition isn't available for the selected language right now."
        }
    }
}

/// Transcribes a recorded audio file. Prefers on-device recognition when the
/// selected language supports it; otherwise Apple's server is used.
final class Transcriber {
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?

    static func ensureAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    func transcribe(url: URL, localeID: String) async throws -> String {
        guard await Self.ensureAuthorized() else { throw TranscriberError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              recognizer.isAvailable else { throw TranscriberError.unavailable }
        self.recognizer = recognizer

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { cont in
            self.task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    once.run { cont.resume(returning: text) }
                } else if let error {
                    once.run { cont.resume(throwing: error) }
                }
            }
        }
    }
}

/// Guards a continuation against being resumed twice.
private final class ResumeOnce {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
