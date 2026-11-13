import Foundation

extension TickTickTask {
    var snapshot: RemoteTaskSnapshot {
        RemoteTaskSnapshot(identity: RemoteTaskIdentity(taskID: id, projectID: projectId), title: title,
                           description: content ?? desc ?? "", createdAt: createdTime, dueAt: scheduledStart,
                           duration: scheduledDuration, completed: status == 2, completedAt: completedTime)
    }
}

public struct TickTickTaskProvider: TaskSyncProvider {
    public let id = TaskProviderID.ticktick
    public let retriesCreationSafely = true
    private let client: TickTickClient
    public init(client: TickTickClient) { self.client = client }

    public func create(_ intent: TaskCreationIntent, context: TaskSyncContext) async throws -> RemoteTaskIdentity {
        guard var identity = intent.payload.remote else { throw TaskProviderError.invalidResponse }
        let remote = try await client.task(projectID: identity.projectID, taskID: identity.taskID)
        try await context.check()
        if let remote {
            identity = RemoteTaskIdentity(taskID: remote.id, projectID: remote.projectId)
        } else {
            if let created = try await client.createTask(intent.payload, identity: identity) {
                identity = RemoteTaskIdentity(taskID: created.id, projectID: created.projectId)
            }
            try await context.check()
        }
        return identity
    }

    public func update(_ task: TodoTask, identity: RemoteTaskIdentity, context: TaskSyncContext) async throws {
        guard let remote = try await client.task(projectID: identity.projectID, taskID: identity.taskID) else {
            throw TickTickError.remoteTaskMissing
        }
        try await context.check()
        try await client.updateTask(task, identity: identity, preserving: remote)
        try await context.check()
        if task.completed && remote.status != 2 {
            try await client.completeTask(identity: identity)
            try await context.check()
        }
    }

    public func pull(destinationID: String?, known: [RemoteTaskIdentity], since: Date?, until: Date,
                     context: TaskSyncContext) async throws -> TaskPullResult {
        let pullStartedAt = until
        var warnings: [String] = []
        var projects: [TickTickProject] = []
        do {
            let listing = try await client.projectListing()
            try await context.check()
            projects = listing.projects
            warnings.append(contentsOf: listing.warnings)
        } catch let error as TickTickError {
            try await context.check()
            if error == .httpStatus(401) || error == .missingToken { throw error }
            warnings.append("TickTick projects could not be loaded. \(error.localizedDescription)")
        }

        var remoteTasks: [String: TickTickTask] = [:]
        for project in projects where project.kind != "NOTE" && project.closed != true {
            do {
                let data = try await client.projectData(projectID: project.id)
                try await context.check()
                for task in data.tasks { remoteTasks[task.id] = task }
            } catch let error as TickTickError {
                try await context.check()
                if error == .httpStatus(401) || error == .missingToken { throw error }
                warnings.append("TickTick list \(project.name) could not be loaded. \(error.localizedDescription)")
            }
        }

        do {
            let inbox = try await client.inboxTasks()
            try await context.check()
            for task in inbox { remoteTasks[task.id] = task }
            if inbox.count >= 200 {
                warnings.append("TickTick returned the 200-task Inbox limit. Some Inbox tasks may be missing from this sync.")
            }
        } catch let error as TickTickError {
            try await context.check()
            if error == .httpStatus(401) || error == .missingToken { throw error }
            warnings.append("The TickTick Inbox could not be loaded. \(error.localizedDescription)")
        }

        var completedHistoryLoaded = false
        do {
            let historyStart = since?.addingTimeInterval(-60)
                ?? pullStartedAt.addingTimeInterval(-30 * 24 * 60 * 60)
            let completed = try await client.completedTasks(startDate: historyStart, endDate: pullStartedAt)
            try await context.check()
            for task in completed { remoteTasks[task.id] = task }
            completedHistoryLoaded = true
            if completed.count >= 200 {
                warnings.append("TickTick returned the 200-task completed-history limit. Some completed tasks in this time range may be missing.")
            }
        } catch let error as TickTickError {
            try await context.check()
            if error == .httpStatus(401) || error == .missingToken { throw error }
            warnings.append("TickTick completed-task history could not be loaded. \(error.localizedDescription)")
        }

        let observed = Set(remoteTasks.keys)
        let missing = Set(known.filter { !observed.contains($0.taskID) })
        for identity in missing.sorted(by: { ($0.projectID, $0.taskID) < ($1.projectID, $1.taskID) }) {
            do {
                let task = try await client.task(projectID: identity.projectID, taskID: identity.taskID)
                try await context.check()
                if let task { remoteTasks[task.id] = task }
            } catch let error as TickTickError {
                try await context.check()
                if error == .httpStatus(401) || error == .missingToken { throw error }
                warnings.append("A known TickTick task could not be refreshed. \(error.localizedDescription)")
            }
        }

        return TaskPullResult(tasks: remoteTasks.values.map { $0.snapshot }, warnings: warnings, historyLoaded: completedHistoryLoaded)
    }
}
