import XCTest
import ImageIO
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

    func testScreenshotAttachmentPersistsAReadablePrivateJPEGAndRelativeLogPath() throws {
        let log = ActivityLog(fileURL: temporaryURL())
        let capturedAt = Date().addingTimeInterval(-5)
        let jpeg = try syntheticScreenshotJPEG()
        try log.recordScreenshot(ScreenshotThumbnail(jpegData: jpeg, capturedAt: capturedAt))
        let entry = try XCTUnwrap(log.entries.last)
        let attachment = try XCTUnwrap(entry.screenshot)
        XCTAssertEqual(entry.date, capturedAt)
        XCTAssertEqual(attachment.capturedAt, capturedAt)
        XCTAssertEqual(try Data(contentsOf: attachment.fileURL), jpeg)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(attachment.fileURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 240)
        XCTAssertEqual(image.height, 150)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: log.screenshotsDirectory.path)
        let imageAttributes = try FileManager.default.attributesOfItem(atPath: attachment.fileURL.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((imageAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Thumbnail activity.screenshots/\(attachment.fileURL.lastPathComponent)"))
        XCTAssertFalse(text.contains(log.fileURL.deletingLastPathComponent().path))
        XCTAssertNil(log.screenshotError)
    }

    func testScreenshotRetentionPrunes241To240AtStartupAndAfterInsertionAndPreservesForeignFiles() throws {
        let url = temporaryURL()
        let directory = url.deletingPathExtension().appendingPathExtension("screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jpeg = try syntheticScreenshotJPEG()
        var owned: [URL] = []
        for index in 0..<241 {
            let file = directory.appendingPathComponent("\(UUID().uuidString).jpg")
            try jpeg.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(86_400 + Double(index))], ofItemAtPath: file.path)
            owned.append(file)
        }
        let foreign = directory.appendingPathComponent("holiday.jpg")
        try Data("Keep this file.".utf8).write(to: foreign)
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("Keep these notes.".utf8).write(to: notes)
        let nested = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let symlink = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: foreign)
        let log = ActivityLog(fileURL: url)
        XCTAssertEqual(try ownedScreenshotCount(in: directory), 240)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned[0].path))
        try log.recordScreenshot(ScreenshotThumbnail(jpegData: jpeg, capturedAt: Date()))
        XCTAssertEqual(try ownedScreenshotCount(in: directory), 240)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(log.entries.last?.screenshot).fileURL.path))
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "Keep this file.")
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "Keep these notes.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), foreign.path)
        let reloaded = ActivityLog(fileURL: url)
        XCTAssertEqual(try ownedScreenshotCount(in: directory), 240)
        XCTAssertNil(reloaded.screenshotError)
    }

    func testScreenshotPersistenceFailureDoesNotAddASuccessEntryOrAttachment() throws {
        let log = ActivityLog(fileURL: temporaryURL())
        try FileManager.default.createDirectory(at: log.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Not a folder.".utf8).write(to: log.screenshotsDirectory)
        XCTAssertThrowsError(try log.recordScreenshot(ScreenshotThumbnail(jpegData: syntheticScreenshotJPEG(), capturedAt: Date()))) {
            XCTAssertEqual($0 as? ScreenshotFailure, .persistenceFailed)
        }
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertNotNil(log.screenshotError)
    }

    func testDisplayAttachmentsShareOneRetentionLimitAndLogTheirIdentity() throws {
        let log = ActivityLog(fileURL: temporaryURL())
        let thumbnail = ScreenshotThumbnail(jpegData: try syntheticScreenshotJPEG(), capturedAt: Date())
        for index in 0..<241 { try log.recordScreenshot(thumbnail, displayID: UInt32(index % 3 + 1)) }
        XCTAssertEqual(try ownedScreenshotCount(in: log.screenshotsDirectory), 240)
        XCTAssertEqual(Set(log.entries.compactMap { $0.screenshot?.displayID }), [1, 2, 3])
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        for display in 1...3 { XCTAssertTrue(text.contains("captured on display \(display).")) }
    }

    private func ownedScreenshotCount(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter {
            let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return $0.pathExtension == "jpg" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
                && values.isRegularFile == true && values.isSymbolicLink != true
        }.count
    }

    private func temporaryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hawkeye-log-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("activity.log")
    }
}
