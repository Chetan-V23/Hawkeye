import Foundation

public struct NotionClient: Sendable {
    private let http: ProviderHTTP
    public init(token: String, session: URLSession = .shared) { self.init(token: token, transport: URLSessionTransport(session: session)) }
    public init(token: String, transport: any HTTPTransport) {
        http = ProviderHTTP(token: token, baseURL: URL(string: "https://api.notion.com/v1")!, transport: transport,
                            headers: ["Notion-Version": "2026-03-11"])
    }

    public func dataSources() async throws -> [NotionDataSource] {
        try await pages(["search"], body: ["filter": .object(["property": .string("object"), "value": .string("data_source")])])
            .map(Self.source)
    }

    public func dataSource(id: String) async throws -> NotionDataSource {
        try Self.source(await http.request("GET", ["data_sources", id]))
    }

    func tasks(dataSourceID: String, mapping: NotionTaskMapping) async throws -> [RemoteTaskSnapshot] {
        try await pages(["data_sources", dataSourceID, "query"], body: [:]).compactMap {
            if $0["archived"]?.bool == true || $0["in_trash"]?.bool == true { return nil }
            return try snapshot($0, dataSourceID: dataSourceID, mapping: mapping)
        }
    }

    func page(id: String, dataSourceID: String, mapping: NotionTaskMapping) async throws -> RemoteTaskSnapshot? {
        do {
            let page = try await http.request("GET", ["pages", id])
            if page["archived"]?.bool == true || page["in_trash"]?.bool == true { return nil }
            return try snapshot(page, dataSourceID: dataSourceID, mapping: mapping)
        } catch TaskProviderError.httpStatus(404) { return nil }
    }

    func create(_ intent: TaskCreationIntent, mapping: NotionTaskMapping) async throws -> RemoteTaskIdentity {
        let response = try await http.request("POST", ["pages"], body: [
            "parent": .object(["data_source_id": .string(intent.destinationID)]),
            "properties": .object(properties(intent.payload, mapping: mapping))
        ])
        guard let id = response["id"]?.string else { throw TaskProviderError.invalidResponse }
        return RemoteTaskIdentity(taskID: id, projectID: intent.destinationID, provider: .notion)
    }

    func recoveryIdentity(pageID: String, dataSourceID: String, mapping: NotionTaskMapping) async throws -> RemoteTaskIdentity {
        guard let uuid = UUID(uuidString: pageID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TaskProviderError.invalidResponse
        }
        let page = try await http.request("GET", ["pages", uuid.uuidString.lowercased()])
        guard let parent = page["parent"]?.object?["data_source_id"]?.string,
              (UUID(uuidString: parent)?.uuidString ?? parent) == (UUID(uuidString: dataSourceID)?.uuidString ?? dataSourceID),
              page["archived"]?.bool != true, page["in_trash"]?.bool != true else {
            throw TaskProviderError.invalidMapping
        }
        let task = try snapshot(page, dataSourceID: dataSourceID, mapping: mapping)
        guard UUID(uuidString: task.identity.taskID) == uuid else { throw TaskProviderError.invalidResponse }
        return task.identity
    }

    func update(_ task: TodoTask, identity: RemoteTaskIdentity, mapping: NotionTaskMapping, context: TaskSyncContext) async throws {
        let page = try await http.request("GET", ["pages", identity.taskID])
        try await context.check()
        guard page["archived"]?.bool != true, page["in_trash"]?.bool != true else { throw TaskProviderError.remoteTaskMissing }
        let remote = try snapshot(page, dataSourceID: identity.projectID, mapping: mapping)
        let rawProperties = page["properties"]?.object ?? [:]
        func property(_ id: String) -> [String: JSONValue]? {
            rawProperties[id]?.object ?? rawProperties.values.compactMap(\.object).first { $0["id"]?.string == id }
        }
        var values = properties(task, mapping: mapping)
        if task.completed == remote.completed { values.removeValue(forKey: mapping.statusPropertyID) }
        if task.dueAt.map(TickTickDate.string) == remote.dueAt.map(TickTickDate.string) {
            values.removeValue(forKey: mapping.duePropertyID)
        } else if let start = task.dueAt, let rawDate = property(mapping.duePropertyID)?["date"]?.object {
            var date = rawDate
            date["start"] = .string(providerDateString(start))
            if let oldStart = remote.dueAt, let end = try checkedProviderDate(rawDate["end"]?.string), end > oldStart {
                date["end"] = .string(providerDateString(start.addingTimeInterval(end.timeIntervalSince(oldStart))))
            }
            date["time_zone"] = .null
            values[mapping.duePropertyID] = .object(["date": .object(date)])
        }
        _ = try await http.request("PATCH", ["pages", identity.taskID], body: ["properties": .object(values)])
    }

