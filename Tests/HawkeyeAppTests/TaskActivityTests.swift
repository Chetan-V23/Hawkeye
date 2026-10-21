import XCTest
import Combine
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class TaskActivityTests: XCTestCase {
    func testTimerPublishesActivationAndCompletionHandsOffThroughEventListeners() async throws {
        let fixture = try makeFixture()
        let start = Date().addingTimeInterval(0.3)
        let first = try await fixture.service.addTask(title: "First", dueAt: start, duration: 60)
        let next = try await fixture.service.addTask(title: "Second", dueAt: start, duration: 60)
        let activation = expectation(description: "First task activates at its boundary")
        var events: [TaskFocusEvent] = []
        let subscription = fixture.model.focusEvents.sink { event in
            events.append(event)
            if case .activated(let task, _) = event, task.id == first.id { activation.fulfill() }
        }
        defer { subscription.cancel() }
        await fixture.model.start()
        await fulfillment(of: [activation], timeout: 3)
        XCTAssertEqual(fixture.model.activeTaskID, first.id)
        XCTAssertTrue(fixture.model.canPause(first))
        let completed = expectation(description: "Completion saved")
        fixture.model.complete(first.id) { success in
            XCTAssertTrue(success)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(fixture.model.activeTaskID, next.id)
        XCTAssertTrue(events.contains { if case .deactivated(_, .completed) = $0 { return true }; return false })
        let log = try String(contentsOf: fixture.model.activity.fileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("Activated First."))
        XCTAssertTrue(log.contains("Completed First."))
        XCTAssertTrue(log.contains("Activated Second."))
    }

    func testTimerDeactivatesExpiredTaskWithoutRemoteSyncOrUIClock() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.service.addTask(title: "Brief task", dueAt: Date().addingTimeInterval(-1), duration: 1.3)
        let expired = expectation(description: "Task expires at end boundary")
        let subscription = fixture.model.focusEvents.sink { event in
            if case .deactivated(_, .expired) = event { expired.fulfill() }
        }
        defer { subscription.cancel() }
        await fixture.model.start()
        XCTAssertNotNil(fixture.model.activeTaskID)
        await fulfillment(of: [expired], timeout: 3)
        XCTAssertNil(fixture.model.activeTaskID)
    }

    func testStartNowActivatesThroughEventsRefreshesScheduleAndLogsAction() async throws {
        let fixture = try makeFixture()
        let task = try await fixture.service.addTask(title: "Overdue", dueAt: Date().addingTimeInterval(-3600))
        await fixture.model.start()
        XCTAssertNil(fixture.model.activeTaskID)
        var activations = 0
        let subscription = fixture.model.focusEvents.sink { event in
            if case .activated(let active, _) = event, active.id == task.id { activations += 1 }
        }
        defer { subscription.cancel() }
        let completed = expectation(description: "Manual start saved")
        let beforeStart = Date()
        fixture.model.startNow(task) { success in
            XCTAssertTrue(success)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(fixture.model.activeTaskID, task.id)
        XCTAssertEqual(activations, 1)
        let start = try XCTUnwrap(fixture.model.tasks.first { $0.id == task.id }?.dueAt)
        XCTAssertGreaterThanOrEqual(start, beforeStart)
        XCTAssertLessThanOrEqual(start, Date())
        XCTAssertTrue(fixture.model.activity.entries.contains { $0.message == "Started now Overdue." })
    }

    private func makeFixture() throws -> (service: TaskService, model: AppModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-activity-\(UUID())")
        let suite = "hawkeye-activity-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = try TaskService(store: JSONTaskStore(url: directory.appendingPathComponent("tasks.json")))
        let model = AppModel(service: service, client: TickTickClient(token: "unused-test-token"),
                             project: ProjectOption(id: "p", name: "Test"), preferences: preferences,
                             tokenStore: .file(directory.appendingPathComponent("token.txt")))
        return (service, model)
    }
}
