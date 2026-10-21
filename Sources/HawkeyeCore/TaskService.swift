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
    func sync() async throws -> SyncReport
}

public actor TaskService: TaskServicing {
    private var state: TaskState
    private let store: JSONTaskStore
    private var client: TickTickClient?
    private var projectID: String?
    private var configurationGeneration: UInt64 = 0
    private var syncInProgress = false
    private var focus = TaskFocusController()

    public init(store: JSONTaskStore, client: TickTickClient? = nil, projectID: String? = nil) throws {
        self.state = try store.load()
        self.store = store
        self.client = client
        self.projectID = projectID
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
        self.client = client
        self.projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        configurationGeneration += 1
    }

    public func sync() async throws -> SyncReport {
        guard !syncInProgress, let client else { return SyncReport(skipped: true) }
        syncInProgress = true
        defer { syncInProgress = false }
        let generation = configurationGeneration
        let destination = projectID
        var pushed = 0
        var warnings: [String] = []
        let pendingTaskIDs = state.outbox.map(\.taskID)

        for id in pendingTaskIDs {
            try checkConfiguration(generation)
            guard let operation = state.outbox.first(where: { $0.taskID == id }),
                  var task = state.task(id: id) else { continue }
            if operation.kind == .create, task.remote == nil {
                guard let destination, !destination.isEmpty else { continue }
                var next = state
                guard let boundTask = next.bindCreate(taskID: id, projectID: destination) else { continue }
                try commit(next)
                task = boundTask
            }
            guard var identity = task.remote else { continue }
            do {
                let remote = try await client.task(projectID: identity.projectID, taskID: identity.taskID)
                try checkConfiguration(generation)
                var alreadyCompleted = remote?.status == 2
                if operation.kind == .create {
                    if let remote {
                        identity = RemoteTaskIdentity(taskID: remote.id, projectID: remote.projectId)
                        var confirmed = state
                        confirmed.confirmCreation(taskID: id, identity: identity)
                        try commit(confirmed)
                        try await client.updateTask(task, identity: identity, preserving: remote)
                        try checkConfiguration(generation)
                    } else {
                        let created = try await client.createTask(task, identity: identity)
                        try checkConfiguration(generation)
                        if let created {
                            identity = RemoteTaskIdentity(taskID: created.id, projectID: created.projectId)
                            alreadyCompleted = created.status == 2
                        }
                        var confirmed = state
                        confirmed.confirmCreation(taskID: id, identity: identity)
                        try commit(confirmed)
                    }
                } else {
                    guard let remote else { throw TickTickError.remoteTaskMissing }
                    try await client.updateTask(task, identity: identity, preserving: remote)
                    try checkConfiguration(generation)
                }
                if task.completed, !alreadyCompleted {
                    try await client.completeTask(identity: identity)
                    try checkConfiguration(generation)
                }
                var acknowledged = state
                acknowledged.acknowledge(operation)
                try commit(acknowledged)
                pushed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TickTickError {
                try checkConfiguration(generation)
                if error == .httpStatus(401) || error == .missingToken { throw error }
                warnings.append(error.localizedDescription)
            }
        }

        let pullStartedAt = Date()
        var projects: [TickTickProject] = []
        do {
            let listing = try await client.projectListing()
            try checkConfiguration(generation)
            projects = listing.projects
            warnings.append(contentsOf: listing.warnings)
        } catch let error as TickTickError {
            try checkConfiguration(generation)
            if error == .httpStatus(401) || error == .missingToken { throw error }
            warnings.append("TickTick projects could not be loaded. \(error.localizedDescription)")
        }

        var remoteTasks: [String: TickTickTask] = [:]
        for project in projects where project.kind != "NOTE" && project.closed != true {
            do {
                let data = try await client.projectData(projectID: project.id)
                try checkConfiguration(generation)
                for task in data.tasks { remoteTasks[task.id] = task }
            } catch let error as TickTickError {
                try checkConfiguration(generation)
                if error == .httpStatus(401) || error == .missingToken { throw error }
                warnings.append("TickTick list \(project.name) could not be loaded. \(error.localizedDescription)")
            }
        }

        do {
            let inbox = try await client.inboxTasks()
            try checkConfiguration(generation)
            for task in inbox { remoteTasks[task.id] = task }
            if inbox.count >= 200 {
                warnings.append("TickTick returned the 200-task Inbox limit. Some Inbox tasks may be missing from this sync.")
            }
        } catch let error as TickTickError {
            try checkConfiguration(generation)
            if error == .httpStatus(401) || error == .missingToken { throw error }
            warnings.append("The TickTick Inbox could not be loaded. \(error.localizedDescription)")
        }

        var completedHistoryLoaded = false
        do {
            let historyStart = state.lastSyncedAt?.addingTimeInterval(-60)
                ?? pullStartedAt.addingTimeInterval(-30 * 24 * 60 * 60)
            let completed = try await client.completedTasks(startDate: historyStart, endDate: pullStartedAt)
            try checkConfiguration(generation)
            for task in completed { remoteTasks[task.id] = task }
            completedHistoryLoaded = true
            if completed.count >= 200 {
                warnings.append("TickTick returned the 200-task completed-history limit. Some completed tasks in this time range may be missing.")
            }
        } catch let error as TickTickError {
            try checkConfiguration(generation)
            if error == .httpStatus(401) || error == .missingToken { throw error }
            warnings.append("TickTick completed-task history could not be loaded. \(error.localizedDescription)")
        }

        let observed = Set(remoteTasks.keys)
        let missing = Set(state.tasks.compactMap(\.remote).filter { !observed.contains($0.taskID) })
        for identity in missing.sorted(by: { ($0.projectID, $0.taskID) < ($1.projectID, $1.taskID) }) {
            do {
                let task = try await client.task(projectID: identity.projectID, taskID: identity.taskID)
                try checkConfiguration(generation)
                if let task { remoteTasks[task.id] = task }
            } catch let error as TickTickError {
                try checkConfiguration(generation)
                if error == .httpStatus(401) || error == .missingToken { throw error }
                warnings.append("A known TickTick task could not be refreshed. \(error.localizedDescription)")
            }
        }

        var merged = state
        merged.merge(remoteTasks.values.sorted { $0.id < $1.id })
        if completedHistoryLoaded { merged.lastSyncedAt = pullStartedAt }
        try commit(merged)
        return SyncReport(pushed: pushed, pulled: remoteTasks.count, warnings: warnings)
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
