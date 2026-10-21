import Foundation

public struct PendingTaskOperation: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case create
        case update
    }

    public let id: UUID
    public let taskID: UUID
    public let revision: UInt64
    public internal(set) var kind: Kind

    public init(id: UUID = UUID(), taskID: UUID, revision: UInt64, kind: Kind) {
        self.id = id
        self.taskID = taskID
        self.revision = revision
        self.kind = kind
    }
}

public struct TaskState: Codable, Equatable, Sendable {
    public internal(set) var tasks: [TodoTask]
    public internal(set) var outbox: [PendingTaskOperation]
    public internal(set) var lastSyncedAt: Date?
    public internal(set) var userFocus: UserFocusState

    public init(tasks: [TodoTask] = [], outbox: [PendingTaskOperation] = [], lastSyncedAt: Date? = nil,
                userFocus: UserFocusState = UserFocusState()) {
        self.tasks = tasks
        self.outbox = outbox
        self.lastSyncedAt = lastSyncedAt
        self.userFocus = userFocus
    }

    private enum CodingKeys: String, CodingKey { case tasks, outbox, lastSyncedAt, userFocus }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode([TodoTask].self, forKey: .tasks)
        outbox = try container.decode([PendingTaskOperation].self, forKey: .outbox)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        userFocus = try container.decodeIfPresent(UserFocusState.self, forKey: .userFocus) ?? UserFocusState()
    }

    public func isPending(_ id: UUID) -> Bool {
        outbox.contains { $0.taskID == id }
    }

    public func task(id: UUID) -> TodoTask? {
        tasks.first { $0.id == id }
    }

    @discardableResult
    public mutating func add(_ task: TodoTask) throws -> TodoTask {
        guard !tasks.contains(where: { $0.id == task.id }) else { throw TaskValidationError.duplicateTask }
        var task = try validated(task)
        task.revision = 1
        task.syncState = task.remote == nil ? .localOnly : .pending
        tasks.append(task)
        enqueue(task, kind: task.remote == nil ? .create : .update)
        return task
    }

    @discardableResult
    public mutating func update(_ edited: TodoTask) throws -> TodoTask {
        guard let index = tasks.firstIndex(where: { $0.id == edited.id }) else { throw TaskValidationError.taskNotFound }
        let current = tasks[index]
        var task = try validated(edited)
        task.remote = current.remote
        task.createdAt = current.createdAt
        task.revision = current.revision + 1
        let sharedFieldsChanged = task.title != current.title
            || task.taskDescription != current.taskDescription
            || task.dueAt != current.dueAt
            || task.completedAt != current.completedAt
        task.syncState = sharedFieldsChanged ? (current.remote == nil ? .localOnly : .pending) : current.syncState
        tasks[index] = task
        clearInvalidManualStart()
        if sharedFieldsChanged {
            let kind = outbox.first(where: { $0.taskID == task.id })?.kind ?? (task.remote == nil ? .create : .update)
            enqueue(task, kind: kind)
        }
        return task
    }

    public mutating func setCompleted(id: UUID, completed: Bool, at date: Date = Date()) throws {
        guard var task = task(id: id) else { throw TaskValidationError.taskNotFound }
        guard task.completed != completed else { return }
        task.completedAt = completed ? date : nil
        _ = try update(task)
    }

    public mutating func merge(_ remoteTasks: [TickTickTask], at date: Date = Date()) {
        for remote in remoteTasks {
            let identity = RemoteTaskIdentity(taskID: remote.id, projectID: remote.projectId)
            if let index = tasks.firstIndex(where: { $0.remote?.taskID == identity.taskID }) {
                tasks[index].remote = identity
                guard !isPending(tasks[index].id) else { continue }
                tasks[index].title = remote.title
                tasks[index].taskDescription = remote.content ?? remote.desc ?? ""
                if tasks[index].dueAt.map(TickTickDate.string) != remote.scheduledStart.map(TickTickDate.string) {
                    tasks[index].dueAt = remote.scheduledStart
                }
                tasks[index].remoteDuration = remote.scheduledDuration
                tasks[index].completedAt = remote.status == 2 ? (remote.completedTime ?? tasks[index].completedAt ?? date) : nil
                tasks[index].syncState = .synced
            } else {
                tasks.append(TodoTask(
                    title: remote.title,
                    taskDescription: remote.content ?? remote.desc ?? "",
                    createdAt: remote.createdTime ?? date,
                    dueAt: remote.scheduledStart,
                    completedAt: remote.status == 2 ? (remote.completedTime ?? date) : nil,
                    remoteDuration: remote.scheduledDuration,
                    remote: identity,
                    syncState: .synced
                ))
            }
        }
        clearInvalidManualStart()
    }

    private mutating func clearInvalidManualStart() {
        if let selection = userFocus.manualStart, !tasks.contains(where: selection.matches) {
            userFocus.manualStart = nil
        }
    }

    mutating func bindCreate(taskID: UUID, projectID: String) -> TodoTask? {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return nil }
        if tasks[index].remote == nil {
            tasks[index].remote = RemoteTaskIdentity(
                taskID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description,
                projectID: projectID
            )
        }
        tasks[index].syncState = .pending
        return tasks[index]
    }

    mutating func confirmCreation(taskID: UUID, identity: RemoteTaskIdentity) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].remote = identity
        tasks[index].syncState = .pending
        if let operationIndex = outbox.firstIndex(where: { $0.taskID == taskID }) {
            outbox[operationIndex].kind = .update
        }
    }

    mutating func acknowledge(_ operation: PendingTaskOperation) {
        guard let index = outbox.firstIndex(where: { $0.id == operation.id }) else { return }
        outbox.remove(at: index)
        if let taskIndex = tasks.firstIndex(where: { $0.id == operation.taskID }) {
            tasks[taskIndex].syncState = .synced
        }
    }

    private mutating func enqueue(_ task: TodoTask, kind: PendingTaskOperation.Kind) {
        outbox.removeAll { $0.taskID == task.id }
        outbox.append(PendingTaskOperation(taskID: task.id, revision: task.revision, kind: kind))
    }

    private func validated(_ task: TodoTask) throws -> TodoTask {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.title.isEmpty else { throw TaskValidationError.emptyTitle }
        if let duration = task.duration, !duration.isFinite || duration <= 0 {
            throw TaskValidationError.invalidDuration
        }
        return task
    }
}
