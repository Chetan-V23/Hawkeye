import Foundation

public struct SyncReport: Sendable {
    public let pushed: Int
    public let pulled: Int
    public let skipped: Bool
    public let warnings: [String]
    public let finishedAt: Date

    public init(pushed: Int = 0, pulled: Int = 0, skipped: Bool = false, warnings: [String] = [], finishedAt: Date = Date()) {
        self.pushed = pushed
        self.pulled = pulled
        self.skipped = skipped
        self.warnings = warnings
        self.finishedAt = finishedAt
    }
}

public protocol TaskServicing: Sendable {
    func snapshot() async -> TaskState
    @discardableResult func addTask(title: String, description: String, dueAt: Date?, duration: TimeInterval?) async throws -> TodoTask
    @discardableResult func updateTask(_ task: TodoTask) async throws -> TodoTask
    func setCompleted(id: UUID, completed: Bool) async throws
    func evaluateFocus(at: Date) async throws -> TaskFocusUpdate
    func pause(id: UUID, minutes: Int, at: Date) async throws -> TaskFocusUpdate
    func deferTask(id: UUID, to: Date, at: Date) async throws
    func startNow(id: UUID, at: Date) async throws -> TaskFocusUpdate
    func configureSync(client: TickTickClient?, projectID: String?) async
    func configureSync(provider: (any TaskSyncProvider)?, destinationID: String?) async
    func discardConnectionData() async throws
    func uncertainNotionCreations() async -> [TodoTask]
    func retryUncertainCreation(taskID: UUID) async throws
    func attachUncertainCreation(taskID: UUID, pageID: String) async throws
    func sync() async throws -> SyncReport
}