    private func properties(_ task: TodoTask, mapping: NotionTaskMapping) -> [String: JSONValue] {
        var values: [String: JSONValue] = [
            mapping.titlePropertyID: .object(["title": richText(task.title)]),
            mapping.duePropertyID: .object(["date": task.dueAt.map { .object(["start": .string(providerDateString($0))]) } ?? .null])
        ]
        if mapping.statusType == "checkbox" {
            values[mapping.statusPropertyID] = .object(["checkbox": .bool(task.completed)])
        } else {
            values[mapping.statusPropertyID] = .object([mapping.statusType: .object([
                "name": .string(task.completed ? mapping.completedStatus : mapping.openStatus)
            ])])
        }
        if let id = mapping.descriptionPropertyID { values[id] = .object(["rich_text": richText(task.taskDescription)]) }
        return values
    }

    private func richText(_ text: String) -> JSONValue {
        var remaining = text[...]
        var values: [JSONValue] = []
        while !remaining.isEmpty {
            let chunk = remaining.prefix(2000)
            values.append(.object(["type": .string("text"), "text": .object(["content": .string(String(chunk))])]))
            remaining = remaining.dropFirst(chunk.count)
        }
        return .array(values)
    }

    private func pages(_ path: [String], body: [String: JSONValue]) async throws -> [[String: JSONValue]] {
        var cursor: String?
        var seen = Set<String>()
        var result: [[String: JSONValue]] = []
        repeat {
            var payload = body
            if let cursor { payload["start_cursor"] = .string(cursor) }
            let page = try await http.request("POST", path, body: payload)
            guard let items = page["results"]?.array else { throw TaskProviderError.invalidResponse }
            for item in items {
                guard let fields = item.object else { throw TaskProviderError.invalidResponse }
                result.append(fields)
            }
            if page["has_more"]?.bool == true {
                cursor = try nextPageCursor(page, seen: &seen)
                guard cursor != nil else { throw TaskProviderError.invalidResponse }
            } else { cursor = nil }
        } while cursor != nil
        return result
    }

    private static func plainText(_ value: JSONValue?) -> String {
        (value?.array ?? []).compactMap { $0.object?["plain_text"]?.string ?? $0.object?["text"]?.object?["content"]?.string }.joined()
    }

