import Foundation
import OSLog

struct ActivityScreenshot: Equatable, Sendable {
    let fileURL: URL
    let capturedAt: Date
    let displayID: UInt32?
}

struct ActivityBrowserContent: Equatable, Sendable {
    let fileURL: URL
    let capturedAt: Date
}

struct BrowserContentRecord: Codable, Equatable, Sendable {
    let sessionID: UUID
    let sessionStartedAt: Date?
    let snapshot: BrowserContentSnapshot
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date: Date
    let category: String
    let message: String
    let screenshot: ActivityScreenshot?
    let browserContent: ActivityBrowserContent?

    init(date: Date, category: String, message: String, screenshot: ActivityScreenshot? = nil,
         browserContent: ActivityBrowserContent? = nil) {
        self.date = date
        self.category = category
        self.message = message
        self.screenshot = screenshot
        self.browserContent = browserContent
    }
}

@MainActor
final class ActivityLog: ObservableObject {
    @Published private(set) var entries: [ActivityEntry] = []
    @Published private(set) var fileError: String?
    @Published private(set) var screenshotError: String?
    @Published private(set) var contentError: String?
    let fileURL: URL
    var screenshotsDirectory: URL { fileURL.deletingPathExtension().appendingPathExtension("screenshots") }
    var browserContentDirectory: URL { fileURL.deletingPathExtension().appendingPathExtension("browser-content") }
    private let logger = Logger(subsystem: "com.hawkeye2.mac", category: "activity")
    private let maximumBytes: Int

    init(fileURL: URL = ActivityLog.defaultURL, maximumBytes: Int = 5 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes
        do { try pruneScreenshots() }
        catch { screenshotError = "Could not maintain the screenshot thumbnail folder." }
        do { try pruneBrowserContent() }
        catch { contentError = BrowserContentFailure.persistenceFailed.message }
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Hawkeye2")
        #if DEBUG
        return base.appendingPathComponent("Development/activity.log")
        #else
        return base.appendingPathComponent("activity.log")
        #endif
    }

    func record(_ category: String, _ message: String, at date: Date = Date()) {
        append(ActivityEntry(date: date, category: category, message: message, screenshot: nil))
        do { try writeText(category, message, at: date); fileError = nil }
        catch {
            fileError = error.localizedDescription
            logger.error("Activity log could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordScreenshot(_ thumbnail: ScreenshotThumbnail, displayID: UInt32? = nil) throws {
        let destination = screenshotsDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        var created = false
        do {
            if FileManager.default.fileExists(atPath: screenshotsDirectory.path),
               try screenshotsDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw ScreenshotFailure.persistenceFailed
            }
            try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: screenshotsDirectory.path)
            guard FileManager.default.createFile(atPath: destination.path, contents: thumbnail.jpegData,
                                                  attributes: [.posixPermissions: 0o600]) else { throw ScreenshotFailure.persistenceFailed }
            created = true
            try pruneScreenshots(preserving: destination)
            let message = displayID.map { "Task screenshot captured on display \($0)." } ?? "Task screenshot captured."
            let relativePath = "\(screenshotsDirectory.lastPathComponent)/\(destination.lastPathComponent)"
            try writeText("Screenshot", "\(message) Thumbnail \(relativePath)", at: thumbnail.capturedAt)
            append(ActivityEntry(date: thumbnail.capturedAt, category: "Screenshot", message: message,
                                 screenshot: ActivityScreenshot(fileURL: destination, capturedAt: thumbnail.capturedAt, displayID: displayID)))
            screenshotError = nil
            fileError = nil
        } catch {
            if created { try? FileManager.default.removeItem(at: destination) }
            screenshotError = ScreenshotFailure.persistenceFailed.message
            throw ScreenshotFailure.persistenceFailed
        }
    }

    func recordBrowserContent(_ snapshot: BrowserContentSnapshot, session: MonitoringSession) throws {
        let destination = browserContentDirectory.appendingPathComponent("\(UUID().uuidString).json")
        var created = false
        do {
            try validateBrowserContentDirectory()
            try FileManager.default.createDirectory(at: browserContentDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browserContentDirectory.path)
            let record = BrowserContentRecord(sessionID: session.id, sessionStartedAt: session.startedAt, snapshot: snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(record)
            guard FileManager.default.createFile(atPath: destination.path, contents: data,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw BrowserContentFailure.persistenceFailed
            }
            created = true
            try pruneBrowserContent(preserving: destination)
            let relativePath = "\(browserContentDirectory.lastPathComponent)/\(destination.lastPathComponent)"
            let message = "Browser content captured."
            try writeText("Browser content", "\(message) Attachment \(relativePath)", at: snapshot.capturedAt)
            append(ActivityEntry(date: snapshot.capturedAt, category: "Browser content", message: message,
                                 browserContent: ActivityBrowserContent(fileURL: destination, capturedAt: snapshot.capturedAt)))
            contentError = nil
            fileError = nil
        } catch {
            if created { try? FileManager.default.removeItem(at: destination) }
            contentError = BrowserContentFailure.persistenceFailed.message
            throw BrowserContentFailure.persistenceFailed
        }
    }

    func retainedBrowserContentURL(_ attachment: ActivityBrowserContent) -> URL? {
        guard attachment.fileURL.deletingLastPathComponent().standardizedFileURL == browserContentDirectory.standardizedFileURL,
              attachment.fileURL.pathExtension == "json",
              UUID(uuidString: attachment.fileURL.deletingPathExtension().lastPathComponent) != nil else { return nil }
        do {
            try validateBrowserContentDirectory()
            let values = try attachment.fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return attachment.fileURL
        } catch { return nil }
    }

    private func validateBrowserContentDirectory() throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: browserContentDirectory.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw BrowserContentFailure.persistenceFailed
        }
    }

    private func pruneBrowserContent(preserving newest: URL? = nil) throws {
        try validateBrowserContentDirectory()
        guard FileManager.default.fileExists(atPath: browserContentDirectory.path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browserContentDirectory.path)
        let files = try FileManager.default.contentsOfDirectory(at: browserContentDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        let owned = try files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1 }
        for (url, _) in owned.filter({ $0.0 != newest }).prefix(max(0, owned.count - 240)) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func append(_ entry: ActivityEntry) {
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        logger.info("[\(entry.category, privacy: .public)] \(entry.message, privacy: .private)")
    }

    private func pruneScreenshots(preserving newest: URL? = nil) throws {
        guard FileManager.default.fileExists(atPath: screenshotsDirectory.path) else { return }
        let directory = try screenshotsDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else { throw ScreenshotFailure.persistenceFailed }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: screenshotsDirectory.path)
        let files = try FileManager.default.contentsOfDirectory(at: screenshotsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        let owned = try files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "jpg", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1 }
        for (url, _) in owned.filter({ $0.0.lastPathComponent != newest?.lastPathComponent }).prefix(max(0, owned.count - 240)) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func writeText(_ category: String, _ message: String, at date: Date) throws {
        let clean = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let line = "\(date.ISO8601Format()) [\(category)] \(clean)\n"
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if size >= maximumBytes {
            let previous = fileURL.appendingPathExtension("previous")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: fileURL, to: previous)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }
}
