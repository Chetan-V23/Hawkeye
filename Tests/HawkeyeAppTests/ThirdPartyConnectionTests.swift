import XCTest
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class ThirdPartyConnectionTests: XCTestCase {
    func testLegacyDestinationMigratesToOneTaggedConnection() throws {
        let preferences = try preferences()
        preferences.set("legacy-list", forKey: "ticktick.projectID")
        preferences.set("Personal", forKey: "ticktick.projectName")
        let connection = try XCTUnwrap(TaskConnection.load(from: preferences))
        XCTAssertEqual(connection.provider, .ticktick)
        XCTAssertEqual(connection.destinationID, "legacy-list")
        XCTAssertEqual(connection.destinationName, "Personal")
        XCTAssertNotNil(preferences.data(forKey: TaskConnection.preferenceKey))
        XCTAssertNil(preferences.object(forKey: "ticktick.projectID"))
        XCTAssertNil(preferences.object(forKey: "ticktick.projectName"))
        XCTAssertEqual(TaskConnection.load(from: preferences), connection)
    }

    func testCheckingAnotherAppKeepsTheActiveConnectionAndEveryTask() async throws {
        let fixture = try fixture()
        let before = await fixture.service.snapshot()
        let catalog = try await fixture.model.discover(provider: .todoist, token: "new-todoist-token")
        XCTAssertEqual(catalog.destinations.map(\.id), ["todoist-project"])
        XCTAssertEqual(fixture.model.providerID, .ticktick)
        XCTAssertEqual(fixture.model.projectID, "original")
        XCTAssertEqual(try fixture.tokens.read(), "old-ticktick-token")
        XCTAssertNil(try fixture.tokens.scoped(to: .todoist).read())
        let after = await fixture.service.snapshot()
        XCTAssertEqual(before, after)
    }

    func testValidatedAppSwitchKeepsTaskDetailsAndFocusAndRemovesOnlyPreviousCredential() async throws {
        let fixture = try fixture()
        let before = await fixture.service.snapshot()
        try fixture.tokens.scoped(to: .notion).save("unrelated-notion-token")
        try await fixture.model.connect(provider: .todoist, token: "new-todoist-token",
                                        destination: TaskDestination(id: "todoist-project", name: "Todoist tasks"))
        let after = await fixture.service.snapshot()
        XCTAssertEqual(Set(before.tasks.map(\.id)), Set(after.tasks.map(\.id)))
        for task in before.tasks {
            let retained = try XCTUnwrap(after.task(id: task.id))
            XCTAssertEqual(retained.title, task.title)
            XCTAssertEqual(retained.taskDescription, task.taskDescription)
            XCTAssertEqual(retained.createdAt, task.createdAt)
            XCTAssertEqual(retained.dueAt, task.dueAt)
            XCTAssertEqual(retained.completedAt, task.completedAt)
            XCTAssertEqual(retained.duration, task.duration ?? task.remoteDuration)
            XCTAssertEqual(retained.effectiveDuration, task.effectiveDuration)
            XCTAssertNil(retained.remote)
        }
        XCTAssertEqual(after.userFocus, before.userFocus)
        XCTAssertNil(after.lastSyncedAt)
        XCTAssertEqual(fixture.model.providerID, .todoist)
        XCTAssertEqual(TaskConnection.load(from: fixture.preferences)?.provider, .todoist)
        XCTAssertNil(try fixture.tokens.read())
        XCTAssertEqual(try fixture.tokens.scoped(to: .todoist).read(), "new-todoist-token")
        XCTAssertEqual(try fixture.tokens.scoped(to: .notion).read(), "unrelated-notion-token")
        let requests = await fixture.server.requests()
        XCTAssertTrue(requests.filter { $0.host == "api.todoist.com" }.allSatisfy { $0.authorization == "Bearer new-todoist-token" })
        XCTAssertFalse(requests.contains { $0.method == "DELETE" })
    }

    func testFailedValidationKeepsPreviousConnectionCredentialsAndSyncState() async throws {
        let fixture = try fixture()
        let before = await fixture.service.snapshot()
        await fixture.server.rejectTodoistProjects()
        do {
            try await fixture.model.connect(provider: .todoist, token: "invalid-token",
                                            destination: TaskDestination(id: "todoist-project", name: "Todoist tasks"))
            XCTFail("A rejected token must not replace the saved connection.")
        } catch {}
        XCTAssertEqual(fixture.model.providerID, .ticktick)
        XCTAssertTrue(fixture.model.connected)
        XCTAssertEqual(try fixture.tokens.read(), "old-ticktick-token")
        XCTAssertNil(try fixture.tokens.scoped(to: .todoist).read())
        let after = await fixture.service.snapshot()
        XCTAssertEqual(after, before)
    }

    func testInvalidDestinationCannotDetachTasksOrSaveCredential() async throws {
        let fixture = try fixture()
        let before = await fixture.service.snapshot()
        do {
            try await fixture.model.connect(provider: .todoist, token: "new-todoist-token",
                                            destination: TaskDestination(id: "deleted-project", name: "Gone"))
            XCTFail("The destination must be revalidated on Save.")
        } catch {}
        let after = await fixture.service.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(fixture.model.providerID, .ticktick)
        XCTAssertNil(try fixture.tokens.scoped(to: .todoist).read())
    }

    func testFailedNewCredentialSaveKeepsOldConnectionAndTasks() async throws {
        let fixture = try fixture()
        let before = await fixture.service.snapshot()
        let newURL = try XCTUnwrap(fixture.tokens.scoped(to: .todoist).fileURL)
        try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
        do {
            try await fixture.model.connect(provider: .todoist, token: "new-todoist-token",
                                            destination: TaskDestination(id: "todoist-project", name: "Todoist tasks"))
            XCTFail("A credential failure must leave the previous connection usable.")
        } catch {}
        XCTAssertTrue(fixture.model.connected)
        XCTAssertEqual(fixture.model.providerID, .ticktick)
        XCTAssertEqual(try fixture.tokens.read(), "old-ticktick-token")
        let after = await fixture.service.snapshot()
        XCTAssertEqual(after, before)
    }

    func testCancelledOldSyncCannotImportTasksAfterValidatedSwitch() async throws {
        let fixture = try fixture()
        await fixture.server.holdOldPull()
        let oldSync = fixture.model.syncNow()
        await fixture.server.waitForOldPull()
        XCTAssertTrue(fixture.model.syncing)
        try await fixture.model.connect(provider: .todoist, token: "new-todoist-token",
                                        destination: TaskDestination(id: "todoist-project", name: "Todoist tasks"))
        await fixture.server.releaseOldPull()
        await oldSync?.value
        let snapshot = await fixture.service.snapshot()
        XCTAssertFalse(snapshot.tasks.contains { $0.title == "Late task from TickTick" })
        XCTAssertEqual(fixture.model.providerID, .todoist)
        XCTAssertFalse(fixture.model.syncStatus.contains("TickTick"))
        XCTAssertTrue(snapshot.tasks.allSatisfy { $0.remote?.provider != .ticktick })
    }

    func testDisconnectRetainsImportedAndLocalTasksAndClearsRemoteState() async throws {
        let fixture = try fixture()
        let before = await fixture.service.snapshot()
        try await fixture.model.disconnect()
        let after = await fixture.service.snapshot()
        XCTAssertEqual(Set(after.tasks.map(\.id)), Set(before.tasks.map(\.id)))
        XCTAssertTrue(after.tasks.allSatisfy { $0.remote == nil })
        XCTAssertEqual(after.userFocus, before.userFocus)
        XCTAssertFalse(fixture.model.connected)
        XCTAssertNil(TaskConnection.load(from: fixture.preferences))
        XCTAssertNil(try fixture.tokens.read())
        let requests = await fixture.server.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testStorageFailureDuringSwitchRestoresCredentialsAndConnection() async throws {
        let fixture = try fixture()
        let before = await fixture.service.snapshot()
        let tasksURL = try XCTUnwrap(fixture.tokens.fileURL).deletingLastPathComponent().appendingPathComponent("tasks.json")
        try FileManager.default.removeItem(at: tasksURL)
        try FileManager.default.createDirectory(at: tasksURL, withIntermediateDirectories: false)
        do {
            try await fixture.model.connect(provider: .todoist, token: "new-todoist-token",
                                            destination: TaskDestination(id: "todoist-project", name: "Todoist tasks"))
            XCTFail("A failed task-store write must not finalize a connection switch.")
        } catch {}
        XCTAssertEqual(try fixture.tokens.read(), "old-ticktick-token")
        XCTAssertNil(try fixture.tokens.scoped(to: .todoist).read())
        XCTAssertTrue(fixture.model.connected)
        XCTAssertEqual(fixture.model.providerID, .ticktick)
        let after = await fixture.service.snapshot()
        XCTAssertEqual(after, before)
        let projects = try await fixture.model.availableProjects()
        XCTAssertEqual(projects.map(\.id), ["original"])
    }

    func testNotionMappingMustValidateBeforeOldConnectionIsDiscarded() async throws {
        let fixture = try fixture()
        let before = await fixture.service.snapshot()
        let mapping = NotionTaskMapping(titlePropertyID: "title", statusPropertyID: "status", statusType: "status",
                                        openStatus: "Open", completedStatus: "Open", duePropertyID: "due")
        do {
            try await fixture.model.connect(provider: .notion, token: "new-notion-token",
                                            destination: TaskDestination(id: "notion-tasks", name: "Tasks"), notionMapping: mapping)
            XCTFail("Open and completed status must be distinct.")
        } catch {}
        let after = await fixture.service.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(fixture.model.providerID, .ticktick)
        XCTAssertEqual(try fixture.tokens.read(), "old-ticktick-token")
        XCTAssertNil(try fixture.tokens.scoped(to: .notion).read())
    }

    func testNotionMappingAndProviderPersistTogether() throws {
        let preferences = try preferences()
        let mapping = NotionTaskMapping(titlePropertyID: "title", statusPropertyID: "status", statusType: "select",
                                        openStatus: "To do", completedStatus: "Done", duePropertyID: "due",
                                        descriptionPropertyID: "description")
        let connection = TaskConnection(provider: .notion, destinationID: "notion-tasks", destinationName: "Tasks", notionMapping: mapping)
        connection.save(to: preferences)
        XCTAssertEqual(TaskConnection.load(from: preferences), connection)
    }

    func testTokenRotationInSameAppPreservesRemoteLinksAndPendingEdits() async throws {
        let fixture = try fixture(pendingEdit: true)
        let before = await fixture.service.snapshot()
        let imported = try XCTUnwrap(before.tasks.first { $0.remote?.taskID == "imported" })
        try await fixture.model.connect(provider: .ticktick, token: "replacement-ticktick-token",
                                        destination: TaskDestination(id: "original", name: "Original"))
        let after = await fixture.service.snapshot()
        XCTAssertEqual(after.task(id: imported.id)?.remote, imported.remote)
        XCTAssertEqual(after.task(id: imported.id)?.title, imported.title)
        XCTAssertEqual(after.outbox.first { $0.taskID == imported.id }?.kind, .update)
        XCTAssertEqual(Set(after.tasks.map(\.id)), Set(before.tasks.map(\.id)))
        XCTAssertEqual(try fixture.tokens.read(), "replacement-ticktick-token")
    }

    private func preferences() throws -> UserDefaults {
        let suite = "hawkeye-third-party-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        return preferences
    }

    private func fixture(pendingEdit: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-provider-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let tokens = TokenStore.file(directory.appendingPathComponent("legacy-token.txt"))
        try tokens.save("old-ticktick-token")
        let preferences = try preferences()
        let imported = TodoTask(title: "Imported work", taskDescription: "Keep this description",
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                dueAt: Date(timeIntervalSince1970: 1_700_001_000), duration: 1800,
                                remote: RemoteTaskIdentity(taskID: "imported", projectID: "original"), syncState: .synced)
        let completed = TodoTask(title: "Completed import", duration: nil,
                                completedAt: Date(timeIntervalSince1970: 1_700_002_000), remoteDuration: 2400,
                                remote: RemoteTaskIdentity(taskID: "done", projectID: "original"), syncState: .synced)
        let local = TodoTask(title: "Local task", duration: 900)
        let focus = UserFocusState(snoozedTaskIDs: [imported.id], announcedStarts: [imported.id: imported.dueAt!])
        let store = JSONTaskStore(url: directory.appendingPathComponent("tasks.json"))
        var state = TaskState(tasks: [imported, completed, local], lastSyncedAt: Date(timeIntervalSince1970: 1_700_003_000), userFocus: focus)
        if pendingEdit {
            var edited = imported
            edited.title = "Pending edited title"
            try state.update(edited)
        }
        try store.save(state)
        let server = ProviderConnectionServer()
        let client = TickTickClient(token: "old-ticktick-token", transport: server)
        let service = try TaskService(store: store, client: client, projectID: "original")
        let model = AppModel(service: service, client: client, project: ProjectOption(id: "original", name: "Original"),
                             preferences: preferences, tokenStore: tokens, transport: server)
        return Fixture(model: model, service: service, tokens: tokens, preferences: preferences, server: server)
    }

    private struct Fixture {
        let model: AppModel
        let service: TaskService
        let tokens: TokenStore
        let preferences: UserDefaults
        let server: ProviderConnectionServer
    }
}

private actor ProviderConnectionServer: HTTPTransport {
    struct Request: Sendable {
        let host: String
        let method: String
        let authorization: String?
    }
    private var captured: [Request] = []
    private var rejectProjects = false
    private var holdPull = false
    private var pullStarted = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var pullWaiter: CheckedContinuation<Void, Never>?

    func requests() -> [Request] { captured }
    func rejectTodoistProjects() { rejectProjects = true }
    func holdOldPull() { holdPull = true }
    func waitForOldPull() async {
        if !pullStarted { await withCheckedContinuation { startedWaiter = $0 } }
    }
    func releaseOldPull() { pullWaiter?.resume(); pullWaiter = nil }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        captured.append(Request(host: url.host!, method: request.httpMethod ?? "GET",
                                authorization: request.value(forHTTPHeaderField: "Authorization")))
        var status = 200
        var json = "{}"
        if url.host == "api.todoist.com", url.path.hasSuffix("/projects") {
            status = rejectProjects ? 401 : 200
            json = "{\"results\":[{\"id\":\"todoist-project\",\"name\":\"Todoist tasks\"}],\"next_cursor\":null}"
        } else if url.host == "api.todoist.com" {
            status = 503
        } else if url.host == "api.notion.com", url.path.hasSuffix("/search") {
            json = """
            {"results":[{"id":"notion-tasks","title":[{"plain_text":"Tasks"}],"properties":{
              "Name":{"id":"title","name":"Name","type":"title","title":{}},
              "Status":{"id":"status","name":"Status","type":"status","status":{"options":[{"name":"Open"},{"name":"Done"}]}},
              "Due":{"id":"due","name":"Due","type":"date","date":{}}
            }}],"has_more":false,"next_cursor":null}
            """
        } else if url.path.hasSuffix("/project") {
            json = "[{\"id\":\"original\",\"name\":\"Original\"}]"
        } else if url.path.hasSuffix("/data") {
            if holdPull {
                pullStarted = true
                startedWaiter?.resume()
                startedWaiter = nil
                await withCheckedContinuation { pullWaiter = $0 }
            }
            json = "{\"tasks\":[{\"id\":\"late\",\"projectId\":\"original\",\"title\":\"Late task from TickTick\",\"status\":0}]}"
        } else {
            json = "[]"
        }
        return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
