import XCTest
@testable import HawkeyeCore

final class TaskFocusTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testActivatesAtStartAndExpiresAtDefaultThirtyMinuteEnd() async throws {
        let service = try makeService()
        let task = try await service.addTask(title: "Start here", dueAt: start)
        let before = try await service.evaluateFocus(at: start.addingTimeInterval(-1))
        XCTAssertNil(before.activeTask)
        XCTAssertEqual(before.nextTransitionAt, start)
        let began = try await service.evaluateFocus(at: start)
        XCTAssertEqual(began.activeTask?.id, task.id)
        XCTAssertEqual(began.events, [.activated(task, notify: true)])
        XCTAssertEqual(began.nextTransitionAt, start.addingTimeInterval(1800))
        let during = try await service.evaluateFocus(at: start.addingTimeInterval(1799))
        XCTAssertTrue(during.events.isEmpty)
        let ended = try await service.evaluateFocus(at: start.addingTimeInterval(1800))
        XCTAssertNil(ended.activeTask)
        XCTAssertEqual(ended.events, [.deactivated(task, reason: .expired)])
        XCTAssertTrue(task.isOverdue(at: start.addingTimeInterval(1800)))
    }

    func testEarliestStartWinsAndCompletionHandsOffToNextEligibleTask() async throws {
        let service = try makeService()
        let later = try await service.addTask(title: "B", dueAt: start.addingTimeInterval(60), duration: 1800)
        let first = try await service.addTask(title: "A", dueAt: start, duration: 1800)
        let began = try await service.evaluateFocus(at: start.addingTimeInterval(120))
        XCTAssertEqual(began.activeTask?.id, first.id)
        try await service.setCompleted(id: first.id, completed: true)
        let handoff = try await service.evaluateFocus(at: start.addingTimeInterval(120))
        XCTAssertEqual(handoff.activeTask?.id, later.id)
        XCTAssertEqual(handoff.events, [.deactivated(first, reason: .completed), .activated(later, notify: true)])
    }

    func testOverlappingExpiredTaskIsSkippedAndUntimedTasksNeverActivate() async throws {
        let service = try makeService()
        let first = try await service.addTask(title: "A", dueAt: start, duration: 1800)
        _ = try await service.addTask(title: "Expired B", dueAt: start.addingTimeInterval(60), duration: 60)
        _ = try await service.addTask(title: "Untimed")
        _ = try await service.evaluateFocus(at: start.addingTimeInterval(300))
        try await service.setCompleted(id: first.id, completed: true)
        let after = try await service.evaluateFocus(at: start.addingTimeInterval(300))
        XCTAssertNil(after.activeTask)
    }

    func testExpirationHandsOffWithoutCompletion() async throws {
        let service = try makeService()
        _ = try await service.addTask(title: "A", dueAt: start, duration: 120)
        let next = try await service.addTask(title: "B", dueAt: start.addingTimeInterval(60))
        _ = try await service.evaluateFocus(at: start)
        let update = try await service.evaluateFocus(at: start.addingTimeInterval(120))
        XCTAssertEqual(update.activeTask?.id, next.id)
    }

    func testShorteningActiveDurationEmitsExpiration() async throws {
        let service = try makeService()
        var task = try await service.addTask(title: "A", dueAt: start, duration: 1800)
        _ = try await service.evaluateFocus(at: start.addingTimeInterval(60))
        task.duration = 30
        _ = try await service.updateTask(task)
        let update = try await service.evaluateFocus(at: start.addingTimeInterval(60))
        XCTAssertNil(update.activeTask)
        guard case .deactivated(_, .expired) = update.events.first else {
            return XCTFail("The changed duration must expire the active task.")
        }
    }

    func testPauseSuppressesAllTasksAndDoesNotChangeSchedulesOrOutbox() async throws {
        let service = try makeService()
        let task = try await service.addTask(title: "A", dueAt: start)
        _ = try await service.addTask(title: "B", dueAt: start.addingTimeInterval(30))
        let before = await service.snapshot()
        let pause = try await service.pause(id: task.id, minutes: 3, at: start)
        XCTAssertNil(pause.activeTask)
        XCTAssertEqual(pause.user.snooze, UserSnooze(taskID: task.id, until: start.addingTimeInterval(180)))
        let during = try await service.evaluateFocus(at: start.addingTimeInterval(60))
        XCTAssertNil(during.activeTask)
        let after = await service.snapshot()
        XCTAssertEqual(before.tasks, after.tasks)
        XCTAssertEqual(before.outbox, after.outbox)
        let resumed = try await service.evaluateFocus(at: start.addingTimeInterval(180))
        XCTAssertEqual(resumed.activeTask?.id, task.id)
        XCTAssertEqual(resumed.events, [.snoozeEnded, .activated(task, notify: false)])
        do {
            _ = try await service.pause(id: task.id, minutes: 2, at: start.addingTimeInterval(180))
            XCTFail("A task can only be paused once.")
        } catch { XCTAssertEqual(error as? TaskFocusError, .alreadySnoozed) }
    }

    func testAnotherTaskGetsItsOwnPauseAllowanceAfterGlobalPause() async throws {
        let service = try makeService()
        let first = try await service.addTask(title: "A", dueAt: start, duration: 60)
        let next = try await service.addTask(title: "B", dueAt: start.addingTimeInterval(30))
        _ = try await service.pause(id: first.id, minutes: 2, at: start)
        let resumed = try await service.evaluateFocus(at: start.addingTimeInterval(120))
        XCTAssertEqual(resumed.activeTask?.id, next.id)
        let paused = try await service.pause(id: next.id, minutes: 5, at: start.addingTimeInterval(120))
        XCTAssertNil(paused.activeTask)
        XCTAssertEqual(paused.user.snoozedTaskIDs, [first.id, next.id])
    }

    func testCompletionDuringPauseDoesNotActivateOverlappingTask() async throws {
        let service = try makeService()
        let first = try await service.addTask(title: "A", dueAt: start)
        _ = try await service.addTask(title: "B", dueAt: start.addingTimeInterval(30))
        _ = try await service.pause(id: first.id, minutes: 2, at: start)
        try await service.setCompleted(id: first.id, completed: true)
        let update = try await service.evaluateFocus(at: start.addingTimeInterval(60))
        XCTAssertNil(update.activeTask)
    }

    func testPauseDoesNotExtendTheOriginalTaskWindow() async throws {
        let service = try makeService()
        let task = try await service.addTask(title: "A", dueAt: start, duration: 60)
        _ = try await service.pause(id: task.id, minutes: 5, at: start)
        let update = try await service.evaluateFocus(at: start.addingTimeInterval(300))
        XCTAssertNil(update.activeTask)
        XCTAssertTrue(task.isOverdue(at: start.addingTimeInterval(300)))
    }

    func testRestartRetainsGlobalPauseAndCannotResetAllowanceOrRepeatNotification() async throws {
        let store = makeStore()
        let service = try TaskService(store: store)
        let task = try await service.addTask(title: "A", dueAt: start)
        _ = try await service.pause(id: task.id, minutes: 2, at: start)
        let restarted = try TaskService(store: store)
        let during = try await restarted.evaluateFocus(at: start.addingTimeInterval(60))
        XCTAssertNil(during.activeTask)
        let resumed = try await restarted.evaluateFocus(at: start.addingTimeInterval(120))
        XCTAssertEqual(resumed.events, [.snoozeEnded, .activated(task, notify: false)])
        do {
            _ = try await restarted.pause(id: task.id, minutes: 3, at: start.addingTimeInterval(120))
            XCTFail("Restart must not reset pause allowance.")
        } catch { XCTAssertEqual(error as? TaskFocusError, .alreadySnoozed) }
    }

    func testReopeningInsideWindowActivatesButOutsideWindowIsOverdue() async throws {
        let service = try makeService()
        let task = try await service.addTask(title: "Reopen", dueAt: start)
        try await service.setCompleted(id: task.id, completed: true)
        let completed = try await service.evaluateFocus(at: start)
        XCTAssertNil(completed.activeTask)
        try await service.setCompleted(id: task.id, completed: false)
        let reopened = try await service.evaluateFocus(at: start.addingTimeInterval(60))
        XCTAssertEqual(reopened.activeTask?.id, task.id)
        try await service.setCompleted(id: task.id, completed: true)
        _ = try await service.evaluateFocus(at: start.addingTimeInterval(60))
        try await service.setCompleted(id: task.id, completed: false)
        let late = try await service.evaluateFocus(at: start.addingTimeInterval(1900))
        XCTAssertNil(late.activeTask)
    }

    func testDeferringActiveTaskHandsOffAndRetainsDurationAndPauseHistory() async throws {
        let service = try makeService()
        let first = try await service.addTask(title: "A", dueAt: start, duration: 600)
        let next = try await service.addTask(title: "B", dueAt: start.addingTimeInterval(30))
        _ = try await service.pause(id: first.id, minutes: 2, at: start)
        _ = try await service.evaluateFocus(at: start.addingTimeInterval(120))
        let deferredStart = start.addingTimeInterval(3600)
        try await service.deferTask(id: first.id, to: deferredStart, at: start.addingTimeInterval(120))
        let update = try await service.evaluateFocus(at: start.addingTimeInterval(120))
        XCTAssertEqual(update.activeTask?.id, next.id)
        let state = await service.snapshot()
        XCTAssertEqual(state.task(id: first.id)?.dueAt, deferredStart)
        XCTAssertEqual(state.task(id: first.id)?.duration, 600)
        XCTAssertTrue(state.userFocus.snoozedTaskIDs.contains(first.id))
        let later = try await service.evaluateFocus(at: deferredStart)
        XCTAssertEqual(later.activeTask?.id, first.id)
        XCTAssertEqual(later.events.last, .activated(try XCTUnwrap(state.task(id: first.id)), notify: true))
    }

    func testInvalidPauseAndDeferralLeaveStateUnchanged() async throws {
        let service = try makeService()
        let task = try await service.addTask(title: "Future", dueAt: start.addingTimeInterval(600))
        let before = await service.snapshot()
        for minutes in [0, 15, 2] {
            do { _ = try await service.pause(id: task.id, minutes: minutes, at: start); XCTFail("Invalid pause accepted.") }
            catch { }
        }
        do { try await service.deferTask(id: task.id, to: start, at: start); XCTFail("Past deferral accepted.") }
        catch { XCTAssertEqual(error as? TaskFocusError, .invalidDeferral) }
        let after = await service.snapshot()
        XCTAssertEqual(after, before)
    }

    func testExistingStoreWithoutUserModelLoadsWithNoPause() throws {
        let original = TaskState(tasks: [TodoTask(title: "Existing")])
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields.removeValue(forKey: "userFocus")
        let decoded = try JSONDecoder().decode(TaskState.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(decoded, original)
    }

    func testFailedSnoozePersistenceDoesNotConsumeAllowanceOrDeactivate() async throws {
        let store = makeStore()
        let service = try TaskService(store: store)
        let task = try await service.addTask(title: "A", dueAt: start)
        _ = try await service.evaluateFocus(at: start)
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
        do { _ = try await service.pause(id: task.id, minutes: 2, at: start); XCTFail("The write must fail.") }
        catch { }
        let after = try await service.evaluateFocus(at: start.addingTimeInterval(1))
        XCTAssertEqual(after.activeTask?.id, task.id)
        XCTAssertTrue(after.events.isEmpty)
        XCTAssertTrue(after.user.snoozedTaskIDs.isEmpty)
    }

    func testImportedRangedTaskUsesStartAndDurationAndDeferralMovesBothRemoteDates() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "ranged", projectId: "p", title: "Timed work",
                                       startDate: start, dueDate: start.addingTimeInterval(2700)))
        let service = try makeService(client: TickTickClient(token: "fake", transport: server))
        _ = try await service.sync()
        let state = await service.snapshot()
        let task = try XCTUnwrap(state.tasks.first)
        XCTAssertEqual(task.dueAt, start)
        XCTAssertEqual(task.effectiveDuration, 2700)
        let active = try await service.evaluateFocus(at: start.addingTimeInterval(2000))
        XCTAssertEqual(active.activeTask?.id, task.id)
        let newStart = start.addingTimeInterval(7200)
        try await service.deferTask(id: task.id, to: newStart, at: start)
        _ = try await service.sync()
        let remote = await server.allTasks()
        XCTAssertEqual(remote.first?.startDate, newStart)
        XCTAssertEqual(remote.first?.dueDate, newStart.addingTimeInterval(2700))
        let merged = await service.snapshot()
        XCTAssertEqual(merged.task(id: task.id)?.dueAt, newStart)
        XCTAssertEqual(merged.task(id: task.id)?.effectiveDuration, 2700)
        XCTAssertFalse(merged.isPending(task.id))
    }

    func testImportActivatesOnlyTasksStillInsideTheirWindow() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "old", projectId: "p", title: "Expired", dueDate: start.addingTimeInterval(-3600)))
        await server.seed(TickTickTask(id: "current", projectId: "p", title: "Current", dueDate: start.addingTimeInterval(-600)))
        let service = try makeService(client: TickTickClient(token: "fake", transport: server))
        _ = try await service.sync()
        let update = try await service.evaluateFocus(at: start)
        XCTAssertEqual(update.activeTask?.title, "Current")
    }

    private func makeService(client: TickTickClient? = nil) throws -> TaskService {
        try TaskService(store: makeStore(), client: client)
    }

    private func makeStore() -> JSONTaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-focus-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JSONTaskStore(url: directory.appendingPathComponent("tasks.json"))
    }
}
