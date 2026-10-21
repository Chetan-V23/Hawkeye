import XCTest
@testable import Hawkeye2

@MainActor
final class ActivityLogTests: XCTestCase {
    func testRecordsReadableFileAndRestrictsFilePermissions() throws {
        let url = temporaryURL()
        let log = ActivityLog(fileURL: url)
        log.record("Task", "Completed proposal.")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[Task] Completed proposal."))
        XCTAssertEqual(log.entries.last?.message, "Completed proposal.")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNil(log.fileError)
    }

    func testRotatesFileAndRetainsPreviousLog() throws {
        let url = temporaryURL()
        let log = ActivityLog(fileURL: url, maximumBytes: 1)
        log.record("Sync", "First sync.")
        log.record("Focus", "Activated next task.")
        XCTAssertTrue(try String(contentsOf: url.appendingPathExtension("previous"), encoding: .utf8).contains("First sync."))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Activated next task."))
    }

    func testFileFailureRemainsVisibleInTheActivityWindow() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let log = ActivityLog(fileURL: url)
        log.record("Sync", "Sync failed.")
        XCTAssertNotNil(log.fileError)
        XCTAssertEqual(log.entries.last?.message, "Sync failed.")
    }

    private func temporaryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-log-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("activity.log")
    }
}
