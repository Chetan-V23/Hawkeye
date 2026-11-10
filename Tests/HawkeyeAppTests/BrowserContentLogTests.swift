import XCTest
import HawkeyeCore
@testable import Hawkeye2

@MainActor
final class BrowserContentLogTests: XCTestCase {
    func testJSONRoundtripAndTextLogPrivacy() throws {
        let log = fixture()
        let task = TodoTask(title: "Sensitive task title", dueAt: Date().addingTimeInterval(-1), duration: 60)
        let snapshot = browserTestSnapshot()
        try log.recordBrowserContent(snapshot, session: .task(task))
        let attachment = try XCTUnwrap(log.entries.last?.browserContent)
        let record = try JSONDecoder().decode(BrowserContentRecord.self, from: Data(contentsOf: attachment.fileURL))
        XCTAssertEqual(record, BrowserContentRecord(sessionID: task.id, sessionStartedAt: task.dueAt, snapshot: snapshot))
        XCTAssertEqual(log.retainedBrowserContentURL(attachment), attachment.fileURL)
        XCTAssertNil(log.entries.last?.screenshot)
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("activity.browser-content/"))
        for sensitive in [snapshot.fullText, snapshot.mainContent!.text, snapshot.pageTitle!, snapshot.pageURL!.absoluteString, task.title] {
            XCTAssertFalse(text.contains(sensitive))
            XCTAssertFalse(log.entries.last!.message.contains(sensitive))
        }
        XCTAssertNil(log.contentError)
    }

    func testAttachmentFolderAndFilesHavePrivatePermissions() throws {
        let log = fixture()
        try log.recordBrowserContent(browserTestSnapshot(), session: .task(activeTask()))
        let attachment = try XCTUnwrap(log.entries.last?.browserContent)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: log.browserContentDirectory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: attachment.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
    }

    func testRetentionRunsAtStartupAndInsertionAndPreservesForeignFiles() throws {
        let log = fixture()
        let manager = FileManager.default
        try manager.createDirectory(at: log.browserContentDirectory, withIntermediateDirectories: true)
        let record = BrowserContentRecord(sessionID: UUID(), sessionStartedAt: Date(), snapshot: browserTestSnapshot())
        let data = try JSONEncoder().encode(record)
        var existing: [URL] = []
        for index in 0..<242 {
            let url = log.browserContentDirectory.appendingPathComponent("\(UUID()).json")
            try data.write(to: url)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: url.path)
            existing.append(url)
        }
        let foreign = log.browserContentDirectory.appendingPathComponent("notes.json")
        try Data("leave this alone".utf8).write(to: foreign)
        let uuidDirectory = log.browserContentDirectory.appendingPathComponent("\(UUID()).json")
        try manager.createDirectory(at: uuidDirectory, withIntermediateDirectories: false)
        let restarted = ActivityLog(fileURL: log.fileURL)
        XCTAssertNil(restarted.contentError)
        XCTAssertFalse(manager.fileExists(atPath: existing[0].path))
        XCTAssertFalse(manager.fileExists(atPath: existing[1].path))
        XCTAssertTrue(manager.fileExists(atPath: existing[2].path))
        try restarted.recordBrowserContent(browserTestSnapshot(), session: .task(activeTask()))
        XCTAssertFalse(manager.fileExists(atPath: existing[2].path))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: log.browserContentDirectory.path).count, 242)
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "leave this alone")
        XCTAssertTrue(manager.fileExists(atPath: uuidDirectory.path))
        let attachment = try XCTUnwrap(restarted.entries.last?.browserContent)
        XCTAssertNotNil(restarted.retainedBrowserContentURL(attachment))
    }

    func testLogAppendFailureRollsBackJSONAndDoesNotPublishAttachment() throws {
        let log = fixture()
        try FileManager.default.createDirectory(at: log.fileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try log.recordBrowserContent(browserTestSnapshot(), session: .task(activeTask()))) {
            XCTAssertEqual($0 as? BrowserContentFailure, .persistenceFailed)
        }
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.contentError, BrowserContentFailure.persistenceFailed.message)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: log.browserContentDirectory.path), [])
    }

    func testRejectsSymlinkFolderWithoutTouchingTarget() throws {
        let log = fixture()
        let manager = FileManager.default
        let target = log.fileURL.deletingLastPathComponent().appendingPathComponent("foreign")
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: log.browserContentDirectory, withDestinationURL: target)
        let restarted = ActivityLog(fileURL: log.fileURL)
        XCTAssertNotNil(restarted.contentError)
        XCTAssertThrowsError(try restarted.recordBrowserContent(browserTestSnapshot(), session: .task(activeTask()))) {
            XCTAssertEqual($0 as? BrowserContentFailure, .persistenceFailed)
        }
        XCTAssertTrue(restarted.entries.isEmpty)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: target.path), [])
    }

    func testMissingAndSymlinkAttachmentsCannotBeOpened() throws {
        let log = fixture()
        try log.recordBrowserContent(browserTestSnapshot(), session: .task(activeTask()))
        let attachment = try XCTUnwrap(log.entries.last?.browserContent)
        try FileManager.default.removeItem(at: attachment.fileURL)
        XCTAssertNil(log.retainedBrowserContentURL(attachment))
        let target = log.fileURL.deletingLastPathComponent().appendingPathComponent("foreign.json")
        try Data("private foreign data".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: attachment.fileURL, withDestinationURL: target)
        XCTAssertNil(log.retainedBrowserContentURL(attachment))
        _ = ActivityLog(fileURL: log.fileURL)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "private foreign data")
        let outside = ActivityBrowserContent(fileURL: target, capturedAt: Date())
        XCTAssertNil(log.retainedBrowserContentURL(outside))
    }

    func testExistingActivityEntryConstructorsRemainValid() {
        let entry = ActivityEntry(date: Date(), category: "App", message: "Started", screenshot: nil)
        XCTAssertNil(entry.browserContent)
    }

    private func activeTask() -> TodoTask { TodoTask(title: "Task", dueAt: Date().addingTimeInterval(-1), duration: 60) }
    private func fixture() -> ActivityLog {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-log-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ActivityLog(fileURL: directory.appendingPathComponent("activity.log"))
    }
}
