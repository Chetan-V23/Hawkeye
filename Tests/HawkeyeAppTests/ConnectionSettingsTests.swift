import XCTest
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class ConnectionSettingsTests: XCTestCase {
    func testListsLoadUsingSavedConnectionWithoutEnteringToken() async throws {
        let fixture = try makeFixture()
        let projects = try await fixture.model.availableProjects()
        XCTAssertEqual(projects.map(\.id), ["original", "destination"])
        let requests = await fixture.server.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.authorization, "Bearer saved-test-token")
        XCTAssertEqual(requests.first?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(fixture.model.projectID, "original")
    }

    func testRefreshingListsDiscoversListsCreatedSincePreviousOpening() async throws {
        let fixture = try makeFixture()
        let initial = try await fixture.model.availableProjects()
        XCTAssertFalse(initial.contains { $0.id == "new-list" })
        await fixture.server.addProject(TickTickProject(id: "new-list", name: "Created in TickTick", permission: "write"))
        let refreshed = try await fixture.model.availableProjects()
        XCTAssertTrue(refreshed.contains { $0.id == "new-list" })
        let requests = await fixture.server.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
    }

    func testDestinationChangePersistsAndOnlyNewTasksUseIt() async throws {
        let fixture = try makeFixture()
        let existing = TodoTask(title: "Already synced", remote: RemoteTaskIdentity(taskID: "existing", projectID: "original"), syncState: .synced)
        var state = TaskState()
        state.merge([TickTickTask(id: "existing", projectId: "original", title: existing.title)])
        try fixture.store.save(state)
        let service = try TaskService(store: fixture.store, client: fixture.client, projectID: "original")
        let model = AppModel(service: service, client: fixture.client,
                             project: ProjectOption(id: "original", name: "Original"), preferences: fixture.preferences)
        try await model.changeDestination(to: ProjectOption(id: "destination", name: "New destination"))
        XCTAssertEqual(model.projectID, "destination")
        XCTAssertEqual(model.projectName, "New destination")
        XCTAssertEqual(fixture.preferences.string(forKey: "ticktick.projectID"), "destination")
        XCTAssertEqual(fixture.preferences.string(forKey: "ticktick.projectName"), "New destination")
        let beforeAdd = await fixture.server.requests()
        XCTAssertTrue(beforeAdd.isEmpty, "Changing a default must not move or update existing remote tasks.")

        let newTask = try await service.addTask(title: "Created after changing list")
        _ = try await service.sync()
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.task(id: newTask.id)?.remote?.projectID, "destination")
        XCTAssertEqual(snapshot.tasks.first { $0.title == "Already synced" }?.remote?.projectID, "original")
        let posts = await fixture.server.requests().filter { $0.method == "POST" && $0.path == "/task" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.projectID, "destination")
        XCTAssertEqual(posts.first?.authorization, "Bearer saved-test-token")
    }

    func testListRefreshFailureDoesNotDiscardSavedConnection() async throws {
        let fixture = try makeFixture()
        await fixture.server.rejectLists(true)
        do {
            _ = try await fixture.model.availableProjects()
            XCTFail("A failed refresh must be reported.")
        } catch {
            XCTAssertTrue(fixture.model.connected)
            XCTAssertEqual(fixture.model.projectID, "original")
        }
        await fixture.server.rejectLists(false)
        let projects = try await fixture.model.availableProjects()
        XCTAssertEqual(projects.count, 2)
    }

    func testDisconnectRemovesOnlyTheInjectedFileCredential() async throws {
        let fixture = try makeFixture()
        let tokenURL = try XCTUnwrap(fixture.model.tokenFileURL)
        try TokenStore.file(tokenURL).save("file-test-token")
        try await fixture.model.disconnect()
        XCTAssertFalse(fixture.model.connected)
        XCTAssertNil(try TokenStore.file(tokenURL).read())
        XCTAssertNil(fixture.preferences.string(forKey: "ticktick.projectID"))
    }

    func testFailedCredentialRemovalKeepsConnectionAvailableForRetry() async throws {
        let fixture = try makeFixture()
        let tokenURL = try XCTUnwrap(fixture.model.tokenFileURL)
        try FileManager.default.createDirectory(at: tokenURL, withIntermediateDirectories: true)
        do {
            try await fixture.model.disconnect()
            XCTFail("A failed credential removal must be reported.")
        } catch {
            XCTAssertTrue(fixture.model.connected)
            XCTAssertEqual(fixture.model.projectID, "original")
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-settings-\(UUID().uuidString)")
        let store = JSONTaskStore(url: directory.appendingPathComponent("tasks.json"))
        let suite = "hawkeye-settings-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let server = SettingsServer()
        let client = TickTickClient(token: "saved-test-token", transport: server)
        let service = try TaskService(store: store, client: client, projectID: "original")
        let model = AppModel(service: service, client: client,
                             project: ProjectOption(id: "original", name: "Original"), preferences: preferences,
                             tokenStore: .file(directory.appendingPathComponent("token.txt")))
        return Fixture(model: model, server: server, client: client, store: store, preferences: preferences)
    }

    private struct Fixture {
        let model: AppModel
        let server: SettingsServer
        let client: TickTickClient
        let store: JSONTaskStore
        let preferences: UserDefaults
    }
}

private actor SettingsServer: HTTPTransport {
    struct Captured: Sendable {
        let method: String
        let path: String
        let authorization: String?
        let projectID: String?
        let cachePolicy: URLRequest.CachePolicy
    }

    private var captured: [Captured] = []
    private var rejecting = false
    private var created: [TickTickTask] = []
    private var additionalProjects: [TickTickProject] = []

    func requests() -> [Captured] { captured }
    func rejectLists(_ reject: Bool) { rejecting = reject }
    func addProject(_ project: TickTickProject) { additionalProjects.append(project) }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path.replacingOccurrences(of: "/open/v1", with: "")
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        captured.append(Captured(method: request.httpMethod ?? "GET", path: path,
                                 authorization: request.value(forHTTPHeaderField: "Authorization"), projectID: body?["projectId"] as? String,
                                 cachePolicy: request.cachePolicy))
        var status = 200
        let data: Data
        if path == "/project" {
            status = rejecting ? 401 : 200
            data = try JSONEncoder().encode([
                TickTickProject(id: "original", name: "Original", permission: "write"),
                TickTickProject(id: "destination", name: "New destination", permission: "write"),
                TickTickProject(id: "closed", name: "Closed", closed: true),
                TickTickProject(id: "notes", name: "Notes", kind: "NOTE"),
                TickTickProject(id: "readonly", name: "Read only", permission: "read")
            ] + additionalProjects)
        } else if path == "/task" && request.httpMethod == "POST" {
            let task = try JSONDecoder().decode(TickTickTask.self, from: request.httpBody!)
            created.append(task)
            data = try JSONEncoder().encode(task)
        } else if path.hasSuffix("/data") {
            data = try JSONEncoder().encode(TickTickProjectData(tasks: created))
        } else if path == "/task/filter" || path == "/task/completed" {
            data = Data("[]".utf8)
        } else {
            status = 404
            data = Data()
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
