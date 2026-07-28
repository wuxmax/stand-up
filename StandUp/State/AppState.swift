import Foundation
import SwiftUI

/// Central app state. Wires together timer settings, the posture timer,
/// notifications, and (optionally) the desk controller.
@MainActor
final class AppState: ObservableObject {
    @Published var timerSettings: TimerSettings
    @Published var deskSettings: DeskSettings
    @Published var deskSnapshot: DeskSnapshot = .idle
    @Published var deskLog: [String] = []
    @Published var autoControlDesk: Bool = false
    @Published var isDeskControlEnabled: Bool = false
    @Published var notificationsAuthorized: Bool = false

    let postureTimer: PostureTimer
    let notificationManager = NotificationManager.shared

    private var desk: DeskController?
    private var deskEventTask: Task<Void, Never>?
    private var tickObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?

    init() {
        let timerSettings = UserDefaults.standard.loadTimerSettings() ?? .default
        let deskSettings = UserDefaults.standard.loadDeskSettings() ?? .default
        self.timerSettings = timerSettings
        self.deskSettings = deskSettings
        self.postureTimer = PostureTimer(settings: timerSettings)
        self.tickObserver = NotificationCenter.default.addObserver(
            forName: PostureTimer.Static.tickCompleteNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let posture = (note.userInfo?["posture"] as? Posture) ?? .sitting
            Task { @MainActor in self.handleTickComplete(newPosture: posture) }
        }
        self.didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNotificationStatus() }
        }
    }

    func onAppear() {
        refreshNotificationStatus()
        notificationManager.requestAuthorizationIfNeeded { [weak self] status in
            Task { @MainActor in self?.applyNotificationStatus(status) }
        }
    }

    func onDisappear() {
        // The menu bar popover opens/closes frequently; do NOT tear down the
        // desk connection here. Desk teardown happens only on app quit
        // (implicit) or when the user disables desk control.
    }

    func refreshNotificationStatus() {
        notificationManager.currentStatus { [weak self] status in
            Task { @MainActor in self?.applyNotificationStatus(status) }
        }
    }

    func openSystemNotificationSettings() {
        notificationManager.openSystemNotificationsSettings()
    }

    private func applyNotificationStatus(_ status: NotificationManager.Status) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            notificationsAuthorized = true
        case .notDetermined, .denied:
            notificationsAuthorized = false
        }
    }

    func updateTimerSettings(_ settings: TimerSettings) {
        timerSettings = settings
        postureTimer.updateSettings(settings)
        UserDefaults.standard.saveTimerSettings(settings)
    }

    func updateDeskSettings(_ settings: DeskSettings) {
        deskSettings = settings
        UserDefaults.standard.saveDeskSettings(settings)
        // Re-create the desk controller if desk control is active so new settings take effect.
        if isDeskControlEnabled {
            restartDeskController()
        }
    }

    func setDeskControlEnabled(_ enabled: Bool) {
        isDeskControlEnabled = enabled
        if enabled {
            restartDeskController()
        } else {
            deskEventTask?.cancel()
            deskEventTask = nil
            desk?.disconnect()
            desk = nil
            deskSnapshot = .idle
        }
    }

    func switchModeNow() {
        postureTimer.switchMode()
        if autoControlDesk && isDeskControlEnabled {
            Task { await moveDeskToCurrentPosture() }
        }
    }

    func moveDeskToCurrentPosture() async {
        guard let desk else { return }
        let target: DeskTarget = (postureTimer.posture == .sitting) ? .sit : .stand
        await desk.moveTo(target)
    }

    private func handleTickComplete(newPosture: Posture) {
        switch newPosture {
        case .standing: notificationManager.sendStandUpNotification()
        case .sitting:  notificationManager.sendSitDownNotification()
        }
        if autoControlDesk && isDeskControlEnabled {
            Task { await moveDeskToCurrentPosture() }
        }
    }

    private func restartDeskController() {
        deskEventTask?.cancel()
        desk?.disconnect()
        let controller = DeskFactory.make(mode: deskSettings.controlMode, settings: deskSettings)
        desk = controller
        deskSnapshot = .idle
        deskEventTask = Task { [weak controller, weak self] in
            guard let controller, let self else { return }
            // Buffer events: forward snapshots/log to @Published state.
            let buffer = EventBuffer(handler: { [weak self] event in
                Task { @MainActor in self?.handleDeskEvent(event) }
            })
            controller.eventHandler = buffer.handle
            await controller.connect()
        }
    }

    private func handleDeskEvent(_ event: DeskEvent) {
        switch event {
        case .snapshot(let snap):
            deskSnapshot = snap
        case .log(let line):
            deskLog.append(line)
            if deskLog.count > 200 { deskLog.removeFirst(deskLog.count - 200) }
        }
    }
}

private final class EventBuffer {
    let handler: (DeskEvent) -> Void
    init(handler: @escaping (DeskEvent) -> Void) { self.handler = handler }
    func handle(_ event: DeskEvent) { handler(event) }
}

// MARK: - UserDefaults persistence

private let timerSettingsKey = "StandUp.timerSettings"
private let deskSettingsKey = "StandUp.deskSettings"

extension UserDefaults {
    func loadTimerSettings() -> TimerSettings? {
        guard let data = data(forKey: timerSettingsKey) else { return nil }
        return try? JSONDecoder().decode(TimerSettings.self, from: data)
    }
    func saveTimerSettings(_ settings: TimerSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            set(data, forKey: timerSettingsKey)
        }
    }
    func loadDeskSettings() -> DeskSettings? {
        guard let data = data(forKey: deskSettingsKey) else { return nil }
        return try? JSONDecoder().decode(DeskSettings.self, from: data)
    }
    func saveDeskSettings(_ settings: DeskSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            set(data, forKey: deskSettingsKey)
        }
    }
}