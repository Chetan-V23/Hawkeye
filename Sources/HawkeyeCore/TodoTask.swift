import Foundation

public enum TaskSyncState: String, Codable, Sendable {
    case localOnly
    case pending
    case synced
}

public struct RemoteTaskIdentity: Codable, Equatable, Hashable, Sendable {
    public var taskID: String
    public var projectID: String
    public var provider: TaskProviderID

    public init(taskID: String, projectID: String, provider: TaskProviderID = .ticktick) {
        self.provider = provider
        self.taskID = taskID
        self.projectID = projectID
    }
    private enum CodingKeys: String, CodingKey { case taskID, projectID, provider }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try values.decode(String.self, forKey: .taskID)
        projectID = try values.decode(String.self, forKey: .projectID)
        provider = try values.decodeIfPresent(TaskProviderID.self, forKey: .provider) ?? .ticktick
    }
}

public struct TodoTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var taskDescription: String
    public var createdAt: Date
    public var dueAt: Date?
    public var duration: TimeInterval?
    public var completedAt: Date?
    public internal(set) var remoteDuration: TimeInterval?
    public internal(set) var remote: RemoteTaskIdentity?
    public internal(set) var syncState: TaskSyncState
    public internal(set) var revision: UInt64

    public var completed: Bool { completedAt != nil }

    public init(
        id: UUID = UUID(),
        title: String,
        taskDescription: String = "",
        createdAt: Date = Date(),
        dueAt: Date? = nil,
        duration: TimeInterval? = nil,
        completedAt: Date? = nil,
        remoteDuration: TimeInterval? = nil,
        remote: RemoteTaskIdentity? = nil,
        syncState: TaskSyncState = .localOnly
    ) {
        self.id = id
        self.title = title
        self.taskDescription = taskDescription
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.duration = duration
        self.completedAt = completedAt
        self.remoteDuration = remoteDuration
        self.remote = remote
        self.syncState = syncState
        self.revision = 0
    }
}

public enum TaskValidationError: Error, LocalizedError, Equatable {
    case emptyTitle
    case invalidDuration
    case taskNotFound
    case duplicateTask

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: return "Give the task a title."
        case .invalidDuration: return "Duration must be a positive number."
        case .taskNotFound: return "This task could not be found."
        case .duplicateTask: return "A task with this ID already exists."
        }
    }
}
