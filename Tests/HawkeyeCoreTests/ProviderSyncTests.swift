import Foundation
import XCTest
@testable import HawkeyeCore

private let notionOpenPage = #"{"id":"page","parent":{"data_source_id":"db"},"properties":{"Name":{"id":"title","title":[{"plain_text":"Remote"}]},"State":{"id":"s","status":{"name":"Open"}},"When":{"id":"d","date":null}}}"#

private actor ProviderTestTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) throws -> (Int, String)
    private let handler: Handler
    private var requests: [URLRequest] = []
    init(_ handler: @escaping Handler) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let count = requests.filter { $0.url?.path == request.url?.path && $0.httpMethod == request.httpMethod }.count
        let (status, text) = try handler(request, count)
        return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func captured() -> [URLRequest] { requests }
}

private struct FixtureProvider: TaskSyncProvider {
    let id: TaskProviderID
    let retriesCreationSafely = true
    var remote: [RemoteTaskSnapshot] = []
    func create(_ intent: TaskCreationIntent, context: TaskSyncContext) async throws -> RemoteTaskIdentity {
        RemoteTaskIdentity(taskID: intent.temporaryID.uuidString, projectID: intent.destinationID, provider: id)
    }
    func update(_ task: TodoTask, identity: RemoteTaskIdentity, context: TaskSyncContext) async throws { try await context.check() }
    func pull(destinationID: String?, known: [RemoteTaskIdentity], since: Date?, until: Date, context: TaskSyncContext) async throws -> TaskPullResult {
        try await context.check()
        return TaskPullResult(tasks: remote)
    }
}

