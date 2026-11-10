import Foundation
import UserNotifications
import HawkeyeCore

@MainActor
protocol NotificationDelivering {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: NotificationDelivering {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

@MainActor
final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let log: ActivityLog
    private var center: (any NotificationDelivering)?
    private var pending: Task<Void, Never>?
    private var pendingPomodoro: Task<Void, Never>?
    private var pomodoroIdentifier: String?

    init(log: ActivityLog, effectsEnabled: Bool = true, center: (any NotificationDelivering)? = nil) {
        self.log = log
        self.center = center
        super.init()
        if center == nil && effectsEnabled && Bundle.main.bundleURL.pathExtension == "app" {
            let nativeCenter = UNUserNotificationCenter.current()
            nativeCenter.delegate = self
            self.center = nativeCenter
        }
    }

    func authorizationStatus() async -> FocusPermissionStatus {
        guard let center else { return .unavailable }
        switch await center.authorizationStatus() {
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
                let status = await center.authorizationStatus()
                guard !Task.isCancelled else { return }
                guard status == .authorized || status == .provisional else {
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

    func receive(pomodoro interval: PomodoroTimer.Interval, sessionID: UUID) {
        pendingPomodoro?.cancel()
        if let pomodoroIdentifier { center?.removePendingNotificationRequests(withIdentifiers: [pomodoroIdentifier]) }
        let identifier = "pomodoro-\(sessionID)-\(interval.startedAt.timeIntervalSinceReferenceDate)"
        pomodoroIdentifier = identifier
        pendingPomodoro = Task { [weak self] in
            guard let self, let center = self.center else { return }
            let status = await center.authorizationStatus()
            guard !Task.isCancelled else { return }
            guard status == .authorized || status == .provisional else {
                self.log.record("Notifications", "Pomodoro alert unavailable. Enable notifications in Focus permissions.")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = interval.phase == .breakTime ? "Time for a break" : "Time to focus"
            content.body = interval.phase == .breakTime
                ? "Your focus timer finished. Drink a glass of water. Monitoring stays active during your break."
                : "Your break is over. Your next focus session has started."
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                if Task.isCancelled {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    return
                }
                self.log.record("Notifications", "Pomodoro alert sent.")
            } catch {
                self.log.record("Notifications", "Pomodoro alert failed. \(error.localizedDescription)")
            }
        }
    }

    func cancelPomodoro() {
        pendingPomodoro?.cancel()
        pendingPomodoro = nil
        if let pomodoroIdentifier { center?.removePendingNotificationRequests(withIdentifiers: [pomodoroIdentifier]) }
        pomodoroIdentifier = nil
    }

    private func identifier(for task: TodoTask) -> String {
        "task-start-\(task.id)-\(task.dueAt?.timeIntervalSinceReferenceDate ?? 0)"
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
