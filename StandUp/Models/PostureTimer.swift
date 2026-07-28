import Foundation

enum TimerRunState: Equatable, Sendable {
    case idle
    case running
    case paused
}

final class PostureTimer: ObservableObject {
    @Published private(set) var posture: Posture = .sitting
    @Published private(set) var runState: TimerRunState = .idle
    @Published private(set) var remaining: TimeInterval = 0

    private var settings: TimerSettings
    private var timer: Timer?
    private let intervalGranularity: TimeInterval = 1.0

    init(settings: TimerSettings) {
        self.settings = settings
        self.remaining = settings.interval(for: posture)
    }

    func updateSettings(_ settings: TimerSettings) {
        // If not running, re-seed remaining with the new duration for the current posture.
        if runState != .running {
            remaining = settings.interval(for: posture)
        }
        self.settings = settings
    }

    func start() {
        guard runState != .running else { return }
        runState = .running
        scheduleTick()
    }

    func pause() {
        guard runState == .running else { return }
        runState = .paused
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        runState = .idle
        posture = .sitting
        remaining = settings.interval(for: posture)
    }

    func switchMode() {
        posture = posture.opposite
        remaining = settings.interval(for: posture)
        if runState == .running {
            scheduleTick()
        }
    }

    private func scheduleTick() {
        timer?.invalidate()
        let t = Timer(timeInterval: intervalGranularity, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard runState == .running else { return }
        remaining -= intervalGranularity
        if remaining <= 0 {
            onComplete()
        }
    }

    private func onComplete() {
        timer?.invalidate()
        timer = nil
        posture = posture.opposite
        remaining = settings.interval(for: posture)
        NotificationCenter.default.post(
            name: Static.tickCompleteNotification,
            object: nil,
            userInfo: ["posture": posture]
        )
        if runState == .running {
            scheduleTick()
        }
    }

    enum Static {
        static let tickCompleteNotification = Notification.Name("StandUp.timer.tickComplete")
    }
}