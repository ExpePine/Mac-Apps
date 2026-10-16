import Foundation

/// Fires `onPrompt(periodStart, periodEnd)` every N minutes.
/// Uses a polling loop against a target date (not a repeating Timer), so it
/// behaves sensibly after the Mac sleeps: if we wake up long past the due
/// time, it quietly resets instead of asking about a multi-hour gap.
@MainActor
final class Scheduler: ObservableObject {
    @Published private(set) var nextFire: Date
    @Published private(set) var isPaused = false
    private(set) var lastFire: Date

    var onPrompt: (@MainActor (Date, Date) -> Void)?

    private let settings: SettingsStore
    private var scheduledInterval: Int
    private var loop: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
        let now = Date()
        lastFire = now
        scheduledInterval = settings.intervalMinutes
        nextFire = now.addingTimeInterval(TimeInterval(settings.intervalMinutes * 60))
        startLoop()
    }

    private var interval: TimeInterval { TimeInterval(settings.intervalMinutes * 60) }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard !isPaused else { return }
        let now = Date()

        // Interval changed in settings: keep the current period start,
        // re-target the next fire (but never sooner than 1 minute from now).
        if settings.intervalMinutes != scheduledInterval {
            scheduledInterval = settings.intervalMinutes
            nextFire = max(lastFire.addingTimeInterval(interval), now.addingTimeInterval(60))
        }

        guard now >= nextFire else { return }

        // Woke from sleep / long away: don't prompt for a huge gap, just reset.
        if now.timeIntervalSince(nextFire) > interval {
            restart()
            return
        }

        let start = lastFire
        lastFire = now
        nextFire = now.addingTimeInterval(interval)
        onPrompt?(start, now)
    }

    /// Start a fresh period from now.
    func restart() {
        let now = Date()
        lastFire = now
        scheduledInterval = settings.intervalMinutes
        nextFire = now.addingTimeInterval(interval)
    }

    func pause() { isPaused = true }

    func resume() {
        isPaused = false
        restart()
    }
}