final class ProviderSyncTests: XCTestCase {
    func testLegacyIdentityDefaultsToTickTick() throws {
        let identity = try JSONDecoder().decode(RemoteTaskIdentity.self, from: Data(#"{"taskID":"old","projectID":"p"}"#.utf8))
        XCTAssertEqual(identity.provider, .ticktick)
        XCTAssertEqual(identity.taskID, "old")
    }

    func testSameRemoteIDsAcrossProvidersDoNotCollide() {
        var state = TaskState()
        for provider in TaskProviderID.allCases {
            state.merge([RemoteTaskSnapshot(identity: .init(taskID: "same", projectID: "p", provider: provider), title: provider.displayName)])
        }
        XCTAssertEqual(state.tasks.count, 3)
        state.merge([RemoteTaskSnapshot(identity: .init(taskID: "same", projectID: "moved", provider: .todoist), title: "Moved")])
        XCTAssertEqual(state.tasks.count, 3)
        XCTAssertEqual(state.tasks.first { $0.remote?.provider == .todoist }?.remote?.projectID, "moved")
    }

    func testSwitchingEveryProviderRetainsAllFieldsFocusAndImportedDuration() async throws {
        let store = temporaryStore()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let imported = TodoTask(title: "Imported", taskDescription: "Notes", createdAt: date, dueAt: date,
                                completedAt: date, remoteDuration: 300,
                                remote: .init(taskID: "remote", projectID: "p"), syncState: .synced)
        let local = TodoTask(title: "Local", duration: 600)
        let focus = UserFocusState()
        try store.save(TaskState(tasks: [imported, local], lastSyncedAt: date, userFocus: focus))
        let service = try TaskService(store: store)
        for provider in TaskProviderID.allCases {
            try await service.discardConnectionData()
            let detached = await service.snapshot()
            XCTAssertEqual(detached.tasks.map(\.id), [imported.id, local.id])
            XCTAssertEqual(detached.task(id: imported.id)?.title, imported.title)
            XCTAssertEqual(detached.task(id: imported.id)?.taskDescription, imported.taskDescription)
            XCTAssertEqual(detached.task(id: imported.id)?.createdAt, imported.createdAt)
            XCTAssertEqual(detached.task(id: imported.id)?.dueAt, imported.dueAt)
            XCTAssertEqual(detached.task(id: imported.id)?.completedAt, imported.completedAt)
            XCTAssertEqual(detached.task(id: imported.id)?.duration, 300)
            XCTAssertEqual(detached.task(id: local.id)?.duration, 600)
            XCTAssertTrue(detached.tasks.allSatisfy { $0.remote == nil && $0.remoteDuration == nil })
            XCTAssertEqual(detached.userFocus, focus)
            XCTAssertNil(detached.lastSyncedAt)
            XCTAssertEqual(detached.outbox.count, 2)
            await service.configureSync(provider: FixtureProvider(id: provider), destinationID: "new")
            _ = try await service.sync()
            let connected = await service.snapshot()
            XCTAssertTrue(connected.tasks.allSatisfy { $0.remote?.provider == provider })
            XCTAssertEqual(connected.tasks.map(\.id), [imported.id, local.id])
        }
        let saved = await service.snapshot()
        XCTAssertEqual(try store.load(), saved)
    }

    func testStartupMismatchDetachesOldIdentityBeforeAnyWrite() async throws {
        let store = temporaryStore()
        let original = TodoTask(title: "Retained", remoteDuration: 120, remote: .init(taskID: "old", projectID: "old"))
        try store.save(TaskState(tasks: [original]))
        let service = try TaskService(store: store, provider: FixtureProvider(id: .todoist), destinationID: "new")
        let detached = await service.snapshot()
        XCTAssertNil(detached.tasks.first?.remote)
        XCTAssertEqual(detached.tasks.first?.duration, 120)
        _ = try await service.sync()
        let synced = await service.snapshot()
        XCTAssertEqual(synced.tasks.first?.id, original.id)
        XCTAssertEqual(synced.tasks.first?.remote?.provider, .todoist)
        XCTAssertNotEqual(synced.tasks.first?.remote?.taskID, "old")
    }

    func testTodoistPaginationCheckedDatesAndDuration() async throws {
        let transport = ProviderTestTransport { request, _ in
            switch request.url!.path {
            case "/api/v1/projects":
                if request.url!.query == nil { return (200, #"{"results":[{"id":"p1","name":"One"}],"next_cursor":"next"}"#) }
                return (200, #"{"results":[{"id":"p2","name":"Two"}],"next_cursor":null}"#)
            case "/api/v1/tasks": return (200, #"{"results":[{"id":"a","project_id":"p1","content":"Open","checked":false,"due":{"date":"2026-11-13"},"duration":{"amount":25,"unit":"minute"}}],"next_cursor":null}"#)
            case "/api/v1/tasks/completed/by_completion_date": return (200, #"{"items":[{"id":"b","project_id":"p1","content":"Done","checked":true,"completed_at":"2026-11-12T10:00:00Z"}],"next_cursor":null}"#)
            default: return (404, "{}")
            }
        }
        let client = TodoistClient(token: " token ", transport: transport)
        let destinations = try await client.projects()
        XCTAssertEqual(destinations.map(\.name), ["One", "Two"])
        let result = try await TodoistTaskProvider(client: client).pull(destinationID: "p1", known: [], since: nil, until: Date(), context: TaskSyncContext())
        XCTAssertEqual(result.tasks.count, 2)
        XCTAssertEqual(result.tasks.first { $0.identity.taskID == "a" }?.duration, 1500)
        XCTAssertNotNil(result.tasks.first { $0.identity.taskID == "a" }?.dueAt)
        XCTAssertTrue(try XCTUnwrap(result.tasks.first { $0.identity.taskID == "b" }).completed)
        let requests = await transport.captured()
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer token" })
        XCTAssertTrue(requests.contains { $0.url?.query?.contains("cursor=next") == true })
    }

    func testTodoistAmbiguousCreateRetriesFrozenCommandThenBindsBeforeUpdate() async throws {
        let store = temporaryStore()
        let transport = ProviderTestTransport { request, count in
            if request.url!.path == "/api/v1/sync" {
                if count == 1 { throw URLError(.timedOut) }
                let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
                let command = body["commands"]!.array!.first!.object!
                return (200, "{\"sync_status\":{\"\(command["uuid"]!.string!)\":\"ok\"},\"temp_id_mapping\":{\"\(command["temp_id"]!.string!)\":\"server\"}}")
            }
            if request.url!.path == "/api/v1/tasks/server", request.httpMethod == "POST" {
                guard try store.load().tasks.first?.remote?.taskID == "server" else { return (400, "{}") }
                if count == 1 { throw URLError(.timedOut) }
                return (200, "{}")
            }
            if request.url!.path.contains("completed") { return (200, #"{"items":[],"next_cursor":null}"#) }
            if request.httpMethod == "GET", request.url!.path == "/api/v1/tasks" { return (200, #"{"results":[],"next_cursor":null}"#) }
            if request.httpMethod == "GET", request.url!.path == "/api/v1/tasks/server" { return (200, #"{"id":"server","project_id":"p","content":"Latest","checked":false}"#) }
            if request.httpMethod == "GET" { return (404, "{}") }
            return (204, "")
        }
        let provider = TodoistTaskProvider(client: TodoistClient(token: "t", transport: transport))
        let service = try TaskService(store: store, provider: provider, destinationID: "p")
        var task = try await service.addTask(title: "Frozen", dueAt: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try await service.sync()
        task.title = "Latest"
        try await service.updateTask(task)
        let restarted = try TaskService(store: store, provider: provider, destinationID: "p")
        _ = try await restarted.sync()
        let bound = await restarted.snapshot()
        XCTAssertEqual(bound.tasks.first?.remote?.taskID, "server")
        XCTAssertTrue(bound.isPending(task.id))
        XCTAssertEqual(bound.outbox.first?.kind, .update)
        _ = try await restarted.sync()
        let final = await restarted.snapshot()
        XCTAssertFalse(final.isPending(task.id))
        let requests = await transport.captured()
        let creates = requests.filter { $0.url?.path == "/api/v1/sync" }
        XCTAssertEqual(creates.count, 2)
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: creates[0].httpBody!),
                       try JSONDecoder().decode([String: JSONValue].self, from: creates[1].httpBody!))
        let commands = try JSONDecoder().decode([String: JSONValue].self, from: creates[0].httpBody!)
        let args = commands["commands"]?.array?.first?.object?["args"]?.object
        XCTAssertEqual(args?["content"]?.string, "Frozen")
        XCTAssertEqual(args?["due"]?.object?["date"]?.string, "2027-01-15T08:00:00Z")
        XCTAssertNil(args?["due_datetime"])
        XCTAssertNil(args?["due_string"])
        let updates = requests.filter { $0.url?.path == "/api/v1/tasks/server" && $0.httpMethod == "POST" }
        let latest = try JSONDecoder().decode([String: JSONValue].self, from: updates.last!.httpBody!)
        XCTAssertEqual(latest["content"]?.string, "Latest")
    }

    func testNotionSearchSchemaPaginationAndMappedPatchPreservesBody() async throws {
        let transport = ProviderTestTransport { request, _ in
            if request.url!.path == "/v1/search" {
                let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
                if body["start_cursor"] != nil { return (200, #"{"results":[],"has_more":false,"next_cursor":null}"#) }
                return (200, #"{"results":[{"id":"db","title":[{"plain_text":"Tasks"}],"properties":{"Name":{"id":"title","type":"title"},"State":{"id":"s","type":"status","status":{"options":[{"name":"Open"},{"name":"Done"}]}},"When":{"id":"d","type":"date"}}}],"has_more":true,"next_cursor":"next"}"#)
            }
            if request.url!.path.hasSuffix("query") { return (200, #"{"results":[{"id":"page","created_time":"2026-11-12T10:00:00Z","properties":{"Name":{"id":"title","title":[{"plain_text":"Page"}]},"State":{"id":"s","status":{"name":"Done"}},"When":{"id":"d","date":{"start":"2026-11-13"}}}}],"has_more":false,"next_cursor":null}"#) }
            if request.httpMethod == "GET", request.url!.path == "/v1/pages/page" { return (200, notionOpenPage) }
            return (200, "{}")
        }
        let client = NotionClient(token: "secret", transport: transport)
        let sources = try await client.dataSources()
        XCTAssertEqual(sources.first?.name, "Tasks")
        let mapping = notionMapping()
        try mapping.validate(in: XCTUnwrap(sources.first))
        let provider = NotionTaskProvider(client: client, mapping: mapping)
        let pull = try await provider.pull(destinationID: "db", known: [], since: nil, until: Date(), context: TaskSyncContext())
        XCTAssertEqual(pull.tasks.first?.title, "Page")
        XCTAssertNil(pull.tasks.first?.description)
        XCTAssertTrue(try XCTUnwrap(pull.tasks.first).completed)
        try await provider.update(TodoTask(title: "Changed", taskDescription: "Keep local", completedAt: Date()), identity: .init(taskID: "page", projectID: "db", provider: .notion), context: TaskSyncContext())
        let requests = await transport.captured()
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11" })
        let patch = try XCTUnwrap(requests.first { $0.httpMethod == "PATCH" })
        let body = try JSONDecoder().decode([String: JSONValue].self, from: patch.httpBody!)
        XCTAssertEqual(Set(body.keys), ["properties"])
        XCTAssertEqual(Set(body["properties"]!.object!.keys), ["title", "s", "d"])
        XCTAssertEqual(body["properties"]?.object?["s"]?.object?["status"]?.object?["name"]?.string, "Done")
    }

    func testNotionAmbiguousCreatePersistsPauseUntilExplicitRetry() async throws {
        let store = temporaryStore()
        let transport = ProviderTestTransport { request, count in
            if request.url!.path == "/v1/pages", request.httpMethod == "POST" {
                if count == 1 { throw URLError(.timedOut) }
                return (200, #"{"id":"page"}"#)
            }
            if request.url!.path.hasSuffix("query") { return (200, #"{"results":[],"has_more":false,"next_cursor":null}"#) }
            if request.httpMethod == "GET", request.url!.path == "/v1/pages/page" { return (200, notionOpenPage) }
            return (200, "{}")
        }
        let provider = NotionTaskProvider(client: NotionClient(token: "secret", transport: transport), mapping: notionMapping())
        let service = try TaskService(store: store, provider: provider, destinationID: "db")
        let task = try await service.addTask(title: "Only once")
        let first = try await service.sync()
        XCTAssertTrue(first.warnings.contains { $0.contains("avoid duplicates") })
        let restarted = try TaskService(store: store, provider: provider, destinationID: "db")
        _ = try await restarted.sync()
        let uncertain = await restarted.uncertainNotionCreations()
        XCTAssertEqual(uncertain.map(\.id), [task.id])
        var requests = await transport.captured()
        XCTAssertEqual(requests.filter { $0.url?.path == "/v1/pages" && $0.httpMethod == "POST" }.count, 1)
        try await restarted.retryUncertainCreation(taskID: task.id)
        _ = try await restarted.sync()
        requests = await transport.captured()
        XCTAssertEqual(requests.filter { $0.url?.path == "/v1/pages" && $0.httpMethod == "POST" }.count, 2)
        let result = await restarted.snapshot()
        XCTAssertEqual(result.tasks.first?.remote?.taskID, "page")
        XCTAssertFalse(result.isPending(task.id))
    }

    func testNotionUnauthorizedCreationCanRetryAfterTokenRepair() async throws {
        let store = temporaryStore()
        let transport = ProviderTestTransport { request, count in
            if request.url!.path == "/v1/pages", request.httpMethod == "POST" { return count == 1 ? (401, "{}") : (200, #"{"id":"page"}"#) }
            if request.url!.path.hasSuffix("query") { return (200, #"{"results":[],"has_more":false}"#) }
            if request.httpMethod == "GET", request.url!.path == "/v1/pages/page" { return (200, notionOpenPage) }
            return (200, "{}")
        }
        let provider = NotionTaskProvider(client: NotionClient(token: "secret", transport: transport), mapping: notionMapping())
        let service = try TaskService(store: store, provider: provider, destinationID: "db")
        _ = try await service.addTask(title: "Retry safely")
        do { _ = try await service.sync(); XCTFail("401 must abort") }
        catch TaskProviderError.httpStatus(401) { }
        let uncertain = await service.uncertainNotionCreations()
        XCTAssertTrue(uncertain.isEmpty)
        _ = try await service.sync()
        let state = await service.snapshot()
        XCTAssertTrue(state.outbox.isEmpty)
    }

    func testMissingNotionDescriptionMappingPreservesLocalDescription() {
        var task = TodoTask(title: "Existing", taskDescription: "Keep", remote: .init(taskID: "p", projectID: "db", provider: .notion))
        task.duration = 600
        var state = TaskState(tasks: [task])
        state.merge([RemoteTaskSnapshot(identity: task.remote!, title: "Remote", description: nil)])
        XCTAssertEqual(state.tasks.first?.taskDescription, "Keep")
        XCTAssertEqual(state.tasks.first?.duration, 600)
    }

    func testNotionMappingRequiresDistinctExplicitStatusOptions() {
        let source = NotionDataSource(id: "db", name: "Tasks", properties: [
            .init(id: "title", name: "Name", type: "title"), .init(id: "s", name: "State", type: "status", options: ["Open", "Done"]),
            .init(id: "d", name: "When", type: "date")
        ])
        var mapping = notionMapping()
        mapping.completedStatus = "Open"
        XCTAssertThrowsError(try mapping.validate(in: source))
        mapping.completedStatus = "Missing"
        XCTAssertThrowsError(try mapping.validate(in: source))
    }

    private func notionMapping() -> NotionTaskMapping {
        .init(titlePropertyID: "title", statusPropertyID: "s", statusType: "status", openStatus: "Open", completedStatus: "Done", duePropertyID: "d")
    }
    private func temporaryStore() -> JSONTaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HawkeyeProviderTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JSONTaskStore(url: directory.appendingPathComponent("tasks.json"))
    }
}