    private static func source(_ fields: [String: JSONValue]) throws -> NotionDataSource {
        guard let id = fields["id"]?.string, let properties = fields["properties"]?.object else { throw TaskProviderError.invalidResponse }
        let parsed = try properties.map { name, value -> NotionProperty in
            guard let item = value.object, let propertyID = item["id"]?.string, let type = item["type"]?.string else {
                throw TaskProviderError.invalidResponse
            }
            let options = item[type]?.object?["options"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
            return NotionProperty(id: propertyID, name: item["name"]?.string ?? name, type: type, options: options)
        }.sorted { $0.name < $1.name }
        let title = plainText(fields["title"])
        return NotionDataSource(id: id, name: title.isEmpty ? "Untitled database" : title, properties: parsed)
    }

    private func snapshot(_ fields: [String: JSONValue], dataSourceID: String, mapping: NotionTaskMapping) throws -> RemoteTaskSnapshot {
        guard let id = fields["id"]?.string, let properties = fields["properties"]?.object else { throw TaskProviderError.invalidResponse }
        func property(_ id: String) -> [String: JSONValue]? {
            properties[id]?.object ?? properties.values.compactMap(\.object).first { $0["id"]?.string == id }
        }
        guard let title = property(mapping.titlePropertyID)?["title"] else { throw TaskProviderError.invalidMapping }
        let status = property(mapping.statusPropertyID)
        guard status?[mapping.statusType] != nil, let due = property(mapping.duePropertyID), due["date"] != nil else {
            throw TaskProviderError.invalidMapping
        }
        let completed = mapping.statusType == "checkbox" ? status?["checkbox"]?.bool == true
            : status?[mapping.statusType]?.object?["name"]?.string == mapping.completedStatus
        let description: String?
        if let id = mapping.descriptionPropertyID {
            guard let richText = property(id)?["rich_text"], richText.array != nil else { throw TaskProviderError.invalidMapping }
            description = Self.plainText(richText)
        } else { description = nil }
        let destination = fields["parent"]?.object?["data_source_id"]?.string ?? dataSourceID
        let start = try checkedProviderDate(due["date"]?.object?["start"]?.string)
        let end = try checkedProviderDate(due["date"]?.object?["end"]?.string)
        let duration = start.flatMap { start in end.flatMap { $0 > start ? $0.timeIntervalSince(start) : nil } }
        return RemoteTaskSnapshot(identity: RemoteTaskIdentity(taskID: id, projectID: destination, provider: .notion),
                                  title: Self.plainText(title), description: description,
                                  createdAt: try checkedProviderDate(fields["created_time"]?.string),
                                  dueAt: start, duration: duration, completed: completed)
    }
}

public struct NotionTaskProvider: TaskSyncProvider {
    public let id = TaskProviderID.notion
    public let retriesCreationSafely = false
    private let client: NotionClient
    private let mapping: NotionTaskMapping
    public init(client: NotionClient, mapping: NotionTaskMapping) { self.client = client; self.mapping = mapping }
    public func create(_ intent: TaskCreationIntent, context: TaskSyncContext) async throws -> RemoteTaskIdentity {
        try await context.check()
        return try await client.create(intent, mapping: mapping)
    }
    public func recoverCreation(_ intent: TaskCreationIntent, pageID: String, context: TaskSyncContext) async throws -> RemoteTaskIdentity {
        try await context.check()
        return try await client.recoveryIdentity(pageID: pageID, dataSourceID: intent.destinationID, mapping: mapping)
    }
    public func update(_ task: TodoTask, identity: RemoteTaskIdentity, context: TaskSyncContext) async throws {
        try await context.check()
        try await client.update(task, identity: identity, mapping: mapping, context: context)
    }
    public func pull(destinationID: String?, known: [RemoteTaskIdentity], since: Date?, until: Date, context: TaskSyncContext) async throws -> TaskPullResult {
        guard let destinationID, !destinationID.isEmpty else { return TaskPullResult(tasks: [], historyLoaded: false) }
        var tasks: [String: RemoteTaskSnapshot] = [:]
        var warnings: [String] = []
        var loaded = false
        do {
            for task in try await client.tasks(dataSourceID: destinationID, mapping: mapping) { tasks[task.identity.taskID] = task }
            try await context.check()
            loaded = true
        } catch {
            try await context.check()
            if isAuthenticationError(error) { throw error }
            warnings.append("Notion database could not be loaded. \(error.localizedDescription)")
        }
        for identity in known where tasks[identity.taskID] == nil {
            do {
                if let task = try await client.page(id: identity.taskID, dataSourceID: identity.projectID, mapping: mapping) {
                    tasks[task.identity.taskID] = task
                }
                try await context.check()
            } catch {
                try await context.check()
                if isAuthenticationError(error) { throw error }
                warnings.append("A known Notion page could not be refreshed. \(error.localizedDescription)")
            }
        }
        return TaskPullResult(tasks: Array(tasks.values), warnings: warnings, historyLoaded: loaded)
    }
}
