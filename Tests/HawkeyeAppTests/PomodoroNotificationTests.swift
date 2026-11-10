import XCTest
import UserNotifications
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class PomodoroNotificationTests: XCTestCase {
    func testTaskFreeFocusCompletionDeliversHydrationAndBreakCompletionDeliversFocusAlert() async throws {
        let center = PomodoroNotificationCenter()
        let notifications = TaskNotifications(log: makeLog(), center: center)
        let start = Date()
        var timer = PomodoroTimer()
        timer.start(at: start)
        let sessionID = try XCTUnwrap(timer.session?.id)
        let rest = try XCTUnwrap(timer.advance(at: start.addingTimeInterval(1500)))
        notifications.receive(pomodoro: rest, sessionID: sessionID)
        await eventually { center.requests.count == 1 }
        XCTAssertTrue(center.requests[0].content.body.contains("Drink a glass of water"))
        XCTAssertTrue(center.requests[0].content.body.contains("Monitoring stays active"))
        XCTAssertNotNil(center.requests[0].content.sound)
        let focus = try XCTUnwrap(timer.advance(at: start.addingTimeInterval(1800)))
        notifications.receive(pomodoro: focus, sessionID: sessionID)
        await eventually { center.requests.count == 2 }
        XCTAssertTrue(center.requests[1].content.body.contains("break is over"))
        XCTAssertNotEqual(center.requests[0].identifier, center.requests[1].identifier)
    }

    func testDeniedNotificationPermissionDoesNotAttemptDelivery() async throws {
        let center = PomodoroNotificationCenter()
        center.status = .denied
        let log = makeLog()
        let notifications = TaskNotifications(log: log, center: center)
        var timer = PomodoroTimer()
        let start = Date()
        timer.start(at: start)
        notifications.receive(pomodoro: try XCTUnwrap(timer.advance(at: start.addingTimeInterval(1500))),
                              sessionID: try XCTUnwrap(timer.session?.id))
        await eventually { !log.entries.isEmpty }
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertTrue(log.entries.last?.message.contains("Enable notifications") == true)
    }

    func testStoppingTimerRemovesAnAlertThatFinishesDeliveryAfterCancellation() async throws {
        let center = PomodoroNotificationCenter()
        center.suspendDelivery = true
        let notifications = TaskNotifications(log: makeLog(), center: center)
        var timer = PomodoroTimer()
        let start = Date()
        timer.start(at: start)
        notifications.receive(pomodoro: try XCTUnwrap(timer.advance(at: start.addingTimeInterval(1500))),
                              sessionID: try XCTUnwrap(timer.session?.id))
        await eventually { center.requests.count == 1 }
        notifications.cancelPomodoro()
        center.resumeDelivery()
        await eventually { !center.removedDelivered.isEmpty }
        XCTAssertEqual(center.removedDelivered, center.requests.map(\.identifier))
        XCTAssertEqual(Set(center.removedPending), Set(center.requests.map(\.identifier)))
    }

    func testStoppingTimerRemovesAnAcceptedRequestBeforeTheSystemDeliversIt() async throws {
        let center = PomodoroNotificationCenter()
        let log = makeLog()
        let notifications = TaskNotifications(log: log, center: center)
        var timer = PomodoroTimer()
        let start = Date()
        timer.start(at: start)
        notifications.receive(pomodoro: try XCTUnwrap(timer.advance(at: start.addingTimeInterval(1500))),
                              sessionID: try XCTUnwrap(timer.session?.id))
        await eventually { log.entries.contains { $0.message == "Pomodoro alert sent." } }
        notifications.cancelPomodoro()
        XCTAssertEqual(center.removedPending, center.requests.map(\.identifier))
        XCTAssertTrue(center.removedDelivered.isEmpty)
    }

    private func makeLog() -> ActivityLog {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-pomodoro-notifications-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ActivityLog(fileURL: directory.appendingPathComponent("activity.log"))
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected notification effect did not occur", file: file, line: line)
    }
}

@MainActor
private final class PomodoroNotificationCenter: NotificationDelivering {
    var status: UNAuthorizationStatus = .authorized
    var requests: [UNNotificationRequest] = []
    var removedPending: [String] = []
    var removedDelivered: [String] = []
    var suspendDelivery = false
    private var continuation: CheckedContinuation<Void, Never>?

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { status == .authorized }
    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
        if suspendDelivery { await withCheckedContinuation { continuation = $0 } }
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { removedPending += identifiers }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removedDelivered += identifiers }
    func resumeDelivery() { continuation?.resume(); continuation = nil }
}
