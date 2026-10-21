import XCTest
@testable import HawkeyeCore

final class StartNowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.75)

    func testStartsOverdueFutureAndUntimedTasksAtCurrentTimeWithTheirDuration() async throws {
        for start in [now.addingTimeInterval(-3600), now.addingTimeInterval(3600), nil] {
            let service = try makeService()
            let task = try await service.addTask(title: "Start me", dueAt: start, duration: 600)
            let update = try await service.startNow(id: task.id, at: now)
            XCTAssertEqual(update.activeTask?.id, task.id)
            XCTAssertEqual(update.activeTask?.dueAt, now)
            XCTAssertEqual(update.activeTask?.endsAt, now.addingTimeInterval(600))
            XCTAssertEqual(update.events, [.activated(try XCTUnwrap(update.activeTask), notify: true)])
            let state = await service.snapshot()
            XCTAssertEqual(state.task(id: task.id)?.dueAt, now)
            XCTAssertTrue(state.isPending(task.id))
        }
    }

    func testRejectsAnotherActiveTaskEvenIfFocusHasNotYetBeenEvaluated() async throws {
        let service = try makeService()
        _ = try await service.addTask(title: "Already due", dueAt: now.addingTimeInterval(-60))
        let next = try await service.addTask(title: "Start me", dueAt: now.addingTimeInterval(600))
        let before = await service.snapshot()
        do {
            _ = try await service.startNow(id: next.id, at: now)
            XCTFail("An active task must block manual start.")
        } catch { XCTAssertEqual(error as? TaskFocusError, .anotherTaskActive) }
        let after = await service.snapshot()
        XCTAssertEqual(after, before)
    }

    func testRejectsAlreadyActiveCompletedAndMissingTasksWithoutChangingState() async throws {
        let service = try makeService()
        let active = try await service.addTask(title: "Active", dueAt: now)
        let completed = try await service.addTask(title: "Completed")
        try await service.setCompleted(id: completed.id, completed: true)
        let before = await service.snapshot()
        do {
            _ = try await service.startNow(id: active.id, at: now)
            XCTFail("An active task must not be restarted.")
        } catch { XCTAssertEqual(error as? TaskFocusError, .taskAlreadyActive) }
        for id in [completed.id, UUID()] {
            do {
                _ = try await service.startNow(id: id, at: now)
                XCTFail("Only unfinished existing tasks can start.")
            } catch { XCTAssertEqual(error as? TaskValidationError, .taskNotFound) }
        }
        let after = await service.snapshot()
        XCTAssertEqual(after, before)
    }

    func testStartingDuringGlobalPauseSelectsChosenTaskAndRetainsUsedPauseAllowance() async throws {
        let service = try makeService()
        let earlier = try await service.addTask(title: "Earlier", dueAt: now.addingTimeInterval(-60))
        let chosen = try await service.addTask(title: "Chosen", dueAt: now.addingTimeInterval(-30))
        _ = try await service.pause(id: earlier.id, minutes: 2, at: now)
        let started = try await service.startNow(id: chosen.id, at: now.addingTimeInterval(10))
        XCTAssertEqual(started.activeTask?.id, chosen.id)
        XCTAssertNil(started.user.snooze)
        XCTAssertTrue(started.user.snoozedTaskIDs.contains(earlier.id))
        XCTAssertEqual(started.events.first, .snoozeEnded)
        let later = try await service.evaluateFocus(at: now.addingTimeInterval(11))
        XCTAssertEqual(later.activeTask?.id, chosen.id)
        XCTAssertTrue(later.events.isEmpty)
        _ = try await service.pause(id: chosen.id, minutes: 2, at: now.addingTimeInterval(11))
        let resumed = try await service.evaluateFocus(at: now.addingTimeInterval(131))
        XCTAssertEqual(resumed.activeTask?.id, chosen.id)
        XCTAssertTrue(resumed.user.snoozedTaskIDs.contains(chosen.id))
        try await service.setCompleted(id: chosen.id, completed: true)
        let handoff = try await service.evaluateFocus(at: now.addingTimeInterval(132))
        XCTAssertEqual(handoff.activeTask?.id, earlier.id)
        XCTAssertNil(handoff.user.manualStart)
    }

    func testStartingPreviouslyPausedTaskDoesNotResetItsPauseAllowance() async throws {
        let service = try makeService()
        let task = try await service.addTask(title: "Paused", dueAt: now.addingTimeInterval(-60))
        _ = try await service.pause(id: task.id, minutes: 2, at: now)
        let started = try await service.startNow(id: task.id, at: now.addingTimeInterval(10))
        XCTAssertEqual(started.activeTask?.id, task.id)
        XCTAssertTrue(started.user.snoozedTaskIDs.contains(task.id))
        do {
            _ = try await service.pause(id: task.id, minutes: 2, at: now.addingTimeInterval(11))
            XCTFail("Manual start must not reset pause allowance.")
        } catch { XCTAssertEqual(error as? TaskFocusError, .alreadySnoozed) }
    }

    func testManualSelectionSurvivesRestartAndClearsOnDeferral() async throws {
        let store = makeStore()
        let service = try TaskService(store: store)
        let earlier = try await service.addTask(title: "Earlier", dueAt: now.addingTimeInterval(-60))
        let chosen = try await service.addTask(title: "Chosen")
        _ = try await service.pause(id: earlier.id, minutes: 2, at: now)
        _ = try await service.startNow(id: chosen.id, at: now.addingTimeInterval(10))
        let restarted = try TaskService(store: store)
        let active = try await restarted.evaluateFocus(at: now.addingTimeInterval(11))
        XCTAssertEqual(active.activeTask?.id, chosen.id)
        XCTAssertEqual(active.events.last, .activated(try XCTUnwrap(active.activeTask), notify: false))
        try await restarted.deferTask(id: chosen.id, to: now.addingTimeInterval(3600), at: now.addingTimeInterval(12))
        let deferred = try await restarted.evaluateFocus(at: now.addingTimeInterval(12))
        XCTAssertEqual(deferred.activeTask?.id, earlier.id)
        XCTAssertNil(deferred.user.manualStart)
    }

    func testManualSelectionExpiresAndHandsOff() async throws {
        let service = try makeService()
        let earlier = try await service.addTask(title: "Earlier", dueAt: now.addingTimeInterval(-60))
        let chosen = try await service.addTask(title: "Chosen", duration: 30)
        _ = try await service.pause(id: earlier.id, minutes: 2, at: now)
        _ = try await service.startNow(id: chosen.id, at: now.addingTimeInterval(10))
        let expired = try await service.evaluateFocus(at: now.addingTimeInterval(40))
        XCTAssertEqual(expired.activeTask?.id, earlier.id)
        XCTAssertNil(expired.user.manualStart)
    }

    func testCompletionAndImmediateReopenCannotReviveManualPriority() async throws {
        let service = try makeService()
        let earlier = try await service.addTask(title: "Earlier", dueAt: now.addingTimeInterval(-60))
        let chosen = try await service.addTask(title: "Chosen")
        _ = try await service.pause(id: earlier.id, minutes: 2, at: now)
        _ = try await service.startNow(id: chosen.id, at: now.addingTimeInterval(10))
        try await service.setCompleted(id: chosen.id, completed: true)
        try await service.setCompleted(id: chosen.id, completed: false)
        let focus = try await service.evaluateFocus(at: now.addingTimeInterval(11))
        XCTAssertEqual(focus.activeTask?.id, earlier.id)
        XCTAssertNil(focus.user.manualStart)
    }

    func testRemoteRoundTripUpdatesStartAndPreservesSelectionDespiteAPIDatePrecision() async throws {
        let server = MockTickTickServer()
        let originalStart = now.addingTimeInterval(-3600)
        await server.seed(TickTickTask(id: "earlier", projectId: "p", title: "Earlier", dueDate: now.addingTimeInterval(-60)))
        await server.seed(TickTickTask(id: "chosen", projectId: "p", title: "Chosen", startDate: originalStart,
                                       dueDate: originalStart.addingTimeInterval(600)))
        let service = try makeService(client: TickTickClient(token: "fake", transport: server))
        _ = try await service.sync()
        let initial = await service.snapshot()
        let earlier = try XCTUnwrap(initial.tasks.first { $0.title == "Earlier" })
        let chosen = try XCTUnwrap(initial.tasks.first { $0.title == "Chosen" })
        _ = try await service.pause(id: earlier.id, minutes: 2, at: now)
        let started = try await service.startNow(id: chosen.id, at: now.addingTimeInterval(10))
        XCTAssertEqual(started.activeTask?.id, chosen.id)
        _ = try await service.sync()
        let remoteTasks = await server.allTasks()
        let remote = try XCTUnwrap(remoteTasks.first { $0.id == "chosen" })
        XCTAssertEqual(remote.startDate.map(TickTickDate.string), TickTickDate.string(now.addingTimeInterval(10)))
        XCTAssertEqual(remote.scheduledDuration, 600)
        let after = await service.snapshot()
        XCTAssertEqual(after.task(id: chosen.id)?.dueAt, now.addingTimeInterval(10))
        XCTAssertFalse(after.isPending(chosen.id))
        let focus = try await service.evaluateFocus(at: now.addingTimeInterval(11))
        XCTAssertEqual(focus.activeTask?.id, chosen.id)
        XCTAssertTrue(focus.events.isEmpty)
    }

    func testFailedPersistenceDoesNotChangeTaskSnoozeOrFocus() async throws {
        let store = makeStore()
        let service = try TaskService(store: store)
        let task = try await service.addTask(title: "Start me", dueAt: now.addingTimeInterval(-3600))
        let before = await service.snapshot()
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
        do {
            _ = try await service.startNow(id: task.id, at: now)
            XCTFail("The failed write must be reported.")
        } catch { }
        let after = await service.snapshot()
        XCTAssertEqual(after, before)
        let focus = try await service.evaluateFocus(at: now)
        XCTAssertNil(focus.activeTask)
        XCTAssertTrue(focus.events.isEmpty)
    }

    func testOldUserFocusWithoutManualSelectionStillDecodes() throws {
        let data = try JSONEncoder().encode(UserFocusState(snoozedTaskIDs: [UUID()]))
        let restored = try JSONDecoder().decode(UserFocusState.self, from: data)
        XCTAssertNil(restored.manualStart)
        XCTAssertEqual(restored.snoozedTaskIDs.count, 1)
    }

    private func makeService(client: TickTickClient? = nil) throws -> TaskService {
        try TaskService(store: makeStore(), client: client)
    }

    private func makeStore() -> JSONTaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-start-now-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JSONTaskStore(url: directory.appendingPathComponent("tasks.json"))
    }
}
