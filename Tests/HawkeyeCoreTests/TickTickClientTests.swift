import Foundation
import XCTest
@testable import HawkeyeCore

final class TickTickClientTests: XCTestCase {
    func testSpecificDueDateClearsAllDayOnlyWhenDateChanges() async throws {
        let server = MockTickTickServer()
        let client = TickTickClient(token: "fake-token", transport: server)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = RemoteTaskIdentity(taskID: "remote", projectID: "p")
        let task = TodoTask(title: "Timed task", dueAt: due)
        _ = try await client.createTask(task, identity: identity)
        let remote = TickTickTask(id: "remote", projectId: "p", title: "All day", dueDate: due, rawFields: ["isAllDay": .bool(true)])
        try await client.updateTask(task, identity: identity, preserving: remote)
        var rescheduled = task
        rescheduled.dueAt = due.addingTimeInterval(3_600)
        try await client.updateTask(rescheduled, identity: identity, preserving: remote)
        let requests = await server.capturedRequests()
        let bodies = try requests.map { try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap($0.body)) }

        XCTAssertEqual(bodies.map { $0["isAllDay"] }, [.bool(false), .bool(true), .bool(false)])
    }

    func testProjectsLoadEveryDocumentedPage() async throws {
        let server = MockTickTickServer()
        let expected = (0..<201).map { TickTickProject(id: "project-\($0)", name: "Project \($0)") }
        await server.setProjects(expected)
        let client = TickTickClient(token: "fake-token", transport: server)

        let projects = try await client.projects()
        let requests = await server.capturedRequests()

        XCTAssertEqual(projects, expected)
        XCTAssertEqual(requests.map { $0.query["offset"] }, ["0", "200"])
        XCTAssertEqual(requests.map { $0.query["limit"] }, ["200", "200"])
    }

    func testRepeatedProjectPageStopsWithUniqueProjectsAndWarning() async throws {
        let server = MockTickTickServer()
        let expected = (0..<200).map { TickTickProject(id: "project-\($0)", name: "Project \($0)") }
        await server.setProjects(expected)
        await server.repeatProjectPages()
        let client = TickTickClient(token: "fake-token", transport: server)

        let listing = try await client.projectListing()
        let requests = await server.capturedRequests()

        XCTAssertEqual(listing.projects, expected)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(listing.warnings.count, 1)
        XCTAssertTrue(try XCTUnwrap(listing.warnings.first).contains("repeated a project page"))
    }

    func testErrorResponseAndTransportErrorNeverExposeToken() async throws {
        let secret = "never-display-this-token"
        let statusClient = TickTickClient(token: secret, transport: ErrorTransport(secret: secret, status: 401))
        let throwingClient = TickTickClient(token: secret, transport: ErrorTransport(secret: secret, status: nil))
        for client in [statusClient, throwingClient] {
            do { _ = try await client.projects(); XCTFail("Request should fail") }
            catch {
                XCTAssertFalse(error.localizedDescription.contains(secret))
                XCTAssertFalse(String(describing: error).contains(secret))
            }
        }
    }

    func testDocumentedDateVariantsDecodeWithoutLosingCompletion() throws {
        for string in ["2026-10-21T12:34:56+0000", "2026-10-21T12:34:56.123+0000", "2026-10-21T12:34:56Z", "2026-10-21T12:34:56.123Z"] {
            let data = try JSONSerialization.data(withJSONObject: ["id": "t", "projectId": "p", "title": "Title", "dueDate": string, "completedTime": string, "status": 2])
            let task = try JSONDecoder().decode(TickTickTask.self, from: data)
            XCTAssertNotNil(task.dueDate, string)
            XCTAssertEqual(task.dueDate, task.completedTime)
            XCTAssertEqual(task.status, 2)
        }
    }

    func testInvalidRemoteDateIsVisibleInsteadOfErasingDueDate() {
        let data = Data("{\"id\":\"t\",\"projectId\":\"p\",\"title\":\"Title\",\"dueDate\":\"invalid\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TickTickTask.self, from: data))
    }
}

private struct ErrorTransport: HTTPTransport {
    let secret: String
    let status: Int?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let status else { throw NSError(domain: "Transport", code: 1, userInfo: [NSLocalizedDescriptionKey: secret]) }
        return (Data(secret.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
