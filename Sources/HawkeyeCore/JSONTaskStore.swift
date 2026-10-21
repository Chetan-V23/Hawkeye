import Foundation

public struct JSONTaskStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Hawkeye2", isDirectory: true)
            .appendingPathComponent("tasks.json")
    }

    public func load() throws -> TaskState {
        guard FileManager.default.fileExists(atPath: url.path) else { return TaskState() }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else { throw TaskStoreError.unsupportedSchema(document.schemaVersion) }
        return document.state
    }

    public func save(_ state: TaskState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(schemaVersion: 1, state: state))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let state: TaskState
    }
}

public enum TaskStoreError: Error, LocalizedError {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Task storage version \(version) is newer than this app supports."
        }
    }
}
