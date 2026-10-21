import Foundation
import XCTest
@testable import HawkeyeCore

final class TaskStoreTests: XCTestCase {
    func testLegacyTaskSnoozeDoesNotChangeTheScheduledWindow() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let task = TodoTask(title: "Future task", dueAt: due)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        legacy["snoozedUntil"] = due.addingTimeInterval(600).timeIntervalSinceReferenceDate
        let restored = try JSONDecoder().decode(TodoTask.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.dueAt, due)
        XCTAssertEqual(restored.endsAt, due.addingTimeInterval(1800))
    }

    func testEveryTaskFieldAndOutboxSurviveAtomicRoundTrip() throws {
        let store = temporaryStore()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var state = TaskState()
        let task = try state.add(TodoTask(title: "Write proposal", taskDescription: "Include costs", createdAt: date, dueAt: date.addingTimeInterval(60), duration: 120))
        try state.setCompleted(id: task.id, completed: true, at: date)
        state.userFocus = UserFocusState(snooze: UserSnooze(taskID: task.id, until: date.addingTimeInterval(30)),
                                        snoozedTaskIDs: [task.id])
        try store.save(state)

        XCTAssertEqual(try store.load(), state)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        XCTAssertEqual(document["schemaVersion"] as? Int, 1)
        XCTAssertTrue(try store.load().tasks[0].completed)
        XCTAssertEqual(try store.load().outbox.count, 1)
    }

    func testEncodingFailureLeavesExistingFileIntact() throws {
        let store = temporaryStore()
        var state = TaskState()
        try state.add(TodoTask(title: "Keep me"))
        try store.save(state)
        let original = try Data(contentsOf: store.url)
        let invalid = TaskState(tasks: [TodoTask(title: "Invalid", duration: .infinity)])

        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }

    func testUnknownSchemaAndCorruptionAreNeverReset() throws {
        let store = temporaryStore()
        try store.save(TaskState())
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        document["schemaVersion"] = 999
        let newer = try JSONSerialization.data(withJSONObject: document)
        try newer.write(to: store.url)

        XCTAssertThrowsError(try store.load()) { error in
            guard case TaskStoreError.unsupportedSchema(999) = error else { return XCTFail("Unexpected error \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: store.url), newer)
        let corrupt = Data("incomplete JSON".utf8)
        try corrupt.write(to: store.url)
        XCTAssertThrowsError(try TaskService(store: store))
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    }

    func testFailedPersistenceDoesNotPublishMutation() async throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: store.url.deletingLastPathComponent().appendingPathComponent("blocked"))
        let failing = JSONTaskStore(url: store.url.deletingLastPathComponent().appendingPathComponent("blocked/tasks.json"))
        let service = try TaskService(store: failing)

        do {
            try await service.addTask(title: "Must persist first")
            XCTFail("The write should fail")
        } catch { }
        let state = await service.snapshot()
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertTrue(state.outbox.isEmpty)
    }

    func testValidationAndCompletionHaveOneSourceOfTruth() throws {
        var state = TaskState()
        XCTAssertThrowsError(try state.add(TodoTask(title: "  \n")))
        XCTAssertThrowsError(try state.add(TodoTask(title: "Title", duration: -1)))
        let task = try state.add(TodoTask(title: "  Title  "))
        XCTAssertEqual(task.title, "Title")
        XCTAssertFalse(task.completed)
        try state.setCompleted(id: task.id, completed: true)
        XCTAssertTrue(try XCTUnwrap(state.task(id: task.id)).completed)
        try state.setCompleted(id: task.id, completed: false)
        XCTAssertNil(try XCTUnwrap(state.task(id: task.id)).completedAt)
        XCTAssertEqual(state.outbox.count, 1)
    }

    private func temporaryStore() -> JSONTaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HawkeyeCoreTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JSONTaskStore(url: directory.appendingPathComponent("tasks.json"))
    }
}
