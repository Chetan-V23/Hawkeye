import Foundation
import XCTest
@testable import HawkeyeCore

final class TaskSyncTests: XCTestCase {
    func testOfflineIntentSurvivesRestartAndRetriesWithStableID() async throws {
        let server = MockTickTickServer()
        let store = temporaryStore()
        let client = TickTickClient(token: "fake-token", transport: server)
        let service = try TaskService(store: store, client: client, projectID: "p")
        let task = try await service.addTask(title: "Offline", description: "Saved now", duration: 120)
        await server.failNext(2)
        let offlineReport = try await service.sync()
        XCTAssertFalse(offlineReport.warnings.isEmpty)
        let offline = await service.snapshot()
        let stableID = try XCTUnwrap(offline.task(id: task.id)?.remote?.taskID)
        XCTAssertTrue(offline.isPending(task.id))
        XCTAssertEqual(try store.load(), offline)

        let restarted = try TaskService(store: store, client: client, projectID: "p")
        _ = try await restarted.sync()
        let synced = await restarted.snapshot()
        let requests = await server.capturedRequests()
        let creates = requests.filter { $0.method == "POST" && $0.path == "/task" }
        XCTAssertEqual(creates.count, 1)
        XCTAssertEqual(synced.task(id: task.id)?.remote?.taskID, stableID)
        XCTAssertFalse(synced.isPending(task.id))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(creates.first?.body)) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, stableID)
        XCTAssertEqual(body["content"] as? String, "Saved now")
        XCTAssertNil(body["duration"])
        XCTAssertNil(body["snoozedUntil"])
        XCTAssertEqual(creates.first?.authorization, "Bearer fake-token")
    }

    func testAmbiguousCreateIsRecoveredWithoutDuplicateAfterRestart() async throws {
        let server = MockTickTickServer()
        let store = temporaryStore()
        let client = TickTickClient(token: "fake-token", transport: server)
        let service = try TaskService(store: store, client: client, projectID: "p")
        let task = try await service.addTask(title: "Only once")
        await server.timeOutAfterNextCreate()
        let first = try await service.sync()
        XCTAssertEqual(first.warnings.count, 1)
        let failed = await service.snapshot()
        XCTAssertTrue(failed.isPending(task.id))

        let restarted = try TaskService(store: store, client: client, projectID: "p")
        _ = try await restarted.sync()
        let requests = await server.capturedRequests()
        let allRemote = await server.allTasks()
        let result = await restarted.snapshot()
        XCTAssertEqual(requests.filter { $0.method == "POST" && $0.path == "/task" }.count, 1)
        XCTAssertEqual(allRemote.count, 1)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertFalse(result.isPending(task.id))
    }

    func testEditDuringCreateSurvivesResponseAndNextSyncUploadsLatest() async throws {
        let server = MockTickTickServer()
        let store = temporaryStore()
        let service = try TaskService(store: store, client: TickTickClient(token: "fake-token", transport: server), projectID: "p")
        let original = try await service.addTask(title: "Old title")
        await server.pauseNext(method: "POST", path: "/task")
        let sync = Task { try await service.sync() }
        await server.waitUntilPaused()
        var edited = original
        edited.title = "New title"
        try await service.updateTask(edited)
        await server.resume()
        _ = try await sync.value

        let intermediate = await service.snapshot()
        XCTAssertEqual(intermediate.task(id: original.id)?.title, "New title")
        XCTAssertTrue(intermediate.isPending(original.id))
        XCTAssertEqual(try store.load().task(id: original.id)?.title, "New title")
        _ = try await service.sync()
        let remote = await server.allTasks()
        let result = await service.snapshot()
        XCTAssertEqual(remote.count, 1)
        XCTAssertEqual(remote.first?.title, "New title")
        XCTAssertFalse(result.isPending(original.id))
    }

    func testOverlappingPollDoesNotMakeSecondNetworkRequest() async throws {
        let server = MockTickTickServer()
        let service = try TaskService(store: temporaryStore(), client: TickTickClient(token: "fake-token", transport: server))
        await server.pauseNext(method: "GET", path: "/project")
        let first = Task { try await service.sync() }
        await server.waitUntilPaused()
        let second = try await service.sync()
        XCTAssertTrue(second.skipped)
        let beforeRelease = await server.capturedRequests()
        XCTAssertEqual(beforeRelease.count, 1)
        await server.resume()
        _ = try await first.value
    }

    func testDisconnectDiscardsAnInFlightDownload() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Do not import"))
        let service = try TaskService(store: temporaryStore(), client: TickTickClient(token: "fake-token", transport: server))
        await server.pauseNext(method: "GET", path: "/project/p/data")
        let sync = Task { try await service.sync() }
        await server.waitUntilPaused()
        await service.configureSync(client: nil, projectID: nil)
        await server.resume()
        do { _ = try await sync.value; XCTFail("Disconnected generation should be cancelled") }
        catch is CancellationError { }
        let state = await service.snapshot()
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.lastSyncedAt)
        let report = try await service.sync()
        XCTAssertTrue(report.skipped)
    }

    func testKnownTaskCompletionIsFetchedWhenAbsentFromActiveProjectData() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Complete remotely"))
        let service = try TaskService(store: temporaryStore(), client: TickTickClient(token: "fake-token", transport: server))
        _ = try await service.sync()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Complete remotely", completedTime: date, status: 2))
        _ = try await service.sync()
        let state = await service.snapshot()

        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.tasks.first?.completedAt, date)
        XCTAssertTrue(try XCTUnwrap(state.tasks.first).completed)
    }

    func testDisappearanceAnd404NeverDeleteOrCompleteTask() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Keep locally"))
        let service = try TaskService(store: temporaryStore(), client: TickTickClient(token: "fake-token", transport: server))
        _ = try await service.sync()
        let before = await service.snapshot()
        await server.remove(projectID: "p", taskID: "remote")
        _ = try await service.sync()
        let after = await service.snapshot()

        XCTAssertEqual(after.tasks, before.tasks)
        XCTAssertFalse(try XCTUnwrap(after.tasks.first).completed)
    }

    func testRemoteMergePreservesLocalDurationAndSnooze() async throws {
        let server = MockTickTickServer()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Initial", dueDate: start))
        let service = try TaskService(store: temporaryStore(), client: TickTickClient(token: "fake-token", transport: server))
        _ = try await service.sync()
        let state = await service.snapshot()
        var task = try XCTUnwrap(state.tasks.first)
        task.duration = 1_200
        try await service.updateTask(task)
        let snooze = start.addingTimeInterval(120)
        _ = try await service.pause(id: task.id, minutes: 2, at: start)
        _ = try await service.sync()
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Remote title", content: "Remote notes"))
        _ = try await service.sync()
        let final = await service.snapshot()

        XCTAssertEqual(final.tasks.first?.title, "Remote title")
        XCTAssertEqual(final.tasks.first?.taskDescription, "Remote notes")
        XCTAssertEqual(final.tasks.first?.duration, 1_200)
        XCTAssertEqual(final.userFocus.snooze?.until, snooze)
    }

    func testStaleEditorPreservesLatestCompletionAndSnooze() async throws {
        let service = try TaskService(store: temporaryStore())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = try await service.addTask(title: "Original", dueAt: start)
        let snooze = start.addingTimeInterval(120)
        _ = try await service.pause(id: stale.id, minutes: 2, at: start)
        try await service.setCompleted(id: stale.id, completed: true)
        stale.title = "Edited later"
        try await service.updateTask(stale)
        let state = await service.snapshot()

        XCTAssertTrue(try XCTUnwrap(state.tasks.first).completed)
        XCTAssertEqual(state.userFocus.snooze?.until, snooze)
        XCTAssertEqual(state.tasks.first?.title, "Edited later")
    }

    func testLocalOnlyChangesDoNotQueueWritesOrOverwriteRemoteTitle() async throws {
        let server = MockTickTickServer()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Old title", dueDate: start))
        let service = try TaskService(store: temporaryStore(), client: TickTickClient(token: "fake-token", transport: server))
        _ = try await service.sync()
        let initial = await service.snapshot()
        var task = try XCTUnwrap(initial.tasks.first)
        task.duration = 600
        try await service.updateTask(task)
        let snooze = start.addingTimeInterval(120)
        _ = try await service.pause(id: task.id, minutes: 2, at: start)
        let local = await service.snapshot()
        XCTAssertFalse(local.isPending(task.id))
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "New remote title"))
        _ = try await service.sync()
        let result = await service.snapshot()
        let requests = await server.capturedRequests()

        XCTAssertEqual(result.tasks.first?.title, "New remote title")
        XCTAssertEqual(result.tasks.first?.duration, 600)
        XCTAssertEqual(result.userFocus.snooze?.until, snooze)
        XCTAssertFalse(requests.contains { $0.method == "POST" && !["/task/filter", "/task/completed"].contains($0.path) })
    }

    func testUpdatePreservesChecklistRepeatAndUnknownMetadata() async throws {
        let server = MockTickTickServer()
        let metadata: [String: JSONValue] = [
            "items": .array([.object(["id": .string("child"), "title": .string("Subtask"), "status": .integer(0)])]),
            "repeatFlag": .string("RRULE:FREQ=WEEKLY"),
            "sortOrder": .integer(9_007_199_254_740_993),
            "futureField": .object(["keep": .bool(true)])
        ]
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Initial", rawFields: metadata))
        let service = try TaskService(store: temporaryStore(), client: TickTickClient(token: "fake-token", transport: server))
        _ = try await service.sync()
        let state = await service.snapshot()
        var task = try XCTUnwrap(state.tasks.first)
        task.title = "Changed title"
        try await service.updateTask(task)
        _ = try await service.sync()
        let allTasks = await server.allTasks()
        let remote = try XCTUnwrap(allTasks.first)

        XCTAssertEqual(remote.title, "Changed title")
        for (key, value) in metadata { XCTAssertEqual(remote.rawFields[key], value, key) }
    }

    func testDownloadOnlyUntilUploadDestinationIsSelected() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Already remote"))
        let client = TickTickClient(token: "fake-token", transport: server)
        let service = try TaskService(store: temporaryStore(), client: client)
        let local = try await service.addTask(title: "Local until configured")
        _ = try await service.sync()
        let downloadOnly = await service.snapshot()
        XCTAssertEqual(downloadOnly.tasks.count, 2)
        XCTAssertNil(downloadOnly.task(id: local.id)?.remote)
        XCTAssertTrue(downloadOnly.isPending(local.id))
        let firstRequests = await server.capturedRequests()
        XCTAssertFalse(firstRequests.contains { $0.method == "POST" && !["/task/filter", "/task/completed"].contains($0.path) })

        await service.configureSync(client: client, projectID: "p")
        _ = try await service.sync()
        let synced = await service.snapshot()
        XCTAssertEqual(synced.tasks.count, 2)
        XCTAssertFalse(synced.isPending(local.id))
    }

    func testTaskMovedToAnotherProjectKeepsIdentityAndPendingEdit() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Initial title"))
        let service = try TaskService(store: temporaryStore(), client: TickTickClient(token: "fake-token", transport: server))
        _ = try await service.sync()
        let initial = await service.snapshot()
        var edited = try XCTUnwrap(initial.tasks.first)
        edited.title = "Local pending title"
        edited.duration = 300
        try await service.updateTask(edited)
        await server.remove(projectID: "p", taskID: "remote")
        await server.seed(TickTickTask(id: "remote", projectId: "q", title: "Moved remotely"))
        let moved = try await service.sync()
        XCTAssertEqual(moved.warnings.count, 1)
        let intermediate = await service.snapshot()
        XCTAssertEqual(intermediate.tasks.count, 1)
        XCTAssertEqual(intermediate.tasks.first?.id, edited.id)
        XCTAssertEqual(intermediate.tasks.first?.remote?.projectID, "q")
        XCTAssertEqual(intermediate.tasks.first?.title, "Local pending title")
        XCTAssertTrue(intermediate.isPending(edited.id))

        _ = try await service.sync()
        let final = await service.snapshot()
        let remote = await server.allTasks()
        XCTAssertEqual(final.tasks.count, 1)
        XCTAssertEqual(final.tasks.first?.duration, 300)
        XCTAssertFalse(final.isPending(edited.id))
        XCTAssertEqual(remote.first?.title, "Local pending title")
        XCTAssertEqual(remote.first?.projectId, "q")
    }

    private func temporaryStore() -> JSONTaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HawkeyeCoreTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JSONTaskStore(url: directory.appendingPathComponent("tasks.json"))
    }
}
