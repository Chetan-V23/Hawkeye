import Foundation
import XCTest
@testable import HawkeyeCore

final class TaskSyncCoverageTests: XCTestCase {
    func testInboxImportsWithoutBeingInProjectEnumeration() async throws {
        let server = MockTickTickServer()
        await server.setProjects([])
        await server.setInboxProjectID("account-inbox")
        await server.seed(TickTickTask(id: "inbox-task", projectId: "account-inbox", title: "Inbox task"))
        let service = try makeService(server: server)

        let report = try await service.sync()
        let state = await service.snapshot()
        let requests = await server.capturedRequests()
        let filterRequest = try XCTUnwrap(requests.first { $0.path == "/task/filter" })
        let filter = try requestBody(filterRequest)

        XCTAssertEqual(state.tasks.map(\.title), ["Inbox task"])
        XCTAssertEqual(state.tasks.first?.remote?.projectID, "account-inbox")
        XCTAssertEqual(filterRequest.method, "POST")
        XCTAssertEqual(filter["projectIds"], .array([.string("inbox")]))
        XCTAssertEqual(filter["status"], .array([.integer(0)]))
        XCTAssertEqual(report.pulled, 1)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testInitialHistoryImportsLastThirtyDaysAcrossUnlistedProjects() async throws {
        let server = MockTickTickServer()
        await server.setProjects([])
        let now = Date()
        await server.seed(TickTickTask(id: "recent", projectId: "unlisted", title: "Recent completion", completedTime: now.addingTimeInterval(-10 * 24 * 60 * 60), status: 2))
        await server.seed(TickTickTask(id: "old", projectId: "unlisted", title: "Old completion", completedTime: now.addingTimeInterval(-31 * 24 * 60 * 60), status: 2))
        let service = try makeService(server: server)

        _ = try await service.sync()
        let state = await service.snapshot()
        let requests = await server.capturedRequests()
        let history = try requestBody(XCTUnwrap(requests.first { $0.path == "/task/completed" }))
        let start = try XCTUnwrap(history["startDate"]?.string.flatMap(TickTickDate.date))
        let end = try XCTUnwrap(history["endDate"]?.string.flatMap(TickTickDate.date))

        XCTAssertEqual(state.tasks.map(\.title), ["Recent completion"])
        XCTAssertTrue(try XCTUnwrap(state.tasks.first).completed)
        XCTAssertNil(history["projectIds"])
        XCTAssertEqual(end.timeIntervalSince(start), 30 * 24 * 60 * 60, accuracy: 1)
        XCTAssertEqual(end.timeIntervalSince(now), 0, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(state.lastSyncedAt).timeIntervalSince(end), 0, accuracy: 1)
    }

    func testIncrementalHistoryOverlapsPreviousCursorBySixtySeconds() async throws {
        let server = MockTickTickServer()
        await server.setProjects([])
        let cursor = Date().addingTimeInterval(-7_200)
        await server.seed(TickTickTask(id: "overlap", projectId: "p", title: "At overlap", completedTime: cursor.addingTimeInterval(-30), status: 2))
        await server.seed(TickTickTask(id: "too-old", projectId: "p", title: "Before overlap", completedTime: cursor.addingTimeInterval(-120), status: 2))
        let store = temporaryStore()
        try store.save(TaskState(lastSyncedAt: cursor))
        let service = try makeService(server: server, store: store)

        _ = try await service.sync()
        let state = await service.snapshot()
        let requests = await server.capturedRequests()
        let history = try requestBody(XCTUnwrap(requests.first { $0.path == "/task/completed" }))
        let start = try XCTUnwrap(history["startDate"]?.string.flatMap(TickTickDate.date))

        XCTAssertEqual(state.tasks.map(\.title), ["At overlap"])
        XCTAssertEqual(start.timeIntervalSince(cursor), -60, accuracy: 1)
    }

    func testInboxAndCompletedHistoryCapsAreVisible() async throws {
        let server = MockTickTickServer()
        await server.setProjects([])
        for index in 0..<201 {
            await server.seed(TickTickTask(id: "inbox-\(index)", projectId: "inbox", title: "Inbox \(index)"))
            await server.seed(TickTickTask(id: "completed-\(index)", projectId: "unlisted", title: "Done \(index)", completedTime: Date().addingTimeInterval(-60), status: 2))
        }
        let service = try makeService(server: server)

        let report = try await service.sync()
        let state = await service.snapshot()

        XCTAssertEqual(report.pulled, 400)
        XCTAssertEqual(state.tasks.count, 400)
        XCTAssertTrue(report.warnings.contains { $0.contains("200-task Inbox limit") })
        XCTAssertTrue(report.warnings.contains { $0.contains("200-task completed-history limit") })
    }

    func testFailedProjectSubsetsDoNotDiscardGoodListsInboxOrHistory() async throws {
        let server = MockTickTickServer()
        await server.setProjects([
            TickTickProject(id: "denied", name: "Denied"),
            TickTickProject(id: "gone", name: "Gone"),
            TickTickProject(id: "broken", name: "Broken"),
            TickTickProject(id: "good", name: "Good")
        ])
        for (id, status) in [("denied", 403), ("gone", 404), ("broken", 503)] {
            await server.setStatus(status, method: "GET", path: "/project/\(id)/data")
        }
        await server.seed(TickTickTask(id: "good", projectId: "good", title: "Good list task"))
        await server.seed(TickTickTask(id: "inbox", projectId: "inbox", title: "Inbox task"))
        await server.seed(TickTickTask(id: "done", projectId: "unlisted", title: "Done task", completedTime: Date().addingTimeInterval(-60), status: 2))
        let store = temporaryStore()
        let known = TodoTask(title: "Known task", remote: RemoteTaskIdentity(taskID: "known", projectID: "denied"), syncState: .synced)
        try store.save(TaskState(tasks: [known]))
        await server.setStatus(503, method: "GET", path: "/project/denied/task/known")
        let service = try makeService(server: server, store: store)

        let report = try await service.sync()
        let state = await service.snapshot()

        XCTAssertEqual(Set(state.tasks.map(\.title)), ["Good list task", "Inbox task", "Done task", "Known task"])
        XCTAssertEqual(report.pulled, 3)
        XCTAssertEqual(report.warnings.count, 4)
        XCTAssertEqual(try store.load(), state)
    }

    func testFailedInboxAndHistoryKeepSuccessfulPullAndHistoryCursorForRetry() async throws {
        let server = MockTickTickServer()
        let store = temporaryStore()
        let cursor = Date().addingTimeInterval(-7_200)
        try store.save(TaskState(lastSyncedAt: cursor))
        await server.seed(TickTickTask(id: "good", projectId: "p", title: "Good list task"))
        await server.seed(TickTickTask(id: "inbox", projectId: "inbox", title: "Inbox task"))
        await server.seed(TickTickTask(id: "done", projectId: "p", title: "Done task", completedTime: cursor.addingTimeInterval(60), status: 2))
        await server.setStatus(403, method: "POST", path: "/task/filter")
        await server.setStatus(500, method: "POST", path: "/task/completed")
        let service = try makeService(server: server, store: store)

        let first = try await service.sync()
        let partial = await service.snapshot()
        XCTAssertEqual(partial.tasks.map(\.title), ["Good list task"])
        XCTAssertEqual(partial.lastSyncedAt, cursor)
        XCTAssertEqual(first.warnings.count, 2)

        await server.setStatus(nil, method: "POST", path: "/task/filter")
        await server.setStatus(nil, method: "POST", path: "/task/completed")
        _ = try await service.sync()
        let retried = await service.snapshot()
        XCTAssertEqual(Set(retried.tasks.map(\.title)), ["Good list task", "Inbox task", "Done task"])
        XCTAssertGreaterThan(try XCTUnwrap(retried.lastSyncedAt), cursor)
    }

    func testProjectEnumerationFailureStillImportsInboxAndHistory() async throws {
        let server = MockTickTickServer()
        await server.setStatus(503, method: "GET", path: "/project")
        await server.seed(TickTickTask(id: "inbox", projectId: "inbox", title: "Inbox task"))
        await server.seed(TickTickTask(id: "done", projectId: "p", title: "Done task", completedTime: Date().addingTimeInterval(-60), status: 2))
        let service = try makeService(server: server)

        let report = try await service.sync()
        let state = await service.snapshot()

        XCTAssertEqual(Set(state.tasks.map(\.title)), ["Inbox task", "Done task"])
        XCTAssertEqual(report.warnings.count, 1)
    }

    func testUnauthorizedProjectAbortsSyncWithoutAcknowledgingDownload() async throws {
        let server = MockTickTickServer()
        await server.setProjects([TickTickProject(id: "good", name: "Good"), TickTickProject(id: "denied", name: "Denied")])
        await server.seed(TickTickTask(id: "good", projectId: "good", title: "Good list task"))
        await server.setStatus(401, method: "GET", path: "/project/denied/data")
        let service = try makeService(server: server)

        do {
            _ = try await service.sync()
            XCTFail("Unauthorized responses must abort sync")
        } catch let error as TickTickError {
            XCTAssertEqual(error, .httpStatus(401))
        }
        let state = await service.snapshot()
        let requests = await server.capturedRequests()
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.lastSyncedAt)
        XCTAssertFalse(requests.contains { $0.path == "/task/filter" })
    }

