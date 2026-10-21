import Foundation
import OSLog

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date: Date
    let category: String
    let message: String
}

@MainActor
final class ActivityLog: ObservableObject {
    @Published private(set) var entries: [ActivityEntry] = []
    @Published private(set) var fileError: String?
    let fileURL: URL
    private let logger = Logger(subsystem: "com.hawkeye2.mac", category: "activity")
    private let maximumBytes: Int

    init(fileURL: URL = ActivityLog.defaultURL, maximumBytes: Int = 5 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes
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
        entries.append(ActivityEntry(date: date, category: category, message: message))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        logger.info("[\(category, privacy: .public)] \(message, privacy: .private)")
        let clean = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let line = "\(date.ISO8601Format()) [\(category)] \(clean)\n"
        do {
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
            fileError = nil
        } catch {
            fileError = error.localizedDescription
            logger.error("Activity log could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
