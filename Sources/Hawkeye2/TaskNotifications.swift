import Foundation
import UserNotifications
import HawkeyeCore

@MainActor
final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let log: ActivityLog
    private var center: UNUserNotificationCenter?
    private var pending: Task<Void, Never>?

    init(log: ActivityLog, effectsEnabled: Bool = true) {
        self.log = log
        super.init()
        if effectsEnabled && Bundle.main.bundleURL.pathExtension == "app" {
            center = UNUserNotificationCenter.current()
            center?.delegate = self
        }
    }

    func authorizationStatus() async -> FocusPermissionStatus {
        guard let center else { return .unavailable }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        default: return .needsAccess
        }
    }

    func requestAuthorization() async {
        guard let center else {
            log.record("Notifications", "Notifications require the packaged .app. Build and open Hawkeye 2 Dev.app.")
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            log.record("Notifications", granted ? "Notification permission granted." : "Notification permission denied. Enable notifications in System Settings.")
        } catch {
            log.record("Notifications", "Permission request failed. \(error.localizedDescription)")
        }
    }

    func receive(_ event: TaskFocusEvent) {
        switch event {
        case .activated(let task, let notify) where notify:
            pending?.cancel()
            pending = Task { [weak self] in
                guard let self, let center = self.center else { return }
                let settings = await center.notificationSettings()
                guard !Task.isCancelled else { return }
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    self.log.record("Notifications", "Start alert unavailable for \(task.title). Notification permission is disabled.")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = task.title
                content.body = "It's time to start."
                content.sound = .default
                let identifier = self.identifier(for: task)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                do {
                    try await center.add(request)
                    guard !Task.isCancelled else {
                        center.removePendingNotificationRequests(withIdentifiers: [identifier])
                        center.removeDeliveredNotifications(withIdentifiers: [identifier])
                        return
                    }
                    self.log.record("Notifications", "Start alert sent for \(task.title).")
                } catch {
                    self.log.record("Notifications", "Start alert failed. \(error.localizedDescription)")
                }
            }
        case .deactivated(let task, _):
            pending?.cancel()
            center?.removePendingNotificationRequests(withIdentifiers: [identifier(for: task)])
            center?.removeDeliveredNotifications(withIdentifiers: [identifier(for: task)])
        default: break
        }
    }

    private func identifier(for task: TodoTask) -> String {
        "task-start-\(task.id)-\(task.dueAt?.timeIntervalSinceReferenceDate ?? 0)"
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
