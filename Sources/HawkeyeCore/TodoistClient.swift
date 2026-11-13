import Foundation

public struct TodoistClient: Sendable {
    private let http: ProviderHTTP
    public init(token: String, session: URLSession = .shared) { self.init(token: token, transport: URLSessionTransport(session: session)) }
    public init(token: String, transport: any HTTPTransport) {
        http = ProviderHTTP(token: token, baseURL: URL(string: "https://api.todoist.com/api/v1")!, transport: transport)
    }

    public func projects() async throws -> [TaskDestination] {
        try await pages(["projects"]).map {
            guard let id = $0["id"]?.string, let name = $0["name"]?.string else { throw TaskProviderError.invalidResponse }
            return TaskDestination(id: id, name: name)
        }
    }

    func tasks() async throws -> [RemoteTaskSnapshot] {
        try await pages(["tasks"]).map { try Self.snapshot($0) }
    }

    func completed(since: Date, until: Date) async throws -> [RemoteTaskSnapshot] {
        var start = since
        var tasks: [RemoteTaskSnapshot] = []
        while start < until {
            let end = min(start.addingTimeInterval(85 * 24 * 60 * 60), until)
            let items = try await pages(["tasks", "completed", "by_completion_date"], key: "items", query: [
                URLQueryItem(name: "since", value: providerDateString(start)),
                URLQueryItem(name: "until", value: providerDateString(end))
            ])
            tasks.append(contentsOf: try items.map { try Self.snapshot($0, completed: true) })
            start = end
        }
        return tasks
    }

    func task(_ id: String) async throws -> RemoteTaskSnapshot? {
        do { return try Self.snapshot(await http.request("GET", ["tasks", id])) }
        catch TaskProviderError.httpStatus(404) { return nil }
    }

    func create(_ intent: TaskCreationIntent) async throws -> RemoteTaskIdentity {
        var args: [String: JSONValue] = ["content": .string(intent.payload.title), "description": .string(intent.payload.taskDescription)]
        args["due"] = intent.payload.dueAt.map { .object(["date": .string(providerDateString($0)), "timezone": .string("UTC")]) } ?? .null
        args["project_id"] = .string(intent.destinationID)
        let command = intent.commandID.uuidString
        let temporary = intent.temporaryID.uuidString
        let response = try await http.request("POST", ["sync"], body: ["commands": .array([.object([
            "type": .string("item_add"), "uuid": .string(command), "temp_id": .string(temporary), "args": .object(args)
        ])])])
        if let status = response["sync_status"]?.object?[command], status.string != "ok" {
            throw TaskProviderError.invalidResponse
        }
        guard let id = response["temp_id_mapping"]?.object?[temporary]?.string else { throw TaskProviderError.invalidResponse }
        return RemoteTaskIdentity(taskID: id, projectID: intent.destinationID, provider: .todoist)
    }

    func update(_ task: TodoTask, identity: RemoteTaskIdentity, context: TaskSyncContext) async throws {
        let active = try await self.task(identity.taskID)
        try await context.check()
        if active == nil && !task.completed {
            try await setCompletion(false, identity: identity, context: context)
            try await context.check()
        }
        var body = payload(task)
        if active?.dueAt.map(TickTickDate.string) == task.dueAt.map(TickTickDate.string) || task.completed {
            body.removeValue(forKey: "due_datetime")
            body.removeValue(forKey: "due_string")
        }
        _ = try await http.request("POST", ["tasks", identity.taskID], body: body)
        try await context.check()
        if active != nil && task.completed {
            try await setCompletion(true, identity: identity, context: context)
            try await context.check()
        }
    }

    private func setCompletion(_ completed: Bool, identity: RemoteTaskIdentity, context: TaskSyncContext) async throws {
        let commandID = (context.operationID ?? UUID()).uuidString
        let result = try await http.request("POST", ["sync"], body: ["commands": .array([.object([
            "type": .string(completed ? "item_close" : "item_uncomplete"), "uuid": .string(commandID),
            "args": .object(["id": .string(identity.taskID)])
        ])])])
        guard result["sync_status"]?.object?[commandID]?.string == "ok" else { throw TaskProviderError.invalidResponse }
    }