    func testClosedAndNoteProjectsAreSkippedForActivePulls() async throws {
        let server = MockTickTickServer()
        await server.setProjects([
            TickTickProject(id: "closed", name: "Closed", closed: true),
            TickTickProject(id: "notes", name: "Notes", kind: "NOTE"),
            TickTickProject(id: "p", name: "Open", kind: "TASK")
        ])
        await server.seed(TickTickTask(id: "active", projectId: "p", title: "Active task"))
        let service = try makeService(server: server)

        _ = try await service.sync()
        let requests = await server.capturedRequests()
        XCTAssertFalse(requests.contains { $0.path == "/project/closed/data" || $0.path == "/project/notes/data" })
        XCTAssertTrue(requests.contains { $0.path == "/project/p/data" })
    }

    func testObservedMovedTaskIsNotOverwrittenByOldProjectLookup() async throws {
        let server = MockTickTickServer()
        await server.setProjects([TickTickProject(id: "q", name: "New project")])
        await server.seed(TickTickTask(id: "moved", projectId: "q", title: "Current title"))
        await server.seed(TickTickTask(id: "moved", projectId: "p", title: "Old archived copy", completedTime: Date(timeIntervalSince1970: 1_700_000_000), status: 2))
        let store = temporaryStore()
        let known = TodoTask(title: "Previous title", remote: RemoteTaskIdentity(taskID: "moved", projectID: "p"), syncState: .synced)
        try store.save(TaskState(tasks: [known]))
        let service = try makeService(server: server, store: store)

        _ = try await service.sync()
        let state = await service.snapshot()
        let requests = await server.capturedRequests()

        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.tasks.first?.id, known.id)
        XCTAssertEqual(state.tasks.first?.title, "Current title")
        XCTAssertEqual(state.tasks.first?.remote?.projectID, "q")
        XCTAssertFalse(try XCTUnwrap(state.tasks.first).completed)
        XCTAssertFalse(requests.contains { $0.path == "/project/p/task/moved" })
    }

    func testCompletionUsesDedicatedEndpointAfterOpenStatusUpdate() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Complete me"))
        let service = try makeService(server: server)
        _ = try await service.sync()
        let initial = await service.snapshot()
        let task = try XCTUnwrap(initial.tasks.first)
        try await service.setCompleted(id: task.id, completed: true)

        let report = try await service.sync()
        let requests = await server.capturedRequests()
        let update = try requestBody(XCTUnwrap(requests.first { $0.path == "/task/remote" }))
        let result = await service.snapshot()
        let remote = await server.allTasks()

        XCTAssertEqual(update["status"], .integer(0))
        XCTAssertEqual(requests.filter { $0.path == "/project/p/task/remote/complete" }.count, 1)
        XCTAssertEqual(remote.first?.status, 2)
        XCTAssertFalse(result.isPending(task.id))
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testCompletedLocalCreateUsesDedicatedEndpointAfterOpenStatusCreate() async throws {
        let server = MockTickTickServer()
        let service = try makeService(server: server, projectID: "p")
        let task = try await service.addTask(title: "Already done locally")
        try await service.setCompleted(id: task.id, completed: true)

        let report = try await service.sync()
        let requests = await server.capturedRequests()
        let create = try requestBody(XCTUnwrap(requests.first { $0.path == "/task" && $0.method == "POST" }))
        let result = await service.snapshot()
        let remote = await server.allTasks()

        XCTAssertEqual(create["status"], .integer(0))
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/complete") }.count, 1)
        XCTAssertEqual(remote.first?.status, 2)
        XCTAssertFalse(result.isPending(task.id))
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testAlreadyCompletedRemoteTaskDoesNotReceiveDuplicateCompletion() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Complete me"))
        let service = try makeService(server: server)
        _ = try await service.sync()
        let initial = await service.snapshot()
        let task = try XCTUnwrap(initial.tasks.first)
        try await service.setCompleted(id: task.id, completed: true)
        let completedAt = Date().addingTimeInterval(-60)
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Completed elsewhere", completedTime: completedAt, status: 2))

        let report = try await service.sync()
        let result = await service.snapshot()
        let requests = await server.capturedRequests()
        let update = try requestBody(XCTUnwrap(requests.first { $0.path == "/task/remote" }))

        XCTAssertEqual(update["status"], .integer(2))
        XCTAssertNotEqual(update["completedTime"], .null)
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/complete") })
        XCTAssertFalse(result.isPending(task.id))
        XCTAssertEqual(try XCTUnwrap(result.tasks.first?.completedAt).timeIntervalSince(completedAt), 0, accuracy: 1)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testReopeningUsesStatusZeroUpdateWithoutCallingComplete() async throws {
        let server = MockTickTickServer()
        await server.seed(TickTickTask(id: "remote", projectId: "p", title: "Done task", completedTime: Date().addingTimeInterval(-60), status: 2))
        let service = try makeService(server: server)
        _ = try await service.sync()
        let initial = await service.snapshot()
        let task = try XCTUnwrap(initial.tasks.first)
        try await service.setCompleted(id: task.id, completed: false)

        _ = try await service.sync()
        let result = await service.snapshot()
        let requests = await server.capturedRequests()
        let update = try requestBody(XCTUnwrap(requests.first { $0.path == "/task/remote" }))

        XCTAssertEqual(update["status"], .integer(0))
        XCTAssertEqual(update["completedTime"], .null)
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/complete") })
        XCTAssertFalse(try XCTUnwrap(result.tasks.first).completed)
        XCTAssertFalse(result.isPending(task.id))
    }

    private func requestBody(_ request: MockTickTickServer.Request) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(request.body))
    }

    private func makeService(server: MockTickTickServer, store: JSONTaskStore? = nil, projectID: String? = nil) throws -> TaskService {
        try TaskService(store: store ?? temporaryStore(), client: TickTickClient(token: "fake-token", transport: server), projectID: projectID)
    }

    private func temporaryStore() -> JSONTaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HawkeyeCoreTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JSONTaskStore(url: directory.appendingPathComponent("tasks.json"))
    }
}