public actor TaskService: TaskServicing {
    private var state: TaskState
    private let store: JSONTaskStore
    private var provider: (any TaskSyncProvider)?
    private var destinationID: String?
    private var configurationGeneration: UInt64 = 0
    private var syncInProgress = false
    private var focus = TaskFocusController()

    public init(store: JSONTaskStore, client: TickTickClient? = nil, projectID: String? = nil) throws {
        self.state = try store.load()
        self.store = store
        self.provider = client.map { TickTickTaskProvider(client: $0) }
        self.destinationID = projectID
    }

    public init(store: JSONTaskStore, provider: (any TaskSyncProvider)?, destinationID: String?) throws {
        var loaded = try store.load()
        if let provider, loaded.tasks.contains(where: { $0.remote.map { $0.provider != provider.id } ?? false })
            || loaded.outbox.contains(where: { $0.creationIntent.map { $0.provider != provider.id } ?? false }) {
            loaded.discardConnectionData()
            try store.save(loaded)
        }
        self.state = loaded
        self.store = store
        self.provider = provider
        self.destinationID = destinationID
    }

    public func snapshot() -> TaskState { state }

    @discardableResult
    public func addTask(title: String, description: String = "", dueAt: Date? = nil, duration: TimeInterval? = nil) throws -> TodoTask {
        var next = state
        let task = try next.add(TodoTask(title: title, taskDescription: description, dueAt: dueAt, duration: duration))
        try commit(next)
        return task
    }

    @discardableResult
    public func updateTask(_ task: TodoTask) throws -> TodoTask {
        guard var latest = state.task(id: task.id) else { throw TaskValidationError.taskNotFound }
        latest.title = task.title
        latest.taskDescription = task.taskDescription
        latest.dueAt = task.dueAt
        latest.duration = task.duration
        var next = state
        let updated = try next.update(latest)
        try commit(next)
        return updated
    }

    public func setCompleted(id: UUID, completed: Bool) throws {
        var next = state
        try next.setCompleted(id: id, completed: completed)
        try commit(next)
    }

    public func evaluateFocus(at date: Date = Date()) throws -> TaskFocusUpdate {
        var next = state
        var controller = focus
        let update = controller.evaluate(tasks: next.tasks, user: &next.userFocus, at: date)
        if next.userFocus != state.userFocus { try commit(next) }
        focus = controller
        return update
    }

    public func pause(id: UUID, minutes: Int, at date: Date = Date()) throws -> TaskFocusUpdate {
        guard [2, 3, 5].contains(minutes) else { throw TaskFocusError.invalidPause }
        var next = state
        var controller = focus
        let before = controller.evaluate(tasks: next.tasks, user: &next.userFocus, at: date)
        guard before.activeTask?.id == id else { throw TaskFocusError.taskNotActive }
        guard !next.userFocus.snoozedTaskIDs.contains(id) else { throw TaskFocusError.alreadySnoozed }
        let snooze = UserSnooze(taskID: id, until: date.addingTimeInterval(TimeInterval(minutes * 60)))
        next.userFocus.snooze = snooze
        next.userFocus.snoozedTaskIDs.insert(id)
        let after = controller.evaluate(tasks: next.tasks, user: &next.userFocus, at: date)
        try commit(next)
        focus = controller
        return TaskFocusUpdate(activeTask: after.activeTask, user: after.user,
                               events: before.events + [.snoozed(snooze)] + after.events,
                               nextTransitionAt: after.nextTransitionAt)
    }

    public func deferTask(id: UUID, to start: Date, at date: Date = Date()) throws {
        guard start > date else { throw TaskFocusError.invalidDeferral }
        guard var task = state.task(id: id), !task.completed else { throw TaskValidationError.taskNotFound }
        task.dueAt = start
        var next = state
        _ = try next.update(task)
        try commit(next)
    }

    public func startNow(id: UUID, at date: Date = Date()) throws -> TaskFocusUpdate {
        guard var task = state.task(id: id), !task.completed else { throw TaskValidationError.taskNotFound }
        var next = state
        var controller = focus
        let before = controller.evaluate(tasks: next.tasks, user: &next.userFocus, at: date)
        if let active = before.activeTask {
            throw active.id == id ? TaskFocusError.taskAlreadyActive : TaskFocusError.anotherTaskActive
        }
        var events = before.events
        if next.userFocus.snooze != nil { events.append(.snoozeEnded) }
        next.userFocus.snooze = nil
        next.userFocus.manualStart = ManualTaskStart(taskID: id, start: date)
        task.dueAt = date
        _ = try next.update(task)
        let after = controller.evaluate(tasks: next.tasks, user: &next.userFocus, at: date)
        try commit(next)
        focus = controller
        return TaskFocusUpdate(activeTask: after.activeTask, user: after.user, events: events + after.events,
                               nextTransitionAt: after.nextTransitionAt)
    }

    public func configureSync(client: TickTickClient?, projectID: String?) {
        configureSync(provider: client.map { TickTickTaskProvider(client: $0) }, destinationID: projectID)
    }

    public func configureSync(provider: (any TaskSyncProvider)?, destinationID: String?) {
        self.provider = provider
        self.destinationID = destinationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        configurationGeneration += 1
    }

    public func discardConnectionData() throws {
        configurationGeneration += 1
        provider = nil
        destinationID = nil
        var next = state
        next.discardConnectionData()
        try commit(next)
    }

    public func uncertainNotionCreations() -> [TodoTask] {
        state.outbox.filter { $0.creationIntent?.provider == .notion && $0.creationIntent?.uncertain == true }
            .compactMap { state.task(id: $0.taskID) }
    }

    public func retryUncertainCreation(taskID: UUID) throws {
        guard state.outbox.contains(where: { $0.taskID == taskID && $0.creationIntent?.provider == .notion && $0.creationIntent?.uncertain == true }) else { return }
        var next = state
        next.setCreationUncertain(taskID: taskID, false)
        try commit(next)
    }

    public func attachUncertainCreation(taskID: UUID, pageID: String) async throws {
        guard let intent = state.outbox.first(where: { $0.taskID == taskID })?.creationIntent,
              intent.provider == .notion, intent.uncertain,
              !pageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskProviderError.uncertainCreation }
        guard let provider, provider.id == .notion else { throw TaskProviderError.uncertainCreation }
        let generation = configurationGeneration
        let context = TaskSyncContext { try await self.checkConfiguration(generation) }
        let identity = try await provider.recoverCreation(intent, pageID: pageID, context: context)
        try checkConfiguration(generation)
        guard state.outbox.first(where: { $0.taskID == taskID })?.creationIntent?.commandID == intent.commandID else {
            throw TaskProviderError.uncertainCreation
        }
        let id = identity.taskID
        var next = state
        if let duplicate = next.tasks.first(where: { $0.id != taskID && $0.remote?.provider == .notion && $0.remote?.taskID == id }) {
            guard !next.isPending(duplicate.id) else { throw TaskValidationError.duplicateTask }
            next.tasks.removeAll { $0.id == duplicate.id }
        }
        next.confirmCreation(taskID: taskID, identity: identity)
        try commit(next)
    }

    public func sync() async throws -> SyncReport {
        guard !syncInProgress, let provider else { return SyncReport(skipped: true) }
        syncInProgress = true
        defer { syncInProgress = false }
        let generation = configurationGeneration
        let destination = destinationID
        let context = TaskSyncContext { try await self.checkConfiguration(generation) }
        if state.tasks.contains(where: { $0.remote.map { $0.provider != provider.id } ?? false })
            || state.outbox.contains(where: { $0.creationIntent.map { $0.provider != provider.id } ?? false }) {
            var detached = state
            detached.discardConnectionData()
            try commit(detached)
        }
        var pushed = 0
        var warnings: [String] = []
        for id in state.outbox.map(\.taskID) {
            try checkConfiguration(generation)
            guard var operation = state.outbox.first(where: { $0.taskID == id }), var task = state.task(id: id) else { continue }
            let context = TaskSyncContext(operationID: operation.statusIntent?.commandID ?? operation.id) {
                try await self.checkConfiguration(generation)
            }
            do {
                if operation.kind == .create {
                    guard let destination, !destination.isEmpty else { continue }
                    var prepared = state
                    if provider.id == .ticktick, task.remote == nil {
                        _ = prepared.bindCreate(taskID: id, projectID: destination)
                    }
                    guard let intent = prepared.prepareCreation(taskID: id, provider: provider.id, destinationID: destination) else { continue }
                    if intent.uncertain && !provider.retriesCreationSafely { throw TaskProviderError.uncertainCreation }
                    if !provider.retriesCreationSafely { prepared.setCreationUncertain(taskID: id, true) }
                    try commit(prepared)
                    operation = state.outbox.first(where: { $0.taskID == id }) ?? operation
                    let identity: RemoteTaskIdentity
                    do {
                        identity = try await provider.create(intent, context: context)
                    } catch let error as TaskProviderError {
                        try checkConfiguration(generation)
                        let rejectedBeforeCreation: Bool
                        if case .httpStatus(let code) = error { rejectedBeforeCreation = (400..<500).contains(code) }
                        else { rejectedBeforeCreation = error == .missingToken || error == .invalidMapping }
                        if rejectedBeforeCreation {
                            var rejected = state
                            rejected.setCreationUncertain(taskID: id, false)
                            try commit(rejected)
                        }
                        throw error
                    }
                    try checkConfiguration(generation)
                    var confirmed = state
                    confirmed.confirmCreation(taskID: id, identity: identity)
                    try commit(confirmed)
                    task.remote = identity
                    try await provider.update(task, identity: identity, context: context)
                    try checkConfiguration(generation)
                } else if let identity = task.remote, identity.provider == provider.id {
                    try await provider.update(task, identity: identity, context: context)
                    try checkConfiguration(generation)
                } else { continue }
                var acknowledged = state
                acknowledged.acknowledge(operation)
                try commit(acknowledged)
                pushed += 1
            } catch is CancellationError { throw CancellationError() }
            catch {
                try checkConfiguration(generation)
                if isAuthenticationError(error) { throw error }
                if state.outbox.first(where: { $0.taskID == id })?.creationIntent?.uncertain == true {
                    warnings.append(TaskProviderError.uncertainCreation.localizedDescription)
                } else { warnings.append(error.localizedDescription) }
            }
        }
        let startedAt = Date()
        let result = try await provider.pull(destinationID: destination,
                                             known: state.tasks.compactMap(\.remote).filter { $0.provider == provider.id },
                                             since: state.lastSyncedAt, until: startedAt, context: context)
        try checkConfiguration(generation)
        var merged = state
        merged.merge(result.tasks.sorted { $0.identity.taskID < $1.identity.taskID })
        if result.historyLoaded { merged.lastSyncedAt = startedAt }
        try commit(merged)
        warnings.append(contentsOf: result.warnings)
        return SyncReport(pushed: pushed, pulled: result.tasks.count, warnings: warnings)
    }

    private func checkConfiguration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw CancellationError() }
    }

    private func commit(_ next: TaskState) throws {
        try store.save(next)
        state = next
    }
}

func isAuthenticationError(_ error: Error) -> Bool {
    if let error = error as? TickTickError { return error == .httpStatus(401) || error == .missingToken }
    if let error = error as? TaskProviderError { return error == .httpStatus(401) || error == .missingToken }
    return false
}