    private func payload(_ task: TodoTask) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["content": .string(task.title), "description": .string(task.taskDescription)]
        if let due = task.dueAt { body["due_datetime"] = .string(providerDateString(due)) }
        else { body["due_string"] = .string("no date") }
        return body
    }

    private func pages(_ path: [String], key: String = "results", query: [URLQueryItem] = []) async throws -> [[String: JSONValue]] {
        var cursor: String?
        var seen = Set<String>()
        var items: [[String: JSONValue]] = []
        repeat {
            let page = try await http.request("GET", path, query: query + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []))
            guard let values = page[key]?.array else { throw TaskProviderError.invalidResponse }
            for value in values {
                guard let object = value.object else { throw TaskProviderError.invalidResponse }
                items.append(object)
            }
            cursor = try nextPageCursor(page, seen: &seen)
        } while cursor != nil
        return items
    }

    private static func snapshot(_ fields: [String: JSONValue], completed: Bool = false) throws -> RemoteTaskSnapshot {
        guard let id = fields["id"]?.string ?? fields["task_id"]?.string,
              let projectID = fields["project_id"]?.string, let title = fields["content"]?.string else {
            throw TaskProviderError.invalidResponse
        }
        let duration = fields["duration"]?.object
        let amount = duration?["amount"]?.number
        let seconds: TimeInterval?
        if let amount {
            guard amount.isFinite, amount > 0, let unit = duration?["unit"]?.string, ["minute", "day"].contains(unit) else {
                throw TaskProviderError.invalidResponse
            }
            seconds = amount * (unit == "minute" ? 60 : 86400)
        } else { seconds = nil }
        return RemoteTaskSnapshot(identity: RemoteTaskIdentity(taskID: id, projectID: projectID, provider: .todoist),
                                  title: title, description: fields["description"]?.string ?? "",
                                  createdAt: try checkedProviderDate(fields["added_at"]?.string), dueAt: try checkedProviderDate(fields["due"]?.object?["datetime"]?.string ?? fields["due"]?.object?["date"]?.string),
                                  duration: seconds, completed: completed || fields["checked"]?.bool == true,
                                  completedAt: try checkedProviderDate(fields["completed_at"]?.string))
    }
}

public struct TodoistTaskProvider: TaskSyncProvider {
    public let id = TaskProviderID.todoist
    public let retriesCreationSafely = true
    private let client: TodoistClient
    public init(client: TodoistClient) { self.client = client }
    public func create(_ intent: TaskCreationIntent, context: TaskSyncContext) async throws -> RemoteTaskIdentity {
        try await context.check()
        return try await client.create(intent)
    }
    public func update(_ task: TodoTask, identity: RemoteTaskIdentity, context: TaskSyncContext) async throws {
        try await context.check()
        try await client.update(task, identity: identity, context: context)
    }
    public func pull(destinationID: String?, known: [RemoteTaskIdentity], since: Date?, until: Date, context: TaskSyncContext) async throws -> TaskPullResult {
        var tasks: [String: RemoteTaskSnapshot] = [:]
        var warnings: [String] = []
        do {
            for task in try await client.tasks() { tasks[task.identity.taskID] = task }
            try await context.check()
        } catch {
            try await context.check()
            if isAuthenticationError(error) { throw error }
            warnings.append("Todoist active tasks could not be loaded. \(error.localizedDescription)")
        }
        let activeIDs = Set(tasks.keys)
        var historyLoaded = false
        do {
            for task in try await client.completed(since: since?.addingTimeInterval(-60) ?? until.addingTimeInterval(-30 * 24 * 60 * 60), until: until) {
                let id = task.identity.taskID
                guard !activeIDs.contains(id) else { continue }
                if tasks[id] == nil || (task.completedAt ?? .distantPast) > (tasks[id]?.completedAt ?? .distantPast) {
                    tasks[id] = task
                }
            }
            try await context.check()
            historyLoaded = true
        } catch {
            try await context.check()
            if isAuthenticationError(error) { throw error }
            warnings.append("Todoist completed history could not be loaded. \(error.localizedDescription)")
        }
        for identity in known where tasks[identity.taskID] == nil {
            do {
                if let task = try await client.task(identity.taskID) { tasks[identity.taskID] = task }
                try await context.check()
            } catch {
                try await context.check()
                if isAuthenticationError(error) { throw error }
                warnings.append("A known Todoist task could not be refreshed. \(error.localizedDescription)")
            }
        }
        return TaskPullResult(tasks: Array(tasks.values), warnings: warnings, historyLoaded: historyLoaded)
    }
}
