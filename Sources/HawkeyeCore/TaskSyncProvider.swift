import Foundation

public enum TaskProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case ticktick, todoist, notion
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .ticktick: return "TickTick"; case .todoist: return "Todoist"; case .notion: return "Notion" }
    }
}

public struct TaskDestination: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct NotionProperty: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let options: [String]
    public init(id: String, name: String, type: String, options: [String] = []) {
        self.id = id; self.name = name; self.type = type; self.options = options
    }
}

public struct NotionDataSource: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let properties: [NotionProperty]
    public init(id: String, name: String, properties: [NotionProperty]) {
        self.id = id; self.name = name; self.properties = properties
    }
}

public struct NotionTaskMapping: Codable, Equatable, Sendable {
    public var titlePropertyID: String
    public var statusPropertyID: String
    public var statusType: String
    public var openStatus: String
    public var completedStatus: String
    public var duePropertyID: String
    public var descriptionPropertyID: String?
    public init(titlePropertyID: String, statusPropertyID: String, statusType: String,
                openStatus: String = "", completedStatus: String = "", duePropertyID: String,
                descriptionPropertyID: String? = nil) {
        self.titlePropertyID = titlePropertyID; self.statusPropertyID = statusPropertyID
        self.statusType = statusType; self.openStatus = openStatus; self.completedStatus = completedStatus
        self.duePropertyID = duePropertyID; self.descriptionPropertyID = descriptionPropertyID
    }
    public func validate(in source: NotionDataSource) throws {
        func property(_ id: String, _ types: [String]) -> Bool {
            source.properties.contains { $0.id == id && types.contains($0.type) }
        }
        guard property(titlePropertyID, ["title"]), property(statusPropertyID, [statusType]),
              ["status", "select", "checkbox"].contains(statusType), property(duePropertyID, ["date"]),
              descriptionPropertyID.map({ property($0, ["rich_text"]) }) ?? true else {
            throw TaskProviderError.invalidMapping
        }
        if statusType != "checkbox" {
            let options = source.properties.first { $0.id == statusPropertyID }?.options ?? []
            guard openStatus != completedStatus, options.contains(openStatus), options.contains(completedStatus) else {
                throw TaskProviderError.invalidMapping
            }
        }
    }
}

public struct RemoteTaskSnapshot: Sendable {
    public let identity: RemoteTaskIdentity
    public let title: String
    public let description: String?
    public let createdAt: Date?
    public let dueAt: Date?
    public let duration: TimeInterval?
    public let completed: Bool
    public let completedAt: Date?
    public init(identity: RemoteTaskIdentity, title: String, description: String? = nil, createdAt: Date? = nil,
                dueAt: Date? = nil, duration: TimeInterval? = nil, completed: Bool = false, completedAt: Date? = nil) {
        self.identity = identity; self.title = title; self.description = description; self.createdAt = createdAt
        self.dueAt = dueAt; self.duration = duration; self.completed = completed; self.completedAt = completedAt
    }
}

public struct TaskPullResult: Sendable {
    public let tasks: [RemoteTaskSnapshot]
    public let warnings: [String]
    public let historyLoaded: Bool
    public init(tasks: [RemoteTaskSnapshot], warnings: [String] = [], historyLoaded: Bool = true) {
        self.tasks = tasks; self.warnings = warnings; self.historyLoaded = historyLoaded
    }
}

public struct TaskCreationIntent: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let temporaryID: UUID
    public let provider: TaskProviderID
    public let destinationID: String
    public let payload: TodoTask
    public internal(set) var uncertain: Bool
    public init(provider: TaskProviderID, destinationID: String, payload: TodoTask) {
        commandID = UUID(); temporaryID = UUID(); self.provider = provider
        self.destinationID = destinationID; self.payload = payload; uncertain = false
    }
}

public struct TaskSyncContext: Sendable {
    private let validation: @Sendable () async throws -> Void
    public let operationID: UUID?
    public init(operationID: UUID? = nil, check: @escaping @Sendable () async throws -> Void = {}) {
        self.operationID = operationID
        validation = check
    }
    public func check() async throws { try Task.checkCancellation(); try await validation() }
}

public protocol TaskSyncProvider: Sendable {
    var id: TaskProviderID { get }
    var retriesCreationSafely: Bool { get }
    func create(_ intent: TaskCreationIntent, context: TaskSyncContext) async throws -> RemoteTaskIdentity
    func recoverCreation(_ intent: TaskCreationIntent, pageID: String, context: TaskSyncContext) async throws -> RemoteTaskIdentity
    func update(_ task: TodoTask, identity: RemoteTaskIdentity, context: TaskSyncContext) async throws
    func pull(destinationID: String?, known: [RemoteTaskIdentity], since: Date?, until: Date, context: TaskSyncContext) async throws -> TaskPullResult
}

public enum TaskProviderError: Error, LocalizedError, Equatable {
    case missingToken, connection, invalidResponse, httpStatus(Int), remoteTaskMissing, invalidMapping, uncertainCreation
    public var errorDescription: String? {
        switch self {
        case .missingToken: return "Enter a personal access token."
        case .connection: return "The task app could not be reached. Your changes are saved."
        case .invalidResponse: return "The task app returned an unreadable response. Your changes are saved."
        case .httpStatus(let status): return "The task app returned HTTP \(status). Check your token and permissions. Your changes are saved."
        case .remoteTaskMissing: return "The remote task could not be found. Your local changes are saved."
        case .invalidMapping: return "Choose valid title, completion, and date properties with distinct open and completed options."
        case .uncertainCreation: return "Notion may have created this task. Automatic creation is paused to avoid duplicates. Check the database, then attach the existing page or explicitly retry creation."
        }
    }
}

public extension TaskSyncProvider {
    func recoverCreation(_ intent: TaskCreationIntent, pageID: String, context: TaskSyncContext) async throws -> RemoteTaskIdentity {
        throw TaskProviderError.uncertainCreation
    }
}
