import AppKit
import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    enum Status: Equatable {
        case notDetermined
        case denied
        case authorized
        case provisional
        case ephemeral
    }

    private init() {}

    func currentStatus(_ completion: @escaping (Status) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: Status
            switch settings.authorizationStatus {
            case .notDetermined: status = .notDetermined
            case .denied:        status = .denied
            case .authorized:    status = .authorized
            case .provisional:   status = .provisional
            case .ephemeral:     status = .ephemeral
            @unknown default:    status = .denied
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    func requestAuthorizationIfNeeded(_ completion: @escaping (Status) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { _, error in
                    if let error = error {
                        print("Notification authorization error: \(error)")
                    }
                    self.currentStatus(completion)
                }
            default:
                self.currentStatus(completion)
            }
        }
    }

    func openSystemNotificationsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func sendStandUpNotification() {
        send(title: "Time to stand up",
             body: "Your sitting interval is over. Stand up and move the desk up.",
             posture: .standing)
    }

    func sendSitDownNotification() {
        send(title: "Time to sit down",
             body: "Your standing interval is over. You can sit down again.",
             posture: .sitting)
    }

    private func send(title: String, body: String, posture: Posture) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["StandUpPosture": posture.rawValue]

        let request = UNNotificationRequest(
            identifier: "StandUp.posture.\(posture.rawValue).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error)")
            }
        }
    }
}